# /// script
# requires-python = ">=3.11"
# dependencies = ["pyte>=0.8,<1"]
# ///
"""Real node PTYs: mouse/keyboard dropdowns, cancellation, and constrained values."""
import fcntl, json, os, pty, select, struct, termios, time, unittest
import pyte
import test_filter_node as fixtures
from test_parallel_node import ROOT, wait, stop

class DropdownIntegration(unittest.TestCase):
    setUp = fixtures.FilterIntegration.setUp
    tearDown = fixtures.FilterIntegration.tearDown
    start = fixtures.FilterIntegration.start
    call = fixtures.FilterIntegration.call

    def form(self, node):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH",32,110,0,0))
        self.screen = pyte.Screen(110,32)
        self.stream = pyte.ByteStream(self.screen)
        self.config = self.folder / "node.json"
        self.config.write_text('{}')
        self.process = self.start([os.environ.get('GRAFFITTY_TEST_CLI', str(ROOT / 'dist/bin/gft')),'node',node,'--edit','--config',str(self.config)],
            {**self.env,'TERM':'xterm-256color'},stdin=slave,stdout=slave,stderr=slave)
        os.close(slave)
        wait(lambda: 'Name' in self.drain())
        self.addCleanup(os.close,self.master)
        self.addCleanup(stop,self.process)

    def drain(self):
        while select.select([self.master],[],[],0)[0]:
            data = os.read(self.master, 65536)
            if not data:
                self.fail("Node exited during PTY test: " + '\n'.join(self.screen.display))
            self.stream.feed(data)
        return '\n'.join(self.screen.display)

    def send(self, data): os.write(self.master,data)

    def click_text(self, text):
        self.drain()
        y = next(i for i,line in enumerate(self.screen.display) if text in line)
        x = self.screen.display[y].index(text)
        self.send(f'\x1b[<0;{x+1};{y+1}M\x1b[<0;{x+1};{y+1}m'.encode())

    def saved(self, **values):
        self.send(b'\x13')
        def matches():
            self.drain()
            try: saved=json.loads(self.config.read_text())
            except json.JSONDecodeError: return False
            return all(saved.get(k)==v for k,v in values.items())
        wait(matches)

    def test_manual_prompt_click_positions_cursor_before_wide_character(self):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.screen = pyte.Screen(80, 24)
        self.stream = pyte.ByteStream(self.screen)
        self.process = self.start([os.environ.get('GRAFFITTY_TEST_CLI', str(ROOT / 'dist/bin/gft')), 'node', 'manual-prompt'],
            {**self.env, 'TERM': 'xterm-256color'}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        self.addCleanup(os.close, self.master)
        self.addCleanup(stop, self.process)
        wait(lambda: 'Prompt' in self.drain())
        self.call(3, 'graph.connect', **{'from': '%3', 'from_port': 'out', 'to': '%2', 'to_port': 'in'})
        self.send('\x1b[200~a한글z\x1b[201~'.encode())
        wait(lambda: 'a한글z' in self.drain())
        y = next(i for i, line in enumerate(self.screen.display) if 'a한글z' in line)
        x = self.screen.display[y].index('a한글z')
        # Click the second terminal cell occupied by 한, then insert and send.
        self.send(f'\x1b[<0;{x+3};{y+1}M\x1b[<0;{x+3};{y+1}m'.encode())
        self.send(b'X')
        wait(lambda: 'aX한글z' in self.drain())
        self.click_text('[ Send ]')
        events = wait(lambda: self.call(2, 'graph.take')['events'])
        self.assertEqual(events[0]['text'], 'aX한글z')

    def test_notification_boolean_and_occasion_dropdowns(self):
        self.form('system-notification')
        self.click_text('always  ▾')
        wait(lambda: 'invisible' in self.drain())
        self.click_text('invisible')
        wait(lambda: 'invisible  ▾' in self.drain())
        self.send(b'\t\r') # boolean field: open with Enter
        wait(lambda: any('│ no' in line for line in self.drain().splitlines()))
        self.send(b'\x1b[B\r')
        wait(lambda: 'no  ▾' in self.drain())
        self.send(b'invalid\x1b[200~arbitrary\x1b[201~')
        self.saved(focus='no',occasion='invisible')
        self.assertNotIn('arbitrary',self.drain())
        self.send(b' \x1b[A\x1b') # highlight yes, Esc cancels
        time.sleep(.15)
        self.saved(focus='no',occasion='invisible')
        self.assertEqual(self.process.poll(),None)

    def test_time_trigger_mode_dropdown(self):
        self.form('scheduled-trigger')
        self.send(b'\t\x1bOQ') # F2 opens Mode
        wait(lambda: any('│ repeat' in line for line in self.drain().splitlines()))
        self.send(b'\x1b[F\r') # End then Enter chooses repeat
        self.saved(mode='repeat')
        self.assertIn('repeat  ▾',self.drain())

    def test_time_trigger_relative_choices_preview_and_arm(self):
        self.form('scheduled-trigger')
        self.send(b'\t\r\x1b[F\r')  # Repeat
        wait(lambda: 'Start' in self.drain())
        self.assertNotIn('Start delay', self.drain())
        self.assertNotIn('Duration from start', self.drain())
        self.send(b'\t\t\r\x1b[B\r')  # Start: In
        wait(lambda: 'Start delay' in self.drain())
        self.send(b'\t\t\r\x1b[B\r')  # End: After
        wait(lambda: 'Duration from start' in self.drain())
        self.saved(mode='repeat', start='in', start_delay='30m', end='after', duration='30m')
        wait(lambda: '30 triggers' in self.drain())
        self.click_text('[ Start ]')
        wait(lambda: 'Armed' in self.drain() and 'Start:' in self.drain())
        self.click_text('[ Pause ]')
        wait(lambda: '[ Start ]' in self.drain())
        self.click_text('[ Start ]')
        wait(lambda: '[ Pause ]' in self.drain())
        self.assertIn('End:', self.drain())
        self.click_text('repeat  ▾')
        self.send(b'\x1b[H\r')  # Once
        wait(lambda: 'When' in self.drain())
        self.assertNotIn('Start delay', self.drain())
        self.send(b'\t\r\x1b[H\r')  # When: In
        wait(lambda: 'Delay ·' in self.drain())
        self.saved(mode='at', when='in', delay='30m', start_delay='30m', duration='30m')
        self.assertIn('Fires once in 30m', self.drain())
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.screen.resize(24, 80)
        self.send(b'\t')  # Force a redraw: the test PTY has no controlling process group.
        wait(lambda: any('Status' in line and '[ Start ]' in line for line in self.drain().splitlines()[10:]))
        self.click_text('[ Start ]')
        wait(lambda: 'Armed' in self.drain())

    def test_once_trigger_can_pause_start_and_start_again_after_completion(self):
        self.form('scheduled-trigger')
        self.call(3, 'graph.connect', **{'from': '%3', 'from_port': 'out', 'to': '%2', 'to_port': 'in'})
        self.send(b'\t\t\r\x1b[H\r\t\x1b[17~1s')
        wait(lambda: 'Fires once in 1s' in self.drain())
        self.click_text('[ Start ]')
        wait(lambda: '[ Pause ]' in self.drain())
        self.click_text('[ Pause ]')
        wait(lambda: '[ Start ]' in self.drain())
        time.sleep(1.1)
        self.assertEqual(self.call(2, 'graph.take')['events'], [])
        self.click_text('[ Start ]')
        wait(lambda: '[ Pause ]' in self.drain())
        wait(lambda: 'Complete' in self.drain() and '[ Start ]' in self.drain())
        events = self.call(2, 'graph.take')['events']
        self.assertEqual(len(events), 1)
        self.call(2, 'graph.ack', event_id=events[0]['event_id'], status='delivered')
        self.click_text('[ Start ]')
        wait(lambda: '[ Pause ]' in self.drain())
        wait(lambda: 'Complete' in self.drain() and '[ Start ]' in self.drain())
        self.assertEqual(len(self.call(2, 'graph.take')['events']), 1)

    def test_filter_status_start_pause_retains_queued_input(self):
        self.form('filter')
        self.send(b'\t\ttrue')
        self.call(1, 'graph.connect', **{'from': '%1', 'from_port': 'result', 'to': '%3', 'to_port': 'in'})
        self.call(3, 'graph.connect', **{'from': '%3', 'from_port': 'matched', 'to': '%2', 'to_port': 'in'})
        self.click_text('[ Start ]')
        wait(lambda: '[ Pause ]' in self.drain())
        self.click_text('[ Pause ]')
        wait(lambda: '[ Start ]' in self.drain())
        self.call(1, 'graph.emit', output='result', payload={'text': 'held while paused'})
        time.sleep(.4)
        self.assertEqual(self.call(2, 'graph.take')['events'], [])
        self.click_text('[ Start ]')
        events = wait(lambda: self.call(2, 'graph.take')['events'])
        self.assertEqual(events[0]['text'], 'held while paused')

if __name__ == '__main__': unittest.main()
