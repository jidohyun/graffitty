"""A missing frontend binding must never make a shared requirement pass."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('shared_e2e',ROOT/'tests/llm-e2e/shared_e2e.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)

class SharedCatalogTests(unittest.TestCase):
    def test_windows_requirements_are_inapplicable_elsewhere_not_passes(self):
        case={'platforms':['windows'],'adapters':{}}
        with patch.object(runner.os, 'name', 'posix'), patch.object(runner.sys, 'platform', 'linux'):
            result=runner.planned(case,'godot')
        self.assertEqual(result['status'],'NOT_APPLICABLE')
        self.assertEqual(runner.overall({'windows':{'godot':result}}),'NOT_APPLICABLE')
        with patch.object(runner.os, 'name', 'nt'):
            self.assertEqual(runner.planned(case,'godot')['status'],'BLOCKED')

    def test_native_focus_requires_explicit_headful_execution(self):
        case={'requires_headful':True,'adapters':{'godot':{'kind':'godot-replay'}}}
        self.assertEqual(runner.planned(case,'godot')['status'],'BLOCKED')
        self.assertEqual(runner.planned(case,'godot',headful=True)['status'],'NOT_RUN')

    def test_every_repository_requirement_requires_all_frontends_and_resolves(self):
        cases=runner.catalog()
        self.assertGreater(len(cases),100)
        self.assertTrue(all(set(c['required_frontends'])==set(runner.FRONTENDS) for c in cases))
        self.assertIn('tabs-and-panes/fit-to-pane',{c['id'] for c in cases})

    def test_missing_frontend_cannot_inherit_another_frontends_pass(self):
        case={'adapters':{'godot':{'kind':'godot-replay'}}}
        self.assertEqual(runner.planned(case,'other')['status'],'BLOCKED')
        self.assertEqual(runner.planned({'adapters':{'another':{'kind':'python'}}},'other')['status'],'BLOCKED')
        matrix={'fit':{'godot':{'status':'PASS'},'other':runner.planned(case,'other')}}
        self.assertEqual(runner.overall(matrix),'BLOCKED')
        matrix['fit']['godot']['status']='FAIL'
        self.assertEqual(runner.overall(matrix),'FAIL')

    def test_catalog_rejects_omitted_frontend_and_cross_engine_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory)/'workspace';folder.mkdir()
            (folder/'case.md').write_text('Required behavior')
            (folder/'case.gd').write_text('extends SceneTree')
            path=folder/'case.toml'
            path.write_text('required_frontends=[]\n')
            with self.assertRaises(ValueError):runner.catalog(Path(directory))
            path.write_text('required_frontends=["godot"]\n[adapters.other]\nkind="godot-replay"\nreplay="case.gd"\n')
            with self.assertRaisesRegex(ValueError,'unknown frontend adapter'):runner.catalog(Path(directory))

if __name__=='__main__':unittest.main()
