#!/usr/bin/env python3
"""Collector and incremental-package checks; no Swift compiler or real sprites needed."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import check_package


class CheckPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=os.environ.get('CHECK_PACKAGE_TEST_TMP'))
        self.addCleanup(self.temporary.cleanup)
        temporary = Path(self.temporary.name).resolve()
        self.root = temporary / 'repo'
        self.product = self.root / 'Sources/OrganicShell'
        self.package = temporary / 'package'
        self.put('Sources/OrganicShell/App/Main.swift', '@main enum Main {}\n')
        self.original = self.put('Sources/OrganicShell/New/Nested/Leaf.swift', '// product\n')
        self.extra = self.put('tools/check.swift', '// check\n')
        self.put('Resources/BodyResources.swift', '// resources\n')
        self.assets = temporary / 'shared/BodyAssets.app'
        (self.assets / 'Contents/Resources/Bodies').mkdir(parents=True)
        (self.assets / 'Contents/Resources/Credits.rtf').write_bytes(b'credits\n')

    def put(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode('utf-8'))
        return path

    def test_new_directories_and_sources_are_discovered(self):
        self.put('Sources/OrganicShell/Future/Deeper/Next.swift', '// future\n')
        sources = check_package.collect(self.root, add=['tools/check.swift'])
        self.assertEqual(set(sources), {'Leaf.swift', 'Next.swift', 'check.swift'})

    def test_exclusions_are_exact_and_stale_entries_fail(self):
        for value in ('Leaf.swift', 'New/Nested/Leaf.swift',
                      'Sources/OrganicShell/New/Nested/Leaf.swift'):
            self.assertEqual(check_package.collect(self.root, exclude=[value]), {})
        with self.assertRaisesRegex(ValueError, 'matches no product source'):
            check_package.collect(self.root, exclude=['Old.swift'])
        (self.product / 'App/Main.swift').unlink()
        with self.assertRaisesRegex(ValueError, 'matches no product source'):
            check_package.collect(self.root)

    def test_duplicate_basename_reports_both_paths(self):
        duplicate = self.put('Sources/OrganicShell/Other/Leaf.swift', '// duplicate\n')
        with self.assertRaisesRegex(ValueError, 'Duplicate source basename') as caught:
            check_package.collect(self.root)
        self.assertIn(str(self.original), str(caught.exception))
        self.assertIn(str(duplicate), str(caught.exception))
        duplicate.unlink()
        with self.assertRaisesRegex(ValueError, 'Duplicate source basename'):
            check_package.collect(self.root, add=[self.original])

    def test_replacements_must_identify_one_included_product_file(self):
        mutant = self.put('mutants/changed.swift', '// mutant\n')
        sources = check_package.collect(self.root, replacement={'Leaf.swift': mutant})
        self.assertEqual(sources['Leaf.swift'], mutant)
        for name in ('Absent.swift', 'Main.swift', 'check.swift'):
            with self.assertRaisesRegex(ValueError, 'one included product source'):
                check_package.collect(self.root, add=[self.extra], replacement={name: mutant})
        with self.assertRaisesRegex(ValueError, 'Repeated replacement'):
            check_package.collect(self.root, replacement={
                'Leaf.swift': mutant, 'New/Nested/Leaf.swift': mutant})

    def test_list_is_sorted_and_does_not_touch_anything(self):
        def snapshot():
            return {str(path): path.lstat().st_mtime_ns for path in self.root.rglob('*')}
        before = snapshot()
        output = subprocess.check_output([
            sys.executable, '-B', str(Path(check_package.__file__).resolve()),
            '--root', str(self.root), '--package', str(self.package),
            '--body-assets', str(self.package / 'never-created'),
            '--add', 'tools/check.swift', '--list'], text=True)
        self.assertEqual(output.splitlines(), [
            'Resources/BodyResources.swift', 'Sources/OrganicShell/New/Nested/Leaf.swift',
            'tools/check.swift', '3 sources'])
        self.assertEqual(snapshot(), before)
        self.assertFalse(self.package.exists())

    def test_incremental_links_manifest_and_mutant_restoration(self):
        def prepare(**kwargs):
            with patch.object(check_package, 'stage_bodies', return_value=self.assets):
                return check_package.prepare(self.root, self.package, add=[self.extra],
                                             define=['M11_MODE_SELFTEST'], **kwargs)
        prepare()
        directory = self.package / 'Sources/Check'
        manifest = self.package / 'Package.swift'
        link = directory / 'Leaf.swift'
        # Fixed old timestamps make accidental rewrites visible without sleeps.
        os.utime(manifest, ns=(1_000_000_000, 1_000_000_000))
        os.utime(link, ns=(1_000_000_000, 1_000_000_000), follow_symlinks=False)
        before = (manifest.stat().st_mtime_ns, link.lstat().st_mtime_ns)
        prepare()
        self.assertEqual(before, (manifest.stat().st_mtime_ns, link.lstat().st_mtime_ns))
        self.assertNotIn(b'\r', manifest.read_bytes())
        body_link = self.package / 'Sources/OrganicBodyResources/Bodies'
        self.assertTrue(body_link.is_symlink())
        self.assertEqual(body_link.resolve(), self.assets / 'Contents/Resources/Bodies')
        link.unlink()
        link.symlink_to(os.path.relpath(self.original, directory))
        os.utime(link, ns=(1_000_000_000, 1_000_000_000), follow_symlinks=False)
        prepare()
        self.assertEqual(link.lstat().st_mtime_ns, 1_000_000_000)
        mutant = self.put('mutants/mutant.swift', '// mutant\n')
        prepare(replacement={'Leaf.swift': mutant})
        self.assertEqual(link.resolve(), mutant)
        prepare()
        self.assertEqual(link.resolve(), self.original)
        # Restore an old caller's copied mutant too, and remove dangling stale links.
        link.unlink()
        link.write_bytes(b'// old copied mutant\n')
        (directory / 'Obsolete.swift').symlink_to(self.root / 'missing.swift')
        prepare()
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), self.original)
        self.assertFalse((directory / 'Obsolete.swift').is_symlink())

    def test_shared_body_staging_reuses_bundle_and_invalidates_inputs(self):
        self.put('scripts/build-body-assets.py', 'def input_key(root): return "verified-key"\n')
        self.put('scripts/package-bodies.sh', '# product staging\n')
        self.put('Resources/Credits.rtf', 'credits\n')
        directory = self.assets.parent

        def bake(*args, **kwargs):
            sprites = self.assets / 'Contents/Resources/Bodies/Sprites'
            sprites.mkdir(parents=True, exist_ok=True)
            (sprites / 'index.json').write_bytes(b'{}\n')

        with patch.object(check_package.subprocess, 'run', side_effect=bake) as run:
            self.assertEqual(check_package.stage_bodies(self.root, directory), self.assets)
            check_package.stage_bodies(self.root, directory)
            self.assertEqual(run.call_count, 1)
            self.put('Resources/Credits.rtf', 'updated credits\n')
            check_package.stage_bodies(self.root, directory)
            self.assertEqual(run.call_count, 2)
        self.assertFalse((self.root / 'scripts/__pycache__').exists())


if __name__ == '__main__':
    unittest.main()
