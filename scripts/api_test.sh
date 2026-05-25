#!/usr/bin/env bash
# kPhotos — kDrive API empirical test suite.
# Probes what's possible with a given PAT against the real kDrive API.
#
# All three variables are REQUIRED. No defaults — the script must never
# accidentally talk to someone else's drive.
#
# Usage:
#   export PAT='your_personal_access_token'
#   export DRIVE_ID='your_numeric_drive_id'
#   export TEST_FOLDER_ID='your_test_folder_id'  # a folder you already own
#   ./scripts/api_test.sh
#
# Each test prints: URL called, request body, HTTP status, response body, interpretation.
# A summary table at the end shows which operations work.

set -uo pipefail

: "${PAT:?ERROR: set PAT environment variable (your kDrive Personal Access Token)}"
: "${DRIVE_ID:?ERROR: set DRIVE_ID environment variable (your numeric kDrive id)}"
: "${TEST_FOLDER_ID:?ERROR: set TEST_FOLDER_ID environment variable (a folder you already own)}"

ROOT_FOLDER_ID="1"
HOST_KDRIVE="https://api.kdrive.infomaniak.com"
HOST_GENERIC="https://api.infomaniak.com"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

HAS_JQ=0
command -v jq >/dev/null 2>&1 && HAS_JQ=1

# Cleanup list (file IDs created during tests, to be trashed at the end).
declare -a CREATED_IDS=()

# Results: each is "STATUS|TEST_NAME"
declare -a RESULTS=()

format_body() {
    local body="$1"
    if [[ $HAS_JQ -eq 1 ]]; then
        echo "$body" | jq -C '.' 2>/dev/null | head -40 || echo "$body" | head -c 800
    else
        echo "$body" | head -c 800
    fi
}

interpret() {
    local code="$1" body="$2" name="$3"
    if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        echo -e "  ${GREEN}✅ SUCCESS${NC}"
        RESULTS+=("OK    |$name")
        return 0
    fi
    case "$code" in
        401) echo -e "  ${RED}❌ AUTH FAILED${NC} — token rejected (invalid or expired)"; RESULTS+=("AUTH  |$name") ;;
        403) echo -e "  ${RED}❌ FORBIDDEN${NC} — scope or kDrive role insufficient"; RESULTS+=("FORBID|$name") ;;
        404) echo -e "  ${RED}❌ NOT FOUND${NC} — wrong path or resource doesn't exist"; RESULTS+=("404   |$name") ;;
        429) echo -e "  ${YELLOW}⚠️  RATE LIMITED${NC} — 60 req/min hit"; RESULTS+=("RATE  |$name") ;;
        400)
            if echo "$body" | grep -q "permission_denied"; then
                echo -e "  ${RED}❌ PERMISSION DENIED${NC} (400 + permission_denied) — your PAT/role cannot do this operation"
                RESULTS+=("PERM  |$name")
            elif echo "$body" | grep -q "validation_failed\|invalid"; then
                echo -e "  ${YELLOW}⚠️  BAD REQUEST${NC} — body/params wrong (not a permission issue)"
                RESULTS+=("BAD   |$name")
            else
                echo -e "  ${YELLOW}⚠️  HTTP 400${NC} — see body above"
                RESULTS+=("400   |$name")
            fi
            ;;
        000) echo -e "  ${RED}❌ NETWORK FAILURE${NC} — no HTTP response (DNS, TLS, connectivity)"; RESULTS+=("NET   |$name") ;;
        *)   echo -e "  ${YELLOW}❓ UNEXPECTED ${code}${NC}"; RESULTS+=("$code  |$name") ;;
    esac
    return 1
}

# Generic test runner for GET / POST-JSON / DELETE requests.
# Args: name, method, url, [json_body]
run_test() {
    local name="$1" method="$2" url="$3" body="${4:-}"
    echo
    echo -e "${BOLD}─── $name ───${NC}"
    echo -e "${BLUE}→ $method${NC} $url"
    [[ -n "$body" ]] && echo -e "${DIM}  body: $body${NC}"

    local tmp; tmp=$(mktemp)
    local http_code start_ts end_ts elapsed
    start_ts=$(date +%s%N)

    if [[ -n "$body" ]]; then
        http_code=$(curl -sS -o "$tmp" -w "%{http_code}" \
            -X "$method" "$url" \
            -H "Authorization: Bearer $PAT" \
            -H "Content-Type: application/json" \
            -d "$body" 2>/dev/null || echo "000")
    else
        http_code=$(curl -sS -o "$tmp" -w "%{http_code}" \
            -X "$method" "$url" \
            -H "Authorization: Bearer $PAT" 2>/dev/null || echo "000")
    fi

    end_ts=$(date +%s%N)
    elapsed=$(( (end_ts - start_ts) / 1000000 ))

    local response_body; response_body=$(cat "$tmp")
    echo -e "${BLUE}← HTTP $http_code${NC} ${DIM}(${elapsed}ms)${NC}"
    echo "$(format_body "$response_body")"
    interpret "$http_code" "$response_body" "$name"

    # If success and response includes an id of a created resource, track it for cleanup
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && [[ "$name" == *"Create"* ]]; then
        if [[ $HAS_JQ -eq 1 ]]; then
            local id; id=$(echo "$response_body" | jq -r '.data.id // empty' 2>/dev/null)
            [[ -n "$id" ]] && CREATED_IDS+=("$id")
        fi
    fi

    rm -f "$tmp"
}

