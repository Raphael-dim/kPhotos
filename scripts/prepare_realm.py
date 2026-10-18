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

"""Raise Realm Core's resource bundle deployment target for Xcode 27.

The Realm Core resource bundle inherits iOS 12 from its package manifest,
which Xcode 27 rejects. kPhotos targets iOS 16.6.
Realm Core 20.1.5 already includes the C++ compatibility fix; leave its
sources intact. Remove this shim when the upstream manifest is compatible.
"""

from pathlib import Path


def prepare_realm(checkout: Path):
    manifest = checkout / "Package.swift"
    manifest_text = manifest.read_text(encoding="utf-8")
    if '.iOS(.v12)' in manifest_text:
        manifest.chmod(manifest.stat().st_mode | 0o200)
        manifest.write_text(manifest_text.replace('.iOS(.v12)', '.iOS("16.6")', 1), encoding="utf-8")
    elif '.iOS("16.6")' not in manifest_text:
        raise SystemExit("Realm Core changed: review its iOS deployment target before rebuilding.")


if __name__ == "__main__":
    prepare_realm(Path(__file__).resolve().parents[1] / "Tuist/.build/checkouts/realm-core")
    print("Realm compatibility checked.")
