#!/usr/bin/env python3
"""Portable receipt tests. No Swift build, AppKit, or body baking is invoked."""
import importlib.util
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('component_check', Path(__file__).with_name('component-check.py'))
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


class ReceiptTests(unittest.TestCase):
    def test_original_summary_formats(self):
        summaries = {
            'native': 'M1 verification: 101 checks, 2 findings -> /tmp/output',
            'settings': 'Settings 102 checks / 2 failures · 40 PNGs',
            'overlay': 'Overlay verification: 103 checks, 2 findings',
            'sheets': 'Sheets verification: 104 checks, 2 findings',
            'sheets-m101': 'M10.1 Sheets: 105 checks, 2 findings, 8 container findings; cost []',
            'debug': 'Debug verification: 106 checks, 2 failures',
            'tools': 'Tools verification: 107 checks, 2 findings',
            'header-ax': 'Header AX verification: 108 checks, 2 findings',
            'split': 'Split Dock: 109 checks, 2 failures',
            'split-model': 'Model sizing: 110 checks, 2 failures',
            'normie-motion': 'M10-C: 111 checks, 2 findings',
            'dock-switches': 'M10 Dock switches: 112 checks, 2 findings',
            'dock-gaussian': 'M10.1 Dock/island: 113 checks, 2 findings',
        }
        self.assertEqual(set(summaries), set(entry.KINDS))
        for index, (kind, summary) in enumerate(summaries.items(), 101):
            with self.subTest(kind=kind):
                self.assertEqual(entry.totals(kind, 'noise\n' + summary + '\nFAIL: detail\n', 1), (index, 2))

    def test_pass(self):
        self.assertEqual(entry.totals('split', 'Split Dock: 357 checks, 0 failures\n', 0), (357, 0))

    def test_incomplete_and_contradictory_runs(self):
        for log, code in [
            ('error: failed to compile', 1),
            ('Scroll verification: 12 checks, 0 findings', 0),
            ('M1 verification: 0 checks, 0 findings', 0),
            ('M1 verification: 12 checks, 0 findings\nM1 verification: 12 checks, 0 findings', 0),
            ('M1 verification: 12 checks, 0 findings', -5),
            ('M1 verification: 12 checks, 0 findings', 1),
            ('M1 verification: 12 checks, 2 findings', 0),
        ]:
            with self.subTest(log=log, code=code), self.assertRaises(ValueError):
                entry.totals('native', log, code)


