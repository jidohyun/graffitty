"""Real raw console probe: b emits BEL, q restores the console and exits."""
import os
import sys

if os.name == "nt":
    import msvcrt
    read = msvcrt.getwch
    restore = lambda: None
else:
    import termios
    import tty
    saved = termios.tcgetattr(sys.stdin)
    tty.setraw(sys.stdin.fileno())
    read = lambda: sys.stdin.read(1)
    restore = lambda: termios.tcsetattr(sys.stdin, termios.TCSADRAIN, saved)

try:
    sys.stdout.write("\x1b[2J\x1b[H\x1b[?25lBELL_READY")
    sys.stdout.flush()
    while True:
        key = read()
        if key == "q":
            break
        if key == "b":
            sys.stdout.write("\a")
            sys.stdout.flush()
        if key == "c":
            sys.stdout.write("\x1b[6;10H\x1b[?25h\x1b[5 q")
            sys.stdout.flush()
finally:
    sys.stdout.write("\x1b[?25h")
    sys.stdout.flush()
    restore()
