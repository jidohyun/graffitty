"""A local email CLI fixture and prepared Claude conversation; transport is real."""
import json
from pathlib import Path
import shutil
import sys

PROMPT = "When a GGP message brings a new email, summarize it and make a short podcast for me."
READY = "Okay, I will summarize the email and make a podcast when a GGP message arrives."
EMAIL = "New email from Product Team\nSubject: Friday launch\nThe launch is confirmed for Friday at 10 AM. Please review the release notes by Thursday.\n"
SUMMARY = "A new email arrived from Product Team: Friday launch.\n\nThe launch is Friday at 10 AM. Review the release notes by Thursday.\n\nI made a short podcast for you to listen to: inbox-podcast.wav"


def write(out):
    (out / 'email.txt').write_text(EMAIL)
    executable = out / 'bin/email-cli'
    executable.parent.mkdir(exist_ok=True)
    executable.write_text('#!' + sys.executable + '\n'
        'from pathlib import Path\nimport os, sys, time\n'
        'assert sys.argv[1:] == ["wait"]\n'
        'root = Path(os.environ["DEMO_RUNTIME"])\n'
        'print("Waiting for a new email...", file=sys.stderr, flush=True)\n'
        'while not (root / "new-email").exists(): time.sleep(0.1)\n'
        'print((root / "email.txt").read_text(), end="", flush=True)\n')
    executable.chmod(0o700)
    shutil.copy2(Path(__file__).with_name('make_podcast.py'), out / 'make_podcast.py')
    config = {'model': 'Claude Sonnet', 'title': 'Claude', 'directory': '/home/demo',
        'animation_clock': str(out / 'animation-clock'), 'scenario_clock': str(out / 'animation-clock'),
        'char_ms': 8, 'tip': '', 'real_tool_calling': True,
        'completion': {'elapsed_ms': 3000, 'completed_at': '2:30 PM'}, 'turns': [
            # Setup happens before the movie clock starts. Seed this completed
            # turn immediately; only the incoming-email turn streams on camera.
            {'prompt': PROMPT, 'steps': [{'type': 'message', 'text': READY, 'char_ms': 0}]},
            {'contains': 'New email from Product Team', 'steps': [
                {'type': 'think', 'text': 'Summarizing the new email', 'ms': 600},
                {'type': 'tool', 'name': 'Bash', 'input': 'python make_podcast.py',
                 'command': [sys.executable, str(out / 'make_podcast.py')], 'ms': 800}],
             'response': SUMMARY}]}
    (out / 'watcher-claude.json').write_text(json.dumps(config, indent=2) + '\n')


if __name__ == '__main__':
    write(Path(sys.argv[1]).resolve())
