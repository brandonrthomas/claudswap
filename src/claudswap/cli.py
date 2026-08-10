#!/usr/bin/env python3
"""claudswap — run claude (or any command) under a pty with an injection FIFO.

Why: tools inside a Claude Code session (like /switch) sometimes need to type
into the session's own input — e.g. to execute the built-in /model command,
which can't be invoked any other way. Terminal-emulator remote-control APIs
cover only a few terminals (tmux, screen, zellij, kitty, wezterm, konsole);
most terminals (VS Code, GNOME Terminal, Windows Terminal, Terminal.app, bare
ssh) have none. claudswap removes the terminal from the equation: it owns the
pty, so injection works everywhere ptys exist (Linux, macOS).

How: claudswap allocates a pty, runs the wrapped command on it, and transparently
mirrors your real terminal <-> pty (raw mode, window resizes, exit status). It
also listens on a per-session FIFO; bytes written there are fed to the pty as
if typed. The FIFO path is exported to the child as $CLAUDSWAP_FIFO (plus
$CLAUDSWAP_PID for ancestry validation), so anything inside the session can
self-target precisely — no window IDs, no "current pane" ambiguity.

Usage:
  claudswap install                # write the /switch command into ~/.claude (run once)
  claudswap [claude args...]        # wrap claude:  claudswap -c, claudswap --model ...
  claudswap --run CMD [ARGS...]     # wrap an arbitrary command instead of claude

Inject from inside the session:
  printf '/model claude-opus-4-1-20250805\r' > "$CLAUDSWAP_FIFO"

Not supported: Windows (no pty module; a ConPTY port would be needed).
"""

import errno
import fcntl
import os
import select
import signal
import struct
import sys
import termios
import tty

try:
    import pty
except ImportError:  # pragma: no cover
    sys.stderr.write("claudswap: this platform has no pty support\n")
    sys.exit(1)


def runtime_dir():
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    d = os.path.join(xdg, "claudswap") if xdg else "/tmp/claudswap-%d" % os.getuid()
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def clean_stale(d):
    """Remove FIFOs whose owning claudswap process is gone (crash leftovers)."""
    try:
        names = os.listdir(d)
    except OSError:
        return
    for name in names:
        if not name.endswith(".fifo"):
            continue
        stem = name[:-5]
        if not stem.isdigit():
            continue
        try:
            os.kill(int(stem), 0)
        except ProcessLookupError:
            try:
                os.unlink(os.path.join(d, name))
            except OSError:
                pass
        except PermissionError:
            pass  # pid reused by another user; leave it


def get_winsize(fd):
    try:
        raw = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
        rows, cols, _, _ = struct.unpack("HHHH", raw)
        if rows and cols:
            return rows, cols
    except OSError:
        pass
    return None


def set_winsize(fd, rows, cols):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def write_all(fd, data):
    while data:
        try:
            n = os.write(fd, data)
        except OSError as e:
            if e.errno == errno.EAGAIN:
                continue
            raise
        data = data[n:]


def _data_dir():
    """Locate the bundled switch-model.sh / swap.md, packaged or in a source tree."""
    try:
        from importlib.resources import files
        p = files(__package__ or "claudswap") / "data"
        if (p / "switch-model.sh").is_file():
            return p
    except Exception:
        pass
    cand = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
    if os.path.isfile(os.path.join(cand, "switch-model.sh")):
        return cand
    return None


def _read(data, name):
    if isinstance(data, str):
        with open(os.path.join(data, name)) as fh:
            return fh.read()
    return (data / name).read_text()


