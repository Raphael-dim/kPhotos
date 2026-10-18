#!/usr/bin/env bash
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

# Refresh the unmodified public kDrive export, or import an explicit official file.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/docs/api/infomaniak_openapi.json"
TEMP_SPEC="$(mktemp "${TARGET}.XXXXXX")"
trap 'rm -f "$TEMP_SPEC"' EXIT
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [official-export.json]" >&2
    exit 2
elif [[ $# -eq 1 ]]; then
    cp -- "$1" "$TEMP_SPEC"
else
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 --get --data-urlencode 'categories[0]=kDrive' \
        'https://developer.infomaniak.com/download' --output "$TEMP_SPEC"
fi
python3 - "$TARGET" "$TEMP_SPEC" <<'PYTHON'
import hashlib
import json
import pathlib
import sys
old_path, new_path = map(pathlib.Path, sys.argv[1:])
raw = new_path.read_bytes()
if len(raw) > 10 * 1024 * 1024:
    raise SystemExit("Export exceeds the 10 MiB documentation budget")
new = json.loads(raw)
paths = new.get("paths", {})
required = {
    "/3/drive/{drive_id}/upload",
    "/3/drive/{drive_id}/files/{file_id}/files",
    "/3/drive/{drive_id}/files/{file_id}/directory",
    "/3/drive/{drive_id}/upload/session/start",
}
if not new.get("openapi", "").startswith("3.") or not required.issubset(paths):
    raise SystemExit("Invalid OpenAPI export or required kDrive routes missing")
if any(not (p == "/2/drive" or p.startswith(("/2/drive/", "/3/drive/", "/2/app/{drive_id}/share/"))) for p in paths):
    raise SystemExit("Export must contain only the kDrive category")
old = json.loads(old_path.read_bytes()) if old_path.exists() else {"paths": {}}
a, b = old["paths"], paths
print(f"Validated OpenAPI {new['openapi']}: {len(b)} paths")
print(f"Added: {len(b.keys() - a.keys())}; removed: {len(a.keys() - b.keys())}; "
      f"changed: {sum(a[p] != b[p] for p in a.keys() & b.keys())}")
print("SHA-256:", hashlib.sha256(raw).hexdigest())
PYTHON
chmod 644 "$TEMP_SPEC"
mv -f "$TEMP_SPEC" "$TARGET"
echo "Updated public kDrive reference. Review the diff and update docs/api/README.md provenance."
