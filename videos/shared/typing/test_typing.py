import importlib.util
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('typing_build', HERE/'build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class HumanTiming(unittest.TestCase):
    def test_preserves_whole_word_rhythm(self):
        model = {'word_traces_ms': {'hello': [[50, 200, 50, 200]]}, 'pairs_ms': {}, 'classes_ms': {'all': [100]}}
        frames = build.schedule('hello', 'prose', model, 0)['frames_before']
        self.assertGreater(frames[2], frames[1] * 2)
        self.assertGreater(frames[4], frames[3] * 2)

    def test_unknown_commands_have_deterministic_fallback(self):
        model = {'word_traces_ms': {}, 'pairs_ms': {}, 'classes_ms': {'all': [40, 70, 110, 180, 250]}}
        text = ':Unseen_Command42'
        a = build.schedule(text, 'command', model, 1)
        self.assertEqual(a, build.schedule(text, 'command', model, 1))
        self.assertEqual(len(a['frames_before']), len(text))
        self.assertEqual(a['sources']['keyboard_class'], len(text)-1)
        self.assertGreater(len(set(a['frames_before'][1:])), 2)

    def test_saved_demo_plans_match_model_and_have_variation(self):
        model = json.loads((HERE/'model.json').read_text(encoding='utf-8'))
        plans = json.loads((HERE/'timings.json').read_text(encoding='utf-8'))
        manifest = json.loads((HERE/'phrases.json').read_text(encoding='utf-8'))
        self.assertGreaterEqual(model['stats']['clean_sections'], 1000)
        self.assertEqual(plans['archive_sha256'], model['archive_sha256'])
        for profile, texts in manifest.items():
            for text in texts:
                variants = plans['phrases'][text]['variants']
                self.assertEqual(variants, [build.schedule(text, profile, model, i) for i in range(4)])
                for variant in variants:
                    frames = variant['frames_before']
                    self.assertEqual(len(frames), len(text))
                    self.assertEqual(frames[0], 0)
                    self.assertTrue(all(2 <= f <= 30 for f in frames[1:]))
                    self.assertLess(sum(frames)/60, max(2, len(text)*.16))
                    if len(text) > 15: self.assertGreater(len(set(frames[1:])), 3)
        preview = plans['phrases'][':MarkdownPreview']['variants']
        self.assertTrue(all(sum(v['frames_before'])/60 < 2 for v in preview))


if __name__ == '__main__': unittest.main()
