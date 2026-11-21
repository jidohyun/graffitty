"""Unit checks only: never launch or manipulate native windows."""
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
import e2e_macos_windows as windows


class WindowIsolationTest(unittest.TestCase):
    def test_only_an_owned_window_id_is_floated(self):
        owner = Mock(pid=10); owner.poll.return_value = None
        before = [{'app-pid': 11, 'window-id': 42, 'window-layout': 'h_tiles'}]
        after = [dict(before[0], **{'window-layout': 'floating'})]
        with patch.object(windows.sys, 'platform', 'darwin'), \
             patch.object(windows.shutil, 'which', return_value='/test/aerospace'), \
             patch.object(windows.subprocess, 'check_output', side_effect=[
                 '10 1\n11 10\n', json.dumps(before), '10 1\n11 10\n', json.dumps(after)]), \
             patch.object(windows.subprocess, 'run') as run:
            evidence = windows.float_test_windows(11, owner)
        run.assert_called_once_with(['/test/aerospace', 'layout', '--window-id', '42', 'floating'], check=True, timeout=5)
        self.assertEqual(evidence['before'], before)
        self.assertEqual(evidence['after'], after)

    def test_detached_window_is_included_alongside_already_floating_owner(self):
        owner = Mock(pid=10); owner.poll.return_value = None
        before = [{'app-pid': 11, 'window-id': 42, 'window-layout': 'floating'},
                  {'app-pid': 11, 'window-id': 43, 'window-layout': 'h_tiles'}]
        after = [dict(w, **{'window-layout': 'floating'}) for w in before]
        with patch.object(windows.sys, 'platform', 'darwin'), \
             patch.object(windows.shutil, 'which', return_value='/test/aerospace'), \
             patch.object(windows.subprocess, 'check_output', side_effect=[
                 '10 1\n11 10\n', json.dumps(before), '10 1\n11 10\n',
                 '10 1\n11 10\n', json.dumps(after)]), \
             patch.object(windows.subprocess, 'run') as run:
            evidence = windows.float_test_windows(11, owner)
        self.assertEqual([call.args[0][3] for call in run.call_args_list], ['42', '43'])
        self.assertEqual(evidence['after'], after)

    def test_rejects_foreign_process_before_calling_window_manager(self):
        owner = Mock(pid=10); owner.poll.return_value = None
        with patch.object(windows.sys, 'platform', 'darwin'), \
             patch.object(windows.shutil, 'which', return_value='/test/aerospace'), \
             patch.object(windows.subprocess, 'check_output', return_value='10 1\n11 1\n') as output, \
             patch.object(windows.subprocess, 'run') as run:
            with self.assertRaisesRegex(AssertionError, 'owned'):
                windows.float_test_windows(11, owner)
        self.assertEqual(output.call_count, 1)
        run.assert_not_called()

    def test_display_move_uses_native_screen_mapping_and_never_moves_focus(self):
        owner = Mock(pid=10); owner.poll.return_value = None
        isolation = {'after': [{'app-pid': 11, 'window-id': 42, 'window-layout': 'floating'}]}
        monitors = [{'monitor-id': 9, 'monitor-appkit-nsscreen-screens-id': 2}]
        with patch.object(windows, 'float_test_windows', return_value=isolation), \
             patch.object(windows, 'owned_pid', return_value=True), \
             patch.object(windows.shutil, 'which', return_value='/test/aerospace'), \
             patch.object(windows.subprocess, 'check_output', return_value=json.dumps(monitors)), \
             patch.object(windows.subprocess, 'run') as run:
            result = windows.move_test_window(11, owner, 1)
        run.assert_called_once_with(['/test/aerospace', 'move-node-to-monitor', '--window-id', '42', '9'], check=True, timeout=5)
        self.assertEqual(result['monitor'], monitors[0])

    def test_display_move_rejects_foreign_window_in_manager_response(self):
        owner = Mock(pid=10); owner.poll.return_value = None
        isolation = {'after': [{'app-pid': 99, 'window-id': 42, 'window-layout': 'floating'}]}
        monitors = [{'monitor-id': 9, 'monitor-appkit-nsscreen-screens-id': 2}]
        with patch.object(windows, 'float_test_windows', return_value=isolation), \
             patch.object(windows, 'owned_pid', return_value=True), \
             patch.object(windows.shutil, 'which', return_value='/test/aerospace'), \
             patch.object(windows.subprocess, 'check_output', return_value=json.dumps(monitors)), \
             patch.object(windows.subprocess, 'run') as run:
            with self.assertRaisesRegex(AssertionError, 'ownership'):
                windows.move_test_window(11, owner, 1)
        run.assert_not_called()

    def test_missing_display_is_not_replaced_by_an_arbitrary_monitor(self):
        owner = Mock(pid=10); owner.poll.return_value = None
        with patch.object(windows, 'float_test_windows', return_value={'after': [{'window-id': 42}]}), \
             patch.object(windows.shutil, 'which', return_value='/test/aerospace'), \
             patch.object(windows.subprocess, 'check_output', return_value='[]'), \
             patch.object(windows.subprocess, 'run') as run:
            with self.assertRaisesRegex(AssertionError, 'unavailable'):
                windows.move_test_window(11, owner, 1)
        run.assert_not_called()

    def test_rejects_exited_owner(self):
        owner = Mock(pid=10); owner.poll.return_value = 0
        with patch.object(windows.sys, 'platform', 'darwin'), \
             patch.object(windows.shutil, 'which', return_value='/test/aerospace'), \
             patch.object(windows.subprocess, 'check_output') as output:
            with self.assertRaisesRegex(AssertionError, 'live fixture'):
                windows.float_test_windows(10, owner)
        output.assert_not_called()


if __name__ == '__main__': unittest.main()
