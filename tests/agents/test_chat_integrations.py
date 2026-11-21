# /// script
# requires-python = ">=3.11"
# dependencies = ["pyte>=0.8,<1"]
# ///
"""Offline rendering and real PTY/host tests. Never sends to a real chat."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import subprocess
import tempfile
import termios
import unittest

import pyte
import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/graph",)]
from test_parallel_node import ROOT, rpc, wait, stop

BIN = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "dist/bin/gft"))
ENV_KEYS = ("GRAFFITTY_NODE_CONFIG", "GRAFFITTY_NODE_SETTINGS", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "SLACK_BOT_TOKEN", "SLACK_CHANNEL_ID", "DISCORD_BOT_TOKEN", "DISCORD_CHANNEL_ID")


def clean_env():
    # Tests must exercise missing credentials and hidden prompts even when the
    # developer has configured real host credential defaults.
    return {**{k: v for k, v in os.environ.items() if k not in (*ENV_KEYS, "GRAFFITTY_SECRETS_CONFIG", "CODEX_THREAD_ID", "GRAFFITTY_CODEX_CONTEXT")},
            "XDG_CONFIG_HOME": str(Path(tempfile.gettempdir()) / f"graffitty-no-secrets-{os.getpid()}")}


class ChatIntegrations(unittest.TestCase):
    def test_explicit_credentials_never_fall_back_to_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            helper = folder / "helper"
            helper.write_text('#!/bin/sh\necho private-error >&2\necho partial-secret\nexit 1\n')
            helper.chmod(0o700)
            config = folder / "secrets.toml"
            config.write_text('[secrets.work]\ncommand = ' + json.dumps([str(helper)]) + '\n')
            for service, name in [("telegram", "TELEGRAM_BOT_TOKEN"), ("slack", "SLACK_BOT_TOKEN"), ("discord", "DISCORD_BOT_TOKEN")]:
                env = {**clean_env(), "GRAFFITTY_SECRETS_CONFIG": str(config), name: "wrong-account-token"}
                run = subprocess.run([str(BIN), "node", service + "-send", "--headless", "--credential", "work"], env=env, cwd=folder, capture_output=True, text=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn('Credential "work"', run.stderr)
                for private in ["wrong-account-token", "private-error", "partial-secret"]:
                    self.assertNotIn(private, run.stdout + run.stderr)

    def test_offline_preview_without_credentials_or_host(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            media = folder / "photo.png"
            media.write_bytes(b"test bytes")
            event = folder / "event.json"
            event.write_text(json.dumps({"text": "Build passed", "payload": {"private": "NOT SENT"}, "sessions": [{"path": "/private/transcript"}], "content": [{"type": "image", "path": str(media), "mime_type": "image/png"}]}))
            for service, env in [("telegram", "TELEGRAM_BOT_TOKEN"), ("slack", "SLACK_BOT_TOKEN"), ("discord", "DISCORD_BOT_TOKEN")]:
                run = subprocess.run([str(BIN), "node", service + "-send", "--preview", str(event)], env=clean_env(), capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stderr)
                result = json.loads(run.stdout)
                self.assertEqual(result["message"]["text"], "Build passed")
                self.assertEqual(len(result["delivery"]), 2)
                self.assertNotIn("NOT SENT", run.stdout)
                self.assertNotIn("/private/transcript", run.stdout)
                self.assertNotIn(env, run.stdout + run.stderr)
                run = subprocess.run([str(BIN), "node", service + "-send", "--headless"], env=clean_env(), stdin=subprocess.DEVNULL, capture_output=True, text=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn(env, run.stderr)
            event.write_text('{"payload":{"arbitrary":true}}')
            run = subprocess.run([str(BIN), "node", "telegram-send", "--preview", str(event)], env=clean_env(), capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("No message content", run.stderr)

    def test_slack_demo_uses_real_form_and_logs_without_credentials_or_http(self):
        with tempfile.TemporaryDirectory(prefix="slack-demo-", dir="/tmp") as directory, socket.socket() as proxy:
            folder = Path(directory)
            proxy.bind(("127.0.0.1", 0))
            proxy.listen()
            address = "http://127.0.0.1:" + str(proxy.getsockname()[1])
            hostlog = (folder / "host.log").open('w+')
            host = subprocess.Popen(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"), "--script", "tests/jev_node_host.gd"],
                                    env={**clean_env(), "JEV_TEST_DIRECTORY": str(folder)}, stdout=hostlog, stderr=hostlog)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 42, 130, 0, 0))
            before = termios.tcgetattr(slave)
            screen = pyte.Screen(130, 42)
            stream = pyte.ByteStream(screen)
            output = bytearray()
            def drain():
                while select.select([master], [], [], 0)[0]:
                    chunk = os.read(master, 65536)
                    output.extend(chunk)
                    stream.feed(chunk)
                return '\n'.join(screen.display)
            node = None
            try:
                wait(lambda: (folder / 'ready.json').exists())
                endpoint = json.loads((folder / 'ready.json').read_text())['socket']
                def call(token, method, **params): return rpc(endpoint, token, method, params)
                call(1, 'agent.event', provider='adapter', event='SessionStart', session_id='source')
                call(1, 'agent.register', name='Source', inputs=[], outputs=[{'id':'result'}])
                node = subprocess.Popen([str(BIN), 'dev', 'slack-send-demo', '--once'],
                    env={**clean_env(), 'TERM':'xterm-256color', 'GRAFFITTY_SOCKET':endpoint, 'GRAFFITTY_TOKEN':'3',
                         'SLACK_BOT_TOKEN':'invalid token must never be read', 'HTTPS_PROXY':address, 'HTTP_PROXY':address, 'ALL_PROXY':address, 'NO_PROXY':''},
                    stdin=slave, stdout=slave, stderr=slave)
                wait(lambda: 'Running' in drain())
                for label in ['Slack', 'Channel ID', '#website-review', 'Message template', 'Delivery log']:
                    self.assertIn(label, drain())
                self.assertNotIn('notifications disabled', drain())
                manifest = next(n['manifest'] for n in call(1, 'graph.list')['nodes'] if n['node'] == '%3')
                self.assertEqual(manifest['name'], 'Slack Send')
                self.assertEqual(manifest['inputs'][0]['name'], 'Send to Slack')
                call(1, 'graph.connect', **{'from':'%1', 'from_port':'result', 'to':'%3', 'to_port':'in'})
                call(1, 'graph.emit', output='result', payload={'text':'Review: 3 requirements missing'}, content=[], renderings={})
                wait(lambda: 'SENDING Slack' in drain())
                self.assertEqual(len(call(3, 'graph.take')['events']), 1)
                wait(lambda: (drain(), node.poll())[1] is not None)
                self.assertEqual(node.returncode, 0, output.decode(errors='replace'))
                transcript = output.decode(errors='replace')
                self.assertIn('SENT · part 1 accepted by Slack', transcript)
                self.assertIn('DELIVERED · Slack → #website-review', transcript)
                self.assertIn('Review: 3 requirements missing', transcript)
                self.assertEqual(call(3, 'graph.take')['events'], [])
                self.assertEqual(termios.tcgetattr(slave), before)
                self.assertFalse(select.select([proxy], [], [], 0)[0], "Demo contacted the HTTP proxy")
            finally:
                if node is not None: stop(node)
                stop(host)
                hostlog.close()
                os.close(master)
                os.close(slave)

    def test_secret_prompt_edit_preview_save_and_terminal_restore(self):
        for service, secret_name, destination_name in [("telegram", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID"), ("slack", "SLACK_BOT_TOKEN", "SLACK_CHANNEL_ID"), ("discord", "DISCORD_BOT_TOKEN", "DISCORD_CHANNEL_ID")]:
            with self.subTest(service=service), tempfile.TemporaryDirectory(prefix="chat-", dir="/tmp") as directory:
                folder = Path(directory)
                config = folder / "config.json"
                config.write_text('{}')
                hostlog = (folder / "host.log").open('w+')
                host = subprocess.Popen(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"), "--script", "tests/jev_node_host.gd"], env={**clean_env(), "JEV_TEST_DIRECTORY": str(folder)}, stdout=hostlog, stderr=hostlog)
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 42, 130, 0, 0))
                before = termios.tcgetattr(slave)
                output = bytearray()
                screen = pyte.Screen(130, 42)
                stream = pyte.ByteStream(screen)
                def drain():
                    while select.select([master], [], [], 0)[0]:
                        chunk = os.read(master, 65536)
                        output.extend(chunk)
                        stream.feed(chunk)
                    return '\n'.join(screen.display)
                node = None
                try:
                    wait(lambda: (folder / 'ready.json').exists())
                    endpoint = json.loads((folder / 'ready.json').read_text())['socket']
                    def call(token, method, **params): return rpc(endpoint, token, method, params)
                    call(1, 'agent.event', provider='adapter', event='SessionStart', session_id='source')
                    call(1, 'agent.register', name='Source', inputs=[], outputs=[{'id':'result'}])
                    node = subprocess.Popen([str(BIN), 'node', service + '-send', '--config', str(config), '--edit'], env={**clean_env(), 'TERM':'xterm-256color', 'GRAFFITTY_SOCKET':endpoint, 'GRAFFITTY_TOKEN':'3', 'GRAFFITTY_NODE_SETTINGS':'{"name":"ignored"}'}, stdin=slave, stdout=slave, stderr=slave)
                    wait(lambda: secret_name in drain())
                    os.write(master, b'TEST-SECRET-DO-NOT-ECHO\r')
                    wait(lambda: destination_name in drain())
                    os.write(master, b'123456789\n')
                    wait(lambda: 'Message template' in drain())
                    self.assertNotIn(b'TEST-SECRET-DO-NOT-ECHO', output)
                    manifest = next(n['manifest'] for n in call(1,'graph.list')['nodes'] if n['node']=='%3')
                    self.assertEqual(manifest['name'], service.title() + ' Send')
                    self.assertIn('<svg', manifest['icon']['svg'])
                    self.assertEqual(manifest['outputs'], [])
                    call(1,'graph.connect', **{'from':'%1','from_port':'result','to':'%3','to_port':'in'})
                    call(1,'graph.emit', output='result', payload={'text':'Hello preview'}, content=[], renderings={})
                    wait(lambda: 'Hello preview' in drain())
                    # F5 previews without sending or acknowledging the event.
                    os.write(master, b'\x1b[15~')
                    wait(lambda: 'PREVIEW' in drain())
                    self.assertEqual(len(call(3,'graph.take')['events']), 1)
                    self.assertIn('not sent', drain())
                    os.write(master, b'\x13')
                    wait(lambda: 'Saved ' in drain())
                    saved = json.loads(config.read_text())
                    self.assertEqual(saved['chat_id' if service=='telegram' else 'channel_id'], '123456789')
                    self.assertNotIn('token', config.read_text().lower())
                    self.assertNotIn('SECRET', config.read_text())
                    os.write(master,b'\x03')
                    wait(lambda: (drain(), node.poll())[1] is not None)
                    self.assertEqual(node.returncode,0)
                    self.assertEqual(termios.tcgetattr(slave),before)
                    self.assertNotIn(b'TEST-SECRET-DO-NOT-ECHO',output)
                    self.assertRegex(output.decode(errors='replace'), r'\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
                finally:
                    if node is not None: stop(node)
                    stop(host)
                    hostlog.close()
                    os.close(master)
                    os.close(slave)


if __name__ == '__main__': unittest.main()