class EntryTests(unittest.TestCase):
    def test_product_package_override_is_rejected_before_writing(self):
        root = Path(__file__).resolve().parents[2]
        for package in (root, root.parent, root / 'Sources/private', root / 'Resources/private'):
            with self.subTest(package=package), tempfile.TemporaryDirectory() as temporary:
                with patch.object(sys, 'argv', ['component-check', 'split', temporary]), \
                     patch.dict(os.environ, {'M11_CHECK_PACKAGE': str(package)}), \
                     self.assertRaises(ValueError):
                    entry.main()
                self.assertFalse((Path(temporary) / 'split').exists())

    def invoke(self, output, *, build_code=0, run_code=0, log='', compile_only=False):
        calls = []

        def logged(command, directory, name, **options):
            calls.append((command, options))
            (directory / (name + '.log')).write_bytes(log.encode('utf-8'))
            return build_code if name == 'build' else run_code

        transcript = io.StringIO()
        with patch.object(sys, 'argv', ['component-check', 'split', str(output)]), \
             patch.dict(os.environ, {'COMPONENT_COMPILE_ONLY': '1' if compile_only else '0',
                                     'M11_CHECK_PACKAGE': str(output / '.cache'), 'M9_ORBS_ONLY': '1'}), \
             patch.object(entry.subprocess, 'run') as prepare, \
             patch.object(entry.subprocess, 'check_output', return_value='/fake/bin\n'), \
             patch.object(entry, 'run_logged', side_effect=logged), \
             contextlib.redirect_stdout(transcript):
            code = entry.main()
        self.assertTrue((output / 'split/sources.txt').is_file())
        self.assertIn('--list', prepare.call_args_list[0].args[0])
        self.assertIn('M9_SPLIT_SELFTEST', prepare.call_args_list[1].args[0])
        return code, transcript.getvalue().splitlines()[-1], calls

    def test_compile_only_and_build_failure_never_launch(self):
        for build_code in (0, 1):
            with self.subTest(build_code=build_code), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                prior = output / 'split'
                prior.mkdir()
                (prior / 'component-result.json').write_bytes(b'{"checks": 123}')
                (prior / 'run.log').write_bytes(b'old passing run')
                code, last, calls = self.invoke(output, build_code=build_code, compile_only=True)
                self.assertEqual(code, 2 if build_code else 0)
                self.assertEqual(len(calls), 1)
                self.assertNotRegex(last, r'\d+ checks')
                self.assertFalse((prior / 'component-result.json').exists())
                self.assertFalse((prior / 'run.log').exists())

    def test_run_maps_findings_and_removes_partial_selector(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            code, last, calls = self.invoke(output, run_code=1, log='Split Dock: 357 checks, 4 failures\n')
            self.assertEqual(code, 1)
            self.assertEqual(last, 'COMPONENT split: 357 checks, 4 findings')
            self.assertEqual(len(calls), 2)
            self.assertNotIn('M9_ORBS_ONLY', calls[1][1]['env'])
            self.assertEqual(json.loads((output / 'split/component-result.json').read_text())['findings'], 4)

    def test_crash_and_missing_summary_do_not_write_receipt(self):
        for run_code, log in ((-5, 'Split Dock: 357 checks, 0 failures\n'), (0, 'partial output')):
            with self.subTest(run_code=run_code), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                code, last, _ = self.invoke(output, run_code=run_code, log=log)
                self.assertEqual(code, 3)
                self.assertNotRegex(last, r'\d+ checks')
                self.assertFalse((output / 'split/component-result.json').exists())


class ClockPackageTests(unittest.TestCase):
    def test_profiles_keep_resources_sources_and_receipts(self):
        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location('uptime_builder', root / 'scripts/build-uptime-harness.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        helper = builder.package_helper(root)
        originals = {path: hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in helper.collect(root).values()}
        for profile in ('split', 'full', 'm11'):
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / 'package'
                compiled = Path(temporary) / 'Check'
                compiled.write_bytes(b'fake executable; Swift must never run in this test')
                bundle_name = ('M111Check' if profile == 'm11' else 'UptimeHarness') + '_OrganicBodyResources.bundle'
                bundle = compiled.parent / bundle_name
                bundle.mkdir()
                (bundle / 'fixture').write_bytes(b'fake body resource')
                transcript = io.StringIO()
                with patch.object(builder, 'package_helper', return_value=helper), \
                     patch.object(helper, 'stage_bodies', return_value=Path(temporary) / 'body-assets'), \
                     patch.object(helper, 'link') as links, \
                     patch.object(builder.subprocess, 'run') as commands, \
                     patch.object(builder, 'release_binary', return_value=compiled), \
                     patch.object(sys, 'argv', ['builder', str(root), str(output), '--profile', profile]), \
                     contextlib.redirect_stdout(transcript):
                    builder.main()
                package = (output / 'Package.swift').read_text()
                self.assertEqual((output / 'fixed' / bundle_name / 'fixture').read_bytes(), b'fake body resource')
                self.assertIn('.target(name: "OrganicBodyResources", resources:', package)
                self.assertIn('dependencies: ["OrganicBodyResources"', package)
                self.assertTrue(any(call.args[0] == root / 'Resources/BodyResources.swift' for call in links.call_args_list))
                self.assertEqual(commands.call_args.args[0][-4:], ['-c', 'release', '-j', '4'])
                if profile == 'm11':
                    self.assertIn('.define("CHECK_PACKAGE_WHOLE_TREE")', package)
                    self.assertNotIn('SwiftTerm', package)
                    self.assertIn('UPTIME_M11_BINARY', transcript.getvalue())
                    self.assertTrue((output / 'fixed/Check').is_file())
                    for name in ('m11-1-check.swift', 'ModeRegressionChecks.swift'):
                        self.assertTrue(any(call.args[0].name == name for call in links.call_args_list))
                else:
                    self.assertIn('SwiftTerm', package)
                    self.assertIn('UPTIME_BINARY', transcript.getvalue())
                    self.assertTrue((output / 'fixed/UptimeHarness').is_file())
                    manifest = json.loads((output / 'source-manifest.json').read_text())
                    expected = len(originals) + (2 if profile == 'full' else 0)
                    self.assertEqual(len(manifest), expected)
                    driver = output / 'private-sources/UptimeHarness.swift'
                    self.assertIn('@main', driver.read_text())
                    for source in (output / 'private-sources').rglob('*.swift'):
                        if source != driver:
                            self.assertNotRegex(source.read_text(encoding='utf-8'), r'(?m)^\s*@main\b')
                self.assertEqual(originals, {path: hashlib.sha256(path.read_bytes()).hexdigest()
                                             for path in originals})


if __name__ == '__main__':
    unittest.main()
