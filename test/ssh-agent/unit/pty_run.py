"""Run a command on a pseudo-terminal, answer ssh-add's passphrase prompts, print what it showed.

usage: python3 -I pty_run.py <answers|-> <seconds> <command> [args...]
  answers  passphrases for the prompts, separated by '|' ('-' answers nothing); each is typed
           once the output ends with ':' (the prompt), the way a person would; never echoed
  seconds  the harness kills the command after this long (a hang then shows as exit 124)
Prints the terminal output, then a last line 'EXIT <status>'. Test helper for passphrase_test.sh.
"""
import os
import pty
import select
import signal
import sys
import time

answers = [] if sys.argv[1] == "-" else sys.argv[1].split("|")
limit = float(sys.argv[2])
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[3], sys.argv[3:])
out = b""
end = time.time() + limit
timed_out = False
while True:
    if time.time() > end:
        timed_out = True
        os.kill(pid, signal.SIGKILL)
        break
    ready, _, _ = select.select([fd], [], [], 0.2)
    if not ready:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
    if answers and out.rstrip(b" ").endswith(b":"):
        os.write(fd, (answers.pop(0) + "\n").encode())
        out += b"<<typed>>\n"
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
print("EXIT", 124 if timed_out else os.waitstatus_to_exitcode(status))
