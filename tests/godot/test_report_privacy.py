"""Published evidence must not expose the recorder's filesystem identity."""
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import report_privacy


class ReportPrivacyTest(unittest.TestCase):
    def test_specific_repository_replacement_precedes_home(self):
        with patch.object(report_privacy, 'ROOT', Path('/home/demo/project')), patch.object(Path, 'home', return_value=Path('/home/demo')):
            original = {'repo': '/home/demo/project/tests', 'cache': '/home/demo/.cache', 'relative': 'tests/report.json'}
            result = json.loads(report_privacy.public_text(json.dumps(original)))
            self.assertEqual(result, {'repo': '${REPO}/tests', 'cache': '${HOME}/.cache', 'relative': 'tests/report.json'})

    def test_json_escaped_windows_paths_remain_valid(self):
        with patch.object(report_privacy, 'ROOT', Path(r'C:\Users\demo\project')), patch.object(Path, 'home', return_value=Path(r'C:\Users\demo')):
            result = json.loads(report_privacy.public_text(json.dumps({'path': r'C:\Users\demo\project\tests'})))
            self.assertEqual(result, {'path': '${REPO}\\tests'})


if __name__ == '__main__':
    unittest.main()