# Upload test with application/octet-stream + query params (per spec).
upload_octet() {
    local name="$1" parent_id="$2"
    local file; file=$(mktemp /tmp/kphotos_upload_test.XXXX.txt)
    echo "kPhotos test $(date) — random=$RANDOM" > "$file"
    local size; size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")
    local fname="kphotos_test_$(date +%s)_$RANDOM.txt"
    local now; now=$(date +%s)
    local url="$HOST_KDRIVE/3/drive/$DRIVE_ID/upload?directory_id=$parent_id&file_name=$fname&total_size=$size&created_at=$now&conflict=version"

    echo
    echo -e "${BOLD}─── $name ───${NC}"
    echo -e "${BLUE}→ POST${NC} $url"
    echo -e "${DIM}  body: [binary $size bytes] Content-Type: application/octet-stream${NC}"

    local tmp; tmp=$(mktemp)
    local http_code
    http_code=$(curl -sS -o "$tmp" -w "%{http_code}" \
        -X POST "$url" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$file" 2>/dev/null || echo "000")

    local response_body; response_body=$(cat "$tmp")
    echo -e "${BLUE}← HTTP $http_code${NC}"
    echo "$(format_body "$response_body")"
    if interpret "$http_code" "$response_body" "$name"; then
        if [[ $HAS_JQ -eq 1 ]]; then
            local id; id=$(echo "$response_body" | jq -r '.data.id // empty' 2>/dev/null)
            [[ -n "$id" ]] && CREATED_IDS+=("$id")
        fi
    fi
    rm -f "$tmp" "$file"
}

# Upload test with multipart/form-data (the way our current Swift code does it).
upload_multipart() {
    local name="$1" parent_id="$2"
    local file; file=$(mktemp /tmp/kphotos_upload_mp.XXXX.txt)
    echo "kPhotos multipart $(date) — random=$RANDOM" > "$file"
    local now; now=$(date +%s)

    echo
    echo -e "${BOLD}─── $name ───${NC}"
    echo -e "${BLUE}→ POST${NC} $HOST_KDRIVE/3/drive/$DRIVE_ID/upload"
    echo -e "${DIM}  body: multipart file=, directory_id=$parent_id, created_at=$now, conflict=version${NC}"

    local tmp; tmp=$(mktemp)
    local http_code
    http_code=$(curl -sS -o "$tmp" -w "%{http_code}" \
        -X POST "$HOST_KDRIVE/3/drive/$DRIVE_ID/upload" \
        -H "Authorization: Bearer $PAT" \
        -F "file=@$file" \
        -F "directory_id=$parent_id" \
        -F "created_at=$now" \
        -F "conflict=version" 2>/dev/null || echo "000")

    local response_body; response_body=$(cat "$tmp")
    echo -e "${BLUE}← HTTP $http_code${NC}"
    echo "$(format_body "$response_body")"
    if interpret "$http_code" "$response_body" "$name"; then
        if [[ $HAS_JQ -eq 1 ]]; then
            local id; id=$(echo "$response_body" | jq -r '.data.id // empty' 2>/dev/null)
            [[ -n "$id" ]] && CREATED_IDS+=("$id")
        fi
    fi
    rm -f "$tmp" "$file"
}

# ═══════════════════════════════════════════════════════════
#                       TESTS
# ═══════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════"
echo "  kPhotos / Infomaniak API empirical test"
echo "═══════════════════════════════════════════════════════"
echo "  PAT:        [redacted, length=${#PAT}]"
echo "  Drive ID:   $DRIVE_ID"
echo "  Test dir:   $TEST_FOLDER_ID"
echo "  Root dir:   $ROOT_FOLDER_ID"
echo "  jq:         $( [[ $HAS_JQ -eq 1 ]] && echo "installed (pretty output)" || echo "missing (raw output)")"
echo "═══════════════════════════════════════════════════════"

# ─── Group 1: Auth & discovery ────────────────────────────
echo
echo -e "${BOLD}▶ Group 1 — Auth & discovery${NC}"

run_test "1.1 Auth / list drives (kDrive host)" \
    "GET" "$HOST_KDRIVE/2/drive"

run_test "1.2 Auth / list drives (generic host)" \
    "GET" "$HOST_GENERIC/2/drive"

# ─── Group 2: Read operations ─────────────────────────────
echo
echo -e "${BOLD}▶ Group 2 — Read operations${NC}"

run_test "2.1 List ROOT folder (id=$ROOT_FOLDER_ID)" \
    "GET" "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$ROOT_FOLDER_ID/files?limit=5"

run_test "2.2 List TEST folder (id=$TEST_FOLDER_ID)" \
    "GET" "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$TEST_FOLDER_ID/files?limit=5"

run_test "2.3 TEST folder metadata" \
    "GET" "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$TEST_FOLDER_ID"

run_test "2.4 Search files (type=image)" \
    "GET" "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/search?type=image&limit=5"

# ─── Group 3: Write operations — directory creation ───────
echo
echo -e "${BOLD}▶ Group 3 — Write operations (directory creation)${NC}"

run_test "3.1 Create directory at ROOT (expected FAIL)" \
    "POST" "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$ROOT_FOLDER_ID/directory" \
    "{\"name\":\"kphotos_at_root_$(date +%s)_$RANDOM\",\"only_for_me\":true}"

run_test "3.2 Create directory INSIDE $TEST_FOLDER_ID" \
    "POST" "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$TEST_FOLDER_ID/directory" \
    "{\"name\":\"kphotos_subdir_$(date +%s)_$RANDOM\",\"only_for_me\":true}"

# ─── Group 4: Write operations — file upload ──────────────
echo
echo -e "${BOLD}▶ Group 4 — Write operations (file upload)${NC}"

upload_octet "4.1 Upload (octet-stream) into TEST folder $TEST_FOLDER_ID" "$TEST_FOLDER_ID"
upload_multipart "4.2 Upload (multipart, app-style) into TEST folder $TEST_FOLDER_ID" "$TEST_FOLDER_ID"
upload_octet "4.3 Upload (octet-stream) at ROOT (probe)" "$ROOT_FOLDER_ID"

# ─── Group 5: Move / Copy / Delete ────────────────────────
echo
echo -e "${BOLD}▶ Group 5 — Move / Copy / Delete${NC}"

# Only attempt move/copy if we created something
if [[ ${#CREATED_IDS[@]} -gt 0 ]]; then
    SOURCE_ID="${CREATED_IDS[0]}"
    run_test "5.1 Move created file ($SOURCE_ID) → root" \
        "POST" "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$SOURCE_ID/move/$ROOT_FOLDER_ID"

    run_test "5.2 Copy created file → $TEST_FOLDER_ID" \
        "POST" "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$SOURCE_ID/copy/$TEST_FOLDER_ID"
else
    echo "  (skipped — no created artifact to move/copy)"
fi

# ─── Group 6: Chunked upload (large files) ────────────────
echo
echo -e "${BOLD}▶ Group 6 — Chunked upload (for files > 50 MB)${NC}"

run_test "6.1 Start upload session (chunked)" \
    "POST" "$HOST_KDRIVE/3/drive/$DRIVE_ID/upload/session/start" \
    "{\"file_name\":\"chunk_probe_$(date +%s).bin\",\"directory_id\":$TEST_FOLDER_ID,\"total_chunks\":1,\"total_size\":100,\"created_at\":$(date +%s),\"conflict\":\"version\"}"

# ─── Cleanup ──────────────────────────────────────────────
echo
echo -e "${BOLD}▶ Cleanup — trashing artifacts created by this run${NC}"

if [[ ${#CREATED_IDS[@]} -eq 0 ]]; then
    echo "  (nothing to clean up)"
else
    for id in "${CREATED_IDS[@]}"; do
        echo "  Trashing file id=$id ..."
        # DELETE /2/drive/{drive_id}/files/{file_id} = move to trash
        code=$(curl -sS -o /dev/null -w "%{http_code}" \
            -X DELETE "$HOST_KDRIVE/2/drive/$DRIVE_ID/files/$id" \
            -H "Authorization: Bearer $PAT" 2>/dev/null || echo "000")
        echo "    → HTTP $code"
    done
fi

# ─── Summary ──────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "                       SUMMARY"
echo "═══════════════════════════════════════════════════════"
for r in "${RESULTS[@]}"; do
    status="${r%%|*}"; name="${r#*|}"
    case "$status" in
        OK*)        echo -e "  ${GREEN}✅ $r${NC}" ;;
        AUTH*|FORBID*|PERM*|404*|NET*) echo -e "  ${RED}❌ $r${NC}" ;;
        BAD*|400*|RATE*) echo -e "  ${YELLOW}⚠️  $r${NC}" ;;
        *)          echo -e "     $r" ;;
    esac
done
echo "═══════════════════════════════════════════════════════"

# Tally
pass=0; fail=0; warn=0
for r in "${RESULTS[@]}"; do
    case "${r%%|*}" in
        OK*) pass=$((pass+1)) ;;
        AUTH*|FORBID*|PERM*|404*|NET*) fail=$((fail+1)) ;;
        *) warn=$((warn+1)) ;;
    esac
done
echo "  $pass passed, $fail failed, $warn warnings"
echo
echo "  Interpretation guide:"
echo "    PERM      = the operation is forbidden for your PAT — REST writes are blocked"
echo "    AUTH      = token rejected; PAT is invalid / expired / wrong host"
echo "    FORBID    = HTTP 403; scope or kDrive role is insufficient"
echo "    BAD       = HTTP 400 with validation error; request shape is wrong (fixable)"
echo "    OK on 2.x = read works"
echo "    OK on 3.x = directory CREATE works"
echo "    OK on 4.x = upload works"
echo "    OK on 5.x = move/copy works"
echo
