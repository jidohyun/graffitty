"""Resource thresholds must still fail after collecting the final video sample."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

from test_chromium_platform_stress import finish_soak


class StressEvidenceTest(unittest.TestCase):
    def points(self, key=None, growth=0):
        values = [dict(server_rss=10, descendant_rss=20, server_handles=3) for _ in range(12)]
        if key:
            for point in values[-3:]: point[key] += growth
        return values

    def test_each_original_limit_still_fails_after_final_decode(self):
        for key, limit in [('server_rss', 128*1024**2), ('descendant_rss', 256*1024**2), ('server_handles', 32)]:
            with self.subTest(key=key):
                records = []
                decode = Mock(return_value={'decoded_frames': 60})
                with self.assertRaises(AssertionError):
                    finish_soak(self.points(key, limit+1), 120, decode,
                                lambda phase, value: records.append((phase, deepcopy(value))))
                decode.assert_called_once_with()
                final = records[-1][1]
                self.assertEqual(final['resource_failures'], [key])
                self.assertEqual(final['growth'][key]['limit'], limit)
                self.assertEqual(final['decode']['decoded_frames'], 60)

    def test_decode_error_keeps_resource_evidence(self):
        records = []
        with self.assertRaisesRegex(RuntimeError, 'decoder failed'):
            finish_soak(self.points('server_handles', 33), 120,
                        Mock(side_effect=RuntimeError('decoder failed')),
                        lambda phase, value: records.append(deepcopy(value)))
        self.assertEqual(records[-1]['decode_error'], 'decoder failed')
        self.assertEqual(records[-1]['resource_failures'], ['server_handles'])
        self.assertEqual(records[-1]['samples'], 12)

    def test_exact_threshold_is_accepted(self):
        records = []
        finish_soak(self.points('descendant_rss', 256*1024**2), 120,
                    lambda: {'decoded_frames': 60}, lambda phase, value: records.append(deepcopy(value)))
        self.assertEqual(records[-1]['resource_failures'], [])
        self.assertEqual(records[-1]['decode']['decoded_frames'], 60)


if __name__ == '__main__': unittest.main()
