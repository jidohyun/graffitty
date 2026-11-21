import os
import pty
import select
import subprocess
import sys
import termios
import time
from pathlib import Path

import pytest

import secret_input


def test_env_and_noninteractive_prompt(monkeypatch):
    monkeypatch.setenv('OPENROUTER_API_KEY', 'test-key')
    assert secret_input.openrouter_key() == 'test-key'
    monkeypatch.delenv('OPENROUTER_API_KEY')
    monkeypatch.setattr(sys.stdin, 'isatty', lambda: False)
    with pytest.raises(ValueError, match='Set OPENROUTER_API_KEY'):
        secret_input.openrouter_key()


def test_hidden_stdin_and_echo_restored():
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)
    command = 'from secret_input import openrouter_key; assert len(openrouter_key()) == 22; print("KEY_LOADED")'
    process = subprocess.Popen([sys.executable, '-c', command], cwd=Path(__file__).parents[1], env={k:v for k,v in os.environ.items() if k != 'OPENROUTER_API_KEY'}, stdin=slave, stdout=slave, stderr=slave)
    output = bytearray()
    try:
        deadline = time.monotonic() + 10
        sent = False
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                output.extend(os.read(master, 65536))
            if b'(hidden):' in output and not sent:
                os.write(master, b'UNIQUE-SECRET-NO-ECHO!\n')
                sent = True
            if b'KEY_LOADED' in output:
                break
        assert process.wait(timeout=3) == 0
        assert b'KEY_LOADED' in output
        assert b'UNIQUE-SECRET-NO-ECHO!' not in output
        assert termios.tcgetattr(slave) == before
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
