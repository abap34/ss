"""Exercise package initialization with a real terminal on standard input."""
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

if os.name == "nt":
    print("init terminal tests skipped: POSIX PTY unavailable")
    sys.exit(0)

import pty
import termios

binary = str(Path(sys.argv[1]).resolve())
root = Path(sys.argv[2]) / "interactive"
root.mkdir()
prompt = b"(empty to cancel): "


def run(name, replies, flags=(), configured="", success=True):
    cwd = root / name
    cwd.mkdir()
    config = cwd / "gitconfig"
    config.write_text(configured)
    environment = dict(os.environ, GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1")
    master, slave = pty.openpty()
    attributes = termios.tcgetattr(slave)
    attributes[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attributes)
    process = subprocess.Popen(
        [binary, "init", "--package", "pkg", *flags], cwd=cwd, env=environment,
        stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
    )
    os.close(slave)
    output = b""
    sent = 0
    deadline = time.monotonic() + 8
    try:
        while True:
            if time.monotonic() > deadline:
                raise AssertionError(f"{name}: timed out\n{output.decode(errors='replace')}")
            if select.select([process.stdout], [], [], 0.1)[0]:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                output += chunk
                while output.count(prompt) > sent:
                    assert sent < len(replies), f"{name}: unexpected prompt: {output!r}"
                    os.write(master, replies[sent])
                    sent += 1
            if process.poll() is not None:
                output += process.stdout.read()
                break
        code = process.wait(timeout=1)
        assert (code == 0) == success, (name, code, output.decode(errors="replace"))
        assert sent == len(replies), (name, sent, output)
        assert config.read_text() == configured, "init must not change global Git configuration"
        package = cwd / "pkg"
        if not success:
            assert not package.exists(), "cancellation must not leave partially generated files"
        return package, output
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
        os.close(master)
        process.stdout.close()


def origin(package):
    return subprocess.check_output(
        ["git", "-C", str(package), "remote", "get-url", "origin"],
        text=True, timeout=5,
    ).strip()


package, _ = run("answer", [b" alice \n"])
assert origin(package) == "https://github.com/alice/pkg.ss"
assert "https://github.com/alice/pkg.ss" in (package / "README.md").read_text()
package, _ = run("retry", [b"../alice\n", b"alice\n"])
assert origin(package) == "https://github.com/alice/pkg.ss"
package, _ = run("long_line", [b"x" * 600 + b"\n", b"alice\n"])
assert origin(package) == "https://github.com/alice/pkg.ss"
run("blank", [b"\n"], success=False)
run("eof", [b"\x04"], success=False)
package, _ = run("custom_host", [b"team/subgroup\n"], flags=["--host", "git.example.com"])
assert origin(package) == "https://git.example.com/team/subgroup/pkg.ss"
package, _ = run("configured", [], configured="[github]\nuser = bob\n")
assert origin(package) == "https://github.com/bob/pkg.ss"
package, _ = run("explicit", [], flags=["--user", "alice"])
assert origin(package) == "https://github.com/alice/pkg.ss"
package, _ = run("disabled", [], flags=["--no-git"])
assert not (package / ".git").exists()
print("init terminal: owner input, retry, cancellation, configuration and bypass passed")
