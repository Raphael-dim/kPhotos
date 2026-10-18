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

"""Scan only publishable working files, then all locally reachable Git history."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    # An explicit executable also permits an independently checksum-verified install.
    executable = os.environ.get("GITLEAKS") or shutil.which("gitleaks")
    if not executable:
        executable = subprocess.check_output(["mise", "which", "gitleaks"], cwd=ROOT, text=True).strip()
    command = [executable]
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
    ).decode().split("\0")
    with tempfile.TemporaryDirectory(prefix="kphotos-publishable-") as directory:
        destination = Path(directory)
        for name in sorted(set(names) - {""}):
            source = ROOT / name
            if source.is_symlink():
                print(f"Review symlink before publication: {name}", file=sys.stderr)
                return 1
            if not source.is_file():
                continue
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        # Empty config prevents accidental loading of broad suppressions in the checkout.
        config = destination / ".gitleaks.toml"
        if config.exists():
            print("Review custom Gitleaks configuration before scanning", file=sys.stderr)
            return 1
        config.write_text("[extend]\nuseDefault = true\n")
        flags = ["--redact", "--no-banner", "--config", str(config), "--ignore-gitleaks-allow"]
        result = subprocess.run(command + ["dir", str(destination)] + flags, cwd=directory)
        if result.returncode:
            return result.returncode
        return subprocess.run(
            command + ["git", str(ROOT), "--log-opts=--all"] + flags, cwd=directory
        ).returncode


if __name__ == "__main__":
    sys.exit(main())
