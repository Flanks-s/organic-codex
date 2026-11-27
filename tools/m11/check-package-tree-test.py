#!/usr/bin/env python3
"""Portable keep-tree tests; body baking, linking and Swift builds are not run."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(os.environ.get('CHECK_PACKAGE_ROOT', Path(__file__).resolve().parents[2])).resolve()
HELPER = Path(os.environ.get('CHECK_PACKAGE_HELPER', ROOT / 'tools/m11/check_package.py'))
BASELINE = os.environ.get('CHECK_PACKAGE_BASELINE')


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


helper = module(HELPER, 'tree_test_helper')


class LayoutTests(unittest.TestCase):
    @unittest.skipUnless(BASELINE, 'Set CHECK_PACKAGE_BASELINE to compare the unchanged helper')
    def test_default_manifest_links_and_return_are_identical(self):
        old = module(BASELINE, 'tree_test_baseline')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            package = directory / 'package'
            options = dict(name='M111Check', define=['M11_MODE_SELFTEST', 'CHECK_PACKAGE_WHOLE_TREE'],
                           add=['tools/m11/m11-1-check.swift', 'tools/m11/ModeRegressionChecks.swift'])
            with patch.object(old, 'stage_bodies', return_value=directory/'assets'), patch.object(old, 'link') as old_links:
                old_result = old.prepare(ROOT, package, **options)
            manifest = (package/'Package.swift').read_bytes()
            with patch.object(helper, 'stage_bodies', return_value=directory/'assets'), patch.object(helper, 'link') as new_links:
                new_result = helper.prepare(ROOT, package, **options)
            self.assertEqual(manifest, (package/'Package.swift').read_bytes())
            self.assertEqual(old_links.call_args_list, new_links.call_args_list)
            self.assertEqual(old_result, new_result)

    @unittest.skipUnless(BASELINE, 'Set CHECK_PACKAGE_BASELINE to compare the unchanged helper')
    def test_default_list_is_byte_identical(self):
        args = ['--root', str(ROOT), '--list']
        before = subprocess.check_output([sys.executable, BASELINE, *args])
        after = subprocess.check_output([sys.executable, str(HELPER), *args])
        self.assertEqual(before, after)

    def test_tree_retains_product_and_repository_driver_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            package = (directory/'package').resolve()
            with patch.object(helper, 'stage_bodies', return_value=directory/'assets'), patch.object(helper, 'link') as links:
                sources = helper.prepare(ROOT, package, keep_tree=True, add=['tools/m11/m11-1-check.swift'])
            for name, source in sources.items():
                expected = package/'Sources/Check'/source.relative_to(ROOT)
                self.assertTrue(any(call.args == (source, expected) for call in links.call_args_list), str(expected))
            self.assertTrue(any(call.args[0] == ROOT/'Resources/BodyResources.swift' for call in links.call_args_list))

    def test_replacement_uses_original_repository_directory(self):
        original = next(iter(helper.collect(ROOT).values()))
        with tempfile.TemporaryDirectory() as temporary:
            replacement = Path(temporary)/'replacement.swift'
            replacement.write_bytes(b'// private replacement fixture\n')
            sources = helper.collect(ROOT, replacement={original.name: replacement})
            paths = helper.tree_sources(ROOT, sources, helper.collect(ROOT))
            self.assertEqual(paths[original.relative_to(ROOT).as_posix()], replacement.resolve())
            self.assertFalse(any(name.endswith('/replacement.swift') for name in paths))

    def test_external_driver_is_stable_and_after_product_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            driver = Path(temporary)/'GeneratedClockDriver.swift'
            driver.write_bytes(b'// private generated driver fixture\n')
            sources = helper.collect(ROOT, add=[driver])
            paths = helper.tree_sources(ROOT, sources, sources)
            self.assertEqual(paths['tools/added/GeneratedClockDriver.swift'], driver.resolve())
            self.assertGreater('tools/added/GeneratedClockDriver.swift', 'Sources/OrganicShell/')

    def test_tree_sync_removes_flat_and_nested_stale_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            directory = base/'Check'
            (directory/'old').mkdir(parents=True)
            (directory/'Old.swift').write_bytes(b'old flat')
            (directory/'old/stale.swift').write_bytes(b'old nested')
            source = base/'Current.swift'
            source.write_bytes(b'// current fixture\n')
            def copy(source, destination):
                destination.write_bytes(source.read_bytes())
            with patch.object(helper, 'link', side_effect=copy):
                helper.link_tree(directory, {'Sources/OrganicShell/Engine/Current.swift': source})
            self.assertFalse((directory/'Old.swift').exists())
            self.assertFalse((directory/'old').exists())
            self.assertEqual((directory/'Sources/OrganicShell/Engine/Current.swift').read_bytes(), source.read_bytes())


if __name__ == '__main__':
    unittest.main()
