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

"""Check first-party source headers against the shared GPL template."""

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def main():
    template = (ROOT / "file-header-template.txt").read_text(encoding="utf-8").rstrip()
    comment_header = "\n".join("#" + line for line in template.splitlines()[1:-1])
    files = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
         "--", "*.swift", "*.py", "*.sh"], cwd=ROOT
    ).decode("utf-8").split("\0")
    failures = []
    checked = 0
    for name in sorted(set(files) - {""}):
        path = ROOT / name
        if not path.is_file():
            continue
        source = path.read_text(encoding="utf-8")
        # SwiftPM and executable scripts require their directive on the first line.
        if source.startswith(("// swift-tools-version:", "#!")):
            source = source.partition("\n")[2].lstrip("\n")
        expected = template if path.suffix == ".swift" else comment_header
        if not source.startswith(expected + "\n"):
            failures.append(name)
        checked += 1
    if failures:
        print("Source headers differ from file-header-template.txt:", file=sys.stderr)
        for name in failures:
            print(f"  {name}", file=sys.stderr)
        return 1
    print(f"Verified GPL headers in {checked} source files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
