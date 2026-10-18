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

"""Idempotent Realm Core compatibility fixes for Xcode 27.

The Realm Core resource bundle inherits iOS 12 from its package manifest,
which Xcode 27 rejects. kPhotos targets iOS 16.6.
Upstream diagnosis: https://github.com/realm/realm-core/issues/8101
The ordering is unchanged; libc++ now also requires an actual operator<.
Remove this shim once the resolved Realm Core includes the upstream fix.
"""
from pathlib import Path

realm_checkout = Path(__file__).resolve().parents[1] / "Tuist/.build/checkouts/realm-core"
manifest = realm_checkout / "Package.swift"
manifest_text = manifest.read_text()
if '.iOS(.v12)' in manifest_text:
    manifest.chmod(manifest.stat().st_mode | 0o200)
    manifest.write_text(manifest_text.replace('.iOS(.v12)', '.iOS("16.6")', 1))
elif '.iOS("16.6")' not in manifest_text:
    raise SystemExit("Realm Core changed: review its iOS deployment target before rebuilding.")

source = realm_checkout / "src/external/s2/s2polyline.cc"
text = source.read_text()
marker = "  // kPhotos: Xcode 27 libc++ compatibility (realm-core #8101)."
if marker not in text:
    before = "  int i;\n  int j;\n  bool i_in_progress;\n};"
    after = """  // kPhotos: Xcode 27 libc++ compatibility (realm-core #8101).
  bool operator<(const SearchState& rhs) const {
    if (i == rhs.i && j == rhs.j) return i_in_progress < rhs.i_in_progress;
    return i == rhs.i ? j < rhs.j : i < rhs.i;
  }
  int i;
  int j;
  bool i_in_progress;
};"""
    if before not in text:
        raise SystemExit("Realm Core changed: review the Xcode 27 compatibility shim before rebuilding.")
    source.chmod(source.stat().st_mode | 0o200)
    source.write_text(text.replace(before, after, 1))
print("Realm compatibility checked.")
