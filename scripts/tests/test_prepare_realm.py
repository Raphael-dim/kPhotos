#!/usr/bin/env python3
# kPhotos - iOS client for kDrive
# Copyright (C) 2026 Raphaël Dimeck
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

"""Regression coverage for the reviewed Realm checkout adjustment."""

from pathlib import Path
import tempfile
import unittest

from scripts.prepare_realm import prepare_realm


class PrepareRealmTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.checkout = Path(self.directory.name)
        self.manifest = self.checkout / "Package.swift"
        self.source = self.checkout / "src/external/s2/s2polyline.cc"
        self.source.parent.mkdir(parents=True)
        # Keep the upstream comparator and the field tail that triggered the old patch.
        self.original_source = b"""struct SearchState {
  inline bool operator<(SearchState const& rhs) const {
    if (i < rhs.i) return true;
    if (i > rhs.i) return false;
    if (j < rhs.j) return true;
    if (j > rhs.j) return false;
    return !i_in_progress && rhs.i_in_progress;
  }
  int i;
  int j;
  bool i_in_progress;
};
"""
        self.source.write_bytes(self.original_source)

    def test_read_only_manifest_is_updated_without_repatching_upstream_cpp(self):
        self.manifest.write_text('platforms: [.iOS(.v12)],', encoding="utf-8")
        self.manifest.chmod(0o444)

        prepare_realm(self.checkout)
        prepare_realm(self.checkout)

        self.assertEqual(self.manifest.read_text(), 'platforms: [.iOS("16.6")],')
        self.assertEqual(self.source.read_bytes(), self.original_source)

    def test_prepared_manifest_is_unchanged(self):
        original = b'platforms: [.iOS("16.6")],'
        self.manifest.write_bytes(original)
        self.manifest.chmod(0o444)

        prepare_realm(self.checkout)

        self.assertEqual(self.manifest.read_bytes(), original)
        self.assertEqual(self.manifest.stat().st_mode & 0o777, 0o444)
        self.assertEqual(self.source.read_bytes(), self.original_source)

    def test_unknown_target_fails_without_modifying_the_checkout(self):
        original = b'platforms: [.iOS(.v15)],'
        self.manifest.write_bytes(original)

        with self.assertRaisesRegex(SystemExit, "review its iOS deployment target"):
            prepare_realm(self.checkout)

        self.assertEqual(self.manifest.read_bytes(), original)
        self.assertEqual(self.source.read_bytes(), self.original_source)


if __name__ == "__main__":
    unittest.main()