def _write(path, text, mode):
    # Write-then-rename so an interrupted install can't leave a half-written file
    # that Claude Code would happily load.
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def do_install():
    """Install the /swap slash command and its backend into ~/.claude."""
    data = _data_dir()
    if data is None:
        sys.stderr.write("claudswap: bundled files missing; try "
                         "`pip install --force-reinstall claudswap`\n")
        return 1
    script_dir = os.path.expanduser("~/.claude/scripts")
    cmd_dir = os.path.expanduser("~/.claude/commands")
    os.makedirs(script_dir, exist_ok=True)
    os.makedirs(cmd_dir, exist_ok=True)

    backend = os.path.join(script_dir, "switch-model.sh")
    _write(backend, _read(data, "switch-model.sh"), 0o755)
    print("  switch-model.sh -> %s" % backend)

    slash = os.path.join(cmd_dir, "swap.md")
    # swap.md ships with a placeholder because the backend's absolute path is
    # only known at install time.
    _write(slash, _read(data, "swap.md").replace("CLAUDSWAP_SCRIPT_PATH", backend), 0o644)
    print("  swap.md -> %s" % slash)

    print("\nDone. /swap is available in new Claude Code sessions.")
    print("Start sessions with `claudswap` (or alias claude=claudswap) so it "
          "works in any terminal.")
    return 0


def main():
    argv = sys.argv[1:]
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if argv and argv[0] == "install":
        return do_install()
    if argv and argv[0] == "--run":
        cmd = argv[1:] or ["bash"]
    else:
        cmd = ["claude"] + argv

    rdir = runtime_dir()
    clean_stale(rdir)
    fifo = os.path.join(rdir, "%d.fifo" % os.getpid())
    try:
        os.unlink(fifo)
    except FileNotFoundError:
        pass
    os.mkfifo(fifo, 0o600)

    # Child (and everything under it) sees these; /switch uses them to self-target.
    os.environ["CLAUDSWAP_FIFO"] = fifo
    os.environ["CLAUDSWAP_PID"] = str(os.getpid())

    stdin_fd = 0
    stdin_tty = os.isatty(stdin_fd)

    child_pid, master = pty.fork()
    if child_pid == 0:
        try:
            os.execvp(cmd[0], cmd)
        except OSError as e:
            sys.stderr.write("claudswap: exec %s: %s\n" % (cmd[0], e))
            os._exit(127)

    # Mirror the real terminal's size onto the pty; track future resizes.
    ws = get_winsize(stdin_fd) if stdin_tty else None
    set_winsize(master, *(ws or (40, 120)))
    if stdin_tty:
        def on_winch(_sig, _frm):
            w = get_winsize(stdin_fd)
            if w:
                set_winsize(master, *w)
        signal.signal(signal.SIGWINCH, on_winch)

    # External signals aimed at the wrapper are forwarded to the wrapped process;
    # its exit then unwinds us via pty EOF.
    def forward(sig, _frm):
        try:
            os.kill(child_pid, sig)
        except OSError:
            pass
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, forward)

    saved_termios = termios.tcgetattr(stdin_fd) if stdin_tty else None
    # O_RDWR keeps a writer open so the FIFO never delivers EOF between clients.
    fifo_fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)

    status = 1
    try:
        if stdin_tty:
            tty.setraw(stdin_fd)
        stdin_open = True
        while True:
            fds = [master, fifo_fd] + ([stdin_fd] if stdin_open else [])
            try:
                ready, _, _ = select.select(fds, [], [])
            except InterruptedError:
                continue
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break  # EIO: wrapped process exited
                if not data:
                    break
                write_all(1, data)
            if stdin_open and stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    stdin_open = False  # e.g. headless run; FIFO still drives us
                else:
                    write_all(master, data)
            if fifo_fd in ready:
                try:
                    data = os.read(fifo_fd, 65536)
                except OSError:
                    data = b""
                if data:
                    write_all(master, data)  # injected input, as if typed
    finally:
        if saved_termios is not None:
            termios.tcsetattr(stdin_fd, termios.TCSAFLUSH, saved_termios)
        for closer in (lambda: os.close(fifo_fd), lambda: os.unlink(fifo),
                       lambda: os.close(master)):
            try:
                closer()
            except OSError:
                pass

    try:
        _, st = os.waitpid(child_pid, 0)
        if os.WIFEXITED(st):
            status = os.WEXITSTATUS(st)
        elif os.WIFSIGNALED(st):
            status = 128 + os.WTERMSIG(st)
    except ChildProcessError:
        pass
    return status


if __name__ == "__main__":
    sys.exit(main())
