"""Hidden stdin prompt for the socket/FastAPI node."""
import os
import sys
import termios


def openrouter_key():
    value = os.environ.get("OPENROUTER_API_KEY", "")
    if value.strip():
        return value
    if not sys.stdin.isatty():
        raise ValueError("Set OPENROUTER_API_KEY; hidden input requires an interactive stdin terminal")
    fd = sys.stdin.fileno()
    before = termios.tcgetattr(fd)
    hidden = before.copy()
    hidden[3] &= ~termios.ECHO
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, hidden)
        print("OPENROUTER_API_KEY (hidden): ", end="", file=sys.stderr, flush=True)
        value = sys.stdin.readline().rstrip("\r\n")
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, before)
        print(file=sys.stderr)
    if not value.strip():
        raise ValueError("OPENROUTER_API_KEY must not be empty")
    return value
