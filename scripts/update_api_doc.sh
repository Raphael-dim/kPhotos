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

# Updates docs/api/infomaniak_openapi.json from the latest manual download.
#
# Workflow:
#   1. Open https://developer.infomaniak.com/docs/api in the browser
#   2. Click "Download" (file is saved as ~/Downloads/infomaniak_api_<unix_ts>.json)
#   3. Run this script — it picks the newest matching file and copies it in
#
# The dev portal generates a fresh signed URL per click — there is no stable
# direct download URL we can curl, hence this manual step.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADS_DIR="${HOME}/Downloads"
TARGET="${REPO_ROOT}/docs/api/infomaniak_openapi.json"
PORTAL_URL="https://developer.infomaniak.com/docs/api"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

echo -e "${BOLD}Infomaniak OpenAPI spec — update${NC}"
echo

# 1. Show current spec freshness
if [[ -f "$TARGET" ]]; then
    if stat -f%Sm "$TARGET" >/dev/null 2>&1; then
        AGE_DAYS=$(( ( $(date +%s) - $(stat -f%m "$TARGET") ) / 86400 ))
    else
        AGE_DAYS=$(( ( $(date +%s) - $(stat -c%Y "$TARGET") ) / 86400 ))
    fi
    echo -e "  current: $(du -h "$TARGET" | awk '{print $1}'), $AGE_DAYS day(s) old"
    if [[ $AGE_DAYS -gt 30 ]]; then
        echo -e "  ${YELLOW}⚠️  more than 30 days old — refresh recommended${NC}"
    fi
fi

# 2. Open the portal
echo
echo -e "${BLUE}→${NC} Opening $PORTAL_URL ..."
open "$PORTAL_URL" 2>/dev/null || echo "  (couldn't open browser — visit manually)"

# 3. Wait for the user
echo
echo -e "${BOLD}Now in the browser:${NC}"
echo "  1. Find the 'Download' button (top-right of the API reference page)"
echo "  2. Click it → file lands in $DOWNLOADS_DIR/infomaniak_api_<timestamp>.json"
echo
echo -e "${DIM}Press <ENTER> when the download is done...${NC}"
read -r _

# 4. Find newest matching file
shopt -s nullglob
candidates=("$DOWNLOADS_DIR"/infomaniak_api_*.json)
shopt -u nullglob
if [[ ${#candidates[@]} -eq 0 ]]; then
    echo -e "${RED}ERROR${NC}: no infomaniak_api_*.json found in $DOWNLOADS_DIR"
    exit 1
fi

LATEST=""; LATEST_MTIME=0
for f in "${candidates[@]}"; do
    if stat -f%m "$f" >/dev/null 2>&1; then mt=$(stat -f%m "$f"); else mt=$(stat -c%Y "$f"); fi
    if (( mt > LATEST_MTIME )); then LATEST_MTIME=$mt; LATEST="$f"; fi
done

echo
echo -e "${BLUE}→${NC} Latest download: $LATEST"

# 5. Validate it's a valid JSON OpenAPI spec
if ! python3 -c "
import json, sys
spec = json.load(open('$LATEST'))
assert spec.get('openapi','').startswith('3.'), 'not OpenAPI 3.x'
n = len(spec.get('paths',{}))
drive = sum(1 for p in spec.get('paths',{}) if 'drive' in p.lower())
print(f'  validated: OpenAPI {spec[\"openapi\"]}, {n} paths ({drive} kDrive)')
" 2>/dev/null; then
    echo -e "${RED}ERROR${NC}: $LATEST is not a valid OpenAPI 3.x spec"
    exit 1
fi

# 6. Show diff vs current (high-level)
if [[ -f "$TARGET" ]]; then
    echo
    echo -e "${BLUE}→${NC} Diff vs current spec:"
    python3 -c "
import json
old = json.load(open('$TARGET'))
new = json.load(open('$LATEST'))
old_p = set(old.get('paths', {}).keys())
new_p = set(new.get('paths', {}).keys())
added = sorted(new_p - old_p)
removed = sorted(old_p - new_p)
print(f'  + {len(added)} new path(s)')
for p in added[:20]: print(f'      + {p}')
if len(added) > 20: print(f'      ... and {len(added)-20} more')
print(f'  - {len(removed)} removed path(s)')
for p in removed[:20]: print(f'      - {p}')
if len(removed) > 20: print(f'      ... and {len(removed)-20} more')
if old.get('info',{}).get('version') != new.get('info',{}).get('version'):
    print(f'  info.version: {old.get(\"info\",{}).get(\"version\")} → {new.get(\"info\",{}).get(\"version\")}')
"
fi

# 7. Copy in
cp "$LATEST" "$TARGET"
echo
echo -e "${GREEN}✓${NC} Updated $TARGET"
echo
echo -e "${DIM}Tip: commit the change with a message like 'chore: refresh Infomaniak OpenAPI spec'${NC}"
