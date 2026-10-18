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

# kPhotos / Infomaniak — Advanced viability tests.
# Verifies CRITICAL operations for a full Photos app:
#   - Real image upload (JPEG)
#   - Date preservation (AGENTS.md §6 — the "kDrive date bug" reason kPhotos exists)
#   - Thumbnail / preview generation
#   - Download round-trip (byte-perfect integrity)
#   - Chunked upload — full sequence (start → chunk × N → finish) for videos > 50 MB
#   - Rename, trash
#
# Usage:
#   export PAT='your_token'
#   ./scripts/api_test_advanced.sh

set -uo pipefail

: "${PAT:?ERROR: set PAT environment variable (your kDrive Personal Access Token)}"
: "${DRIVE_ID:?ERROR: set DRIVE_ID environment variable (your numeric kDrive id)}"
: "${TEST_FOLDER_ID:?ERROR: set TEST_FOLDER_ID environment variable (a folder you already own)}"

HOST_KDRIVE="https://api.kdrive.infomaniak.com"

# 2020-06-15 12:00:00 UTC — a fixed past date, easy to recognize.
TEST_DATE=1592223200

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

command -v jq >/dev/null 2>&1 || { echo -e "${RED}ERROR${NC}: jq required. brew install jq"; exit 1; }

declare -a CREATED_IDS=()
declare -a RESULTS=()

# Minimal valid JPEG — 1x1 white pixel, ~125 bytes. Real header so thumbnail server can read it.
TINY_JPEG_B64='/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AKp//9k='

mark() {
    local status="$1"; local name="$2"
    RESULTS+=("$status|$name")
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}✓${NC} $label: $actual"
        return 0
    else
        echo -e "  ${RED}✗${NC} $label: expected=$expected, got=$actual"
        return 1
    fi
}

# ════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════"
echo "  kPhotos Advanced viability test"
echo "═══════════════════════════════════════════════════════"
echo "  Test date: $TEST_DATE = $(date -r $TEST_DATE 2>/dev/null || echo '2020-06-15 UTC')"
echo "  Drive:     $DRIVE_ID, parent folder: $TEST_FOLDER_ID"
echo "═══════════════════════════════════════════════════════"

# ─── Prepare test artifacts ────────────────────────────────
echo
echo -e "${BOLD}▶ Preparing test files${NC}"

JPEG_FILE=$(mktemp /tmp/kphotos_test.XXXXXX.jpg)
echo "$TINY_JPEG_B64" | base64 -d > "$JPEG_FILE"
JPEG_SIZE=$(stat -f%z "$JPEG_FILE" 2>/dev/null || stat -c%s "$JPEG_FILE")
echo "  Tiny JPEG: $JPEG_FILE ($JPEG_SIZE bytes, valid 1x1)"

BIN_FILE=$(mktemp /tmp/kphotos_test.XXXXXX.bin)
dd if=/dev/urandom of="$BIN_FILE" bs=1024 count=200 >/dev/null 2>&1
BIN_SIZE=$(stat -f%z "$BIN_FILE" 2>/dev/null || stat -c%s "$BIN_FILE")
echo "  200KB random: $BIN_FILE ($BIN_SIZE bytes)"

BIG_FILE=$(mktemp /tmp/kphotos_big.XXXXXX.bin)
dd if=/dev/urandom of="$BIG_FILE" bs=1024 count=2500 >/dev/null 2>&1
BIG_SIZE=$(stat -f%z "$BIG_FILE" 2>/dev/null || stat -c%s "$BIG_FILE")
echo "  2.5MB random: $BIG_FILE ($BIG_SIZE bytes) — for chunked upload"

# ─── Test 1 — Upload real JPEG ─────────────────────────────
echo
echo -e "${BOLD}─── T1 — Upload real JPEG (octet-stream) with past created_at ───${NC}"

FNAME="kphotos_real_jpeg_$(date +%s)_$RANDOM.jpg"
URL="$HOST_KDRIVE/3/drive/$DRIVE_ID/upload?directory_id=$TEST_FOLDER_ID&file_name=$FNAME&total_size=$JPEG_SIZE&created_at=$TEST_DATE&conflict=version"
echo -e "${BLUE}→ POST${NC} $URL"

UPLOAD_RES=$(mktemp)
HTTP=$(curl -sS -o "$UPLOAD_RES" -w "%{http_code}" \
    -X POST "$URL" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: image/jpeg" \
    --data-binary "@$JPEG_FILE")
echo -e "${BLUE}← HTTP $HTTP${NC}"
jq -C '{result: .result, error_code: .error.code}' < "$UPLOAD_RES" 2>/dev/null || true
JPEG_ID=$(jq -r '.data.id // empty' < "$UPLOAD_RES")
if [[ -n "$JPEG_ID" ]]; then
    CREATED_IDS+=("$JPEG_ID")
    echo -e "  ${GREEN}✓${NC} Upload OK, file id=$JPEG_ID"
    mark OK "T1 Upload JPEG"
else
    echo -e "  ${RED}✗${NC} Upload failed"
    mark FAIL "T1 Upload JPEG"
fi
rm -f "$UPLOAD_RES"

# ─── Test 2 — CRITICAL: Verify created_at preservation ─────
if [[ -n "${JPEG_ID:-}" ]]; then
    echo
    echo -e "${BOLD}─── T2 — CRITICAL: Verify created_at preserved (AGENTS.md §6) ───${NC}"
    echo -e "${CYAN}  This is THE bug that kPhotos exists to fix.${NC}"
    META_RES=$(mktemp)
    curl -sS -o "$META_RES" \
        -X GET "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$JPEG_ID" \
        -H "Authorization: Bearer $PAT"
    jq -C '{created_at: .data.created_at, added_at: .data.added_at, last_modified_at: .data.last_modified_at}' < "$META_RES"
    ACTUAL_CREATED=$(jq -r '.data.created_at // "null"' < "$META_RES")
    if assert_eq "created_at preservation" "$TEST_DATE" "$ACTUAL_CREATED"; then
        echo -e "  ${GREEN}${BOLD}🎉 DATE BUG FIXED${NC} — kDrive accepted and stored the past date"
        mark OK "T2 Date preservation"
    else
        echo -e "  ${RED}${BOLD}⚠️  DATE BUG STILL ACTIVE${NC} — kDrive ignored our created_at"
        mark FAIL "T2 Date preservation"
    fi
    rm -f "$META_RES"
fi

# ─── Test 3 — Thumbnail ───────────────────────────────────
if [[ -n "${JPEG_ID:-}" ]]; then
    echo
    echo -e "${BOLD}─── T3 — Thumbnail fetch ───${NC}"
    THUMB_RES=$(mktemp /tmp/kphotos_thumb.XXXX)
    HTTP=$(curl -sS -o "$THUMB_RES" -w "%{http_code}\n%{content_type}" \
        -X GET "$HOST_KDRIVE/2/drive/$DRIVE_ID/files/$JPEG_ID/thumbnail" \
        -H "Authorization: Bearer $PAT")
    HTTP_CODE=$(echo "$HTTP" | head -1)
    CT=$(echo "$HTTP" | tail -1)
    SIZE=$(stat -f%z "$THUMB_RES" 2>/dev/null || stat -c%s "$THUMB_RES")
    echo "  HTTP $HTTP_CODE, content-type: $CT, size: ${SIZE}B"
    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        echo -e "  ${GREEN}✓${NC} Thumbnail generated"
        mark OK "T3 Thumbnail"
    else
        echo "  (response body omitted)"
        mark FAIL "T3 Thumbnail"
    fi
    rm -f "$THUMB_RES"
fi

# ─── Test 4 — Preview ─────────────────────────────────────
if [[ -n "${JPEG_ID:-}" ]]; then
    echo
    echo -e "${BOLD}─── T4 — Preview fetch ───${NC}"
    PREV_RES=$(mktemp /tmp/kphotos_preview.XXXX)
    HTTP=$(curl -sS -o "$PREV_RES" -w "%{http_code}\n%{content_type}" \
        -X GET "$HOST_KDRIVE/2/drive/$DRIVE_ID/files/$JPEG_ID/preview" \
        -H "Authorization: Bearer $PAT")
    HTTP_CODE=$(echo "$HTTP" | head -1)
    CT=$(echo "$HTTP" | tail -1)
    SIZE=$(stat -f%z "$PREV_RES" 2>/dev/null || stat -c%s "$PREV_RES")
    echo "  HTTP $HTTP_CODE, content-type: $CT, size: ${SIZE}B"
    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        echo -e "  ${GREEN}✓${NC} Preview generated"
        mark OK "T4 Preview"
    else
        echo "  (response body omitted)"
        mark FAIL "T4 Preview"
    fi
    rm -f "$PREV_RES"
fi

# ─── Test 5 — Download round-trip integrity ───────────────
if [[ -n "${JPEG_ID:-}" ]]; then
    echo
    echo -e "${BOLD}─── T5 — Download round-trip (byte integrity) ───${NC}"
    DL_RES=$(mktemp /tmp/kphotos_download.XXXX.jpg)
    HTTP=$(curl -sS -o "$DL_RES" -w "%{http_code}" \
        -X GET "$HOST_KDRIVE/2/drive/$DRIVE_ID/files/$JPEG_ID/download" \
        -H "Authorization: Bearer $PAT")
    DL_SIZE=$(stat -f%z "$DL_RES" 2>/dev/null || stat -c%s "$DL_RES")
    echo "  HTTP $HTTP, size: ${DL_SIZE}B (uploaded: ${JPEG_SIZE}B)"
    if [[ "$HTTP" =~ ^2 ]]; then
        HASH_UP=$(shasum -a 256 "$JPEG_FILE" | awk '{print $1}')
        HASH_DL=$(shasum -a 256 "$DL_RES" | awk '{print $1}')
        if [[ "$HASH_UP" == "$HASH_DL" ]]; then
            echo -e "  ${GREEN}✓${NC} SHA-256 match — byte-perfect round-trip"
            mark OK "T5 Download integrity"
        else
            echo -e "  ${RED}✗${NC} Hash mismatch (up=$HASH_UP vs dl=$HASH_DL)"
            mark FAIL "T5 Download integrity"
        fi
    else
        echo "  (response body omitted)"
        mark FAIL "T5 Download"
    fi
    rm -f "$DL_RES"
fi

# ─── Test 6 — Rename ──────────────────────────────────────
if [[ -n "${JPEG_ID:-}" ]]; then
    echo
    echo -e "${BOLD}─── T6 — Rename file ───${NC}"
    NEW_NAME="kphotos_renamed_$(date +%s).jpg"
    RES=$(mktemp)
    HTTP=$(curl -sS -o "$RES" -w "%{http_code}" \
        -X POST "$HOST_KDRIVE/2/drive/$DRIVE_ID/files/$JPEG_ID/rename" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$NEW_NAME\"}")
    echo "  HTTP $HTTP"
    jq -C '{result: .result, name: .data.name}' < "$RES" 2>/dev/null
    if [[ "$HTTP" =~ ^2 ]]; then
        ACTUAL_NAME=$(jq -r '.data.name // empty' < "$RES")
        if [[ "$ACTUAL_NAME" == "$NEW_NAME" ]]; then
            echo -e "  ${GREEN}✓${NC} Renamed to $NEW_NAME"
            mark OK "T6 Rename"
        else
            mark FAIL "T6 Rename (name mismatch)"
        fi
    else
        mark FAIL "T6 Rename HTTP $HTTP"
    fi
    rm -f "$RES"
fi

# ─── Test 7 — Upload 200KB binary (simulates a real photo) ─
echo
echo -e "${BOLD}─── T7 — Upload 200KB binary with past date ───${NC}"
FNAME="kphotos_200k_$(date +%s)_$RANDOM.jpg"
URL="$HOST_KDRIVE/3/drive/$DRIVE_ID/upload?directory_id=$TEST_FOLDER_ID&file_name=$FNAME&total_size=$BIN_SIZE&created_at=$TEST_DATE&conflict=version"
RES=$(mktemp)
HTTP=$(curl -sS -o "$RES" -w "%{http_code}" \
    -X POST "$URL" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: image/jpeg" \
    --data-binary "@$BIN_FILE")
echo "  HTTP $HTTP"
BIN_ID=$(jq -r '.data.id // empty' < "$RES")
if [[ -n "$BIN_ID" ]]; then
    CREATED_IDS+=("$BIN_ID")
    echo -e "  ${GREEN}✓${NC} 200KB upload OK, id=$BIN_ID"
    mark OK "T7 Upload 200KB"
    # Verify date
    BIN_META=$(mktemp)
    curl -sS -o "$BIN_META" -X GET "$HOST_KDRIVE/3/drive/$DRIVE_ID/files/$BIN_ID" -H "Authorization: Bearer $PAT"
    BIN_CREATED=$(jq -r '.data.created_at // "null"' < "$BIN_META")
    assert_eq "200KB created_at" "$TEST_DATE" "$BIN_CREATED" && mark OK "T7b Date preserved (200KB)" || mark FAIL "T7b Date preserved (200KB)"
    rm -f "$BIN_META"
else
    jq -C '{result: .result, error_code: .error.code}' < "$RES"
    mark FAIL "T7 Upload 200KB"
fi
rm -f "$RES"

# ─── Test 8 — Full chunked upload (start → chunks → finish) ─
echo
echo -e "${BOLD}─── T8 — Full chunked upload sequence (2.5MB in 2 chunks) ───${NC}"

# Split big file into 2 chunks
CHUNK1=$(mktemp /tmp/kphotos_chunk1.XXXX)
CHUNK2=$(mktemp /tmp/kphotos_chunk2.XXXX)
dd if="$BIG_FILE" of="$CHUNK1" bs=1024 count=1500 >/dev/null 2>&1
dd if="$BIG_FILE" of="$CHUNK2" bs=1024 count=1000 skip=1500 >/dev/null 2>&1
CHUNK1_SIZE=$(stat -f%z "$CHUNK1" 2>/dev/null || stat -c%s "$CHUNK1")
CHUNK2_SIZE=$(stat -f%z "$CHUNK2" 2>/dev/null || stat -c%s "$CHUNK2")
echo "  Chunk 1: ${CHUNK1_SIZE}B, Chunk 2: ${CHUNK2_SIZE}B, Total: ${BIG_SIZE}B"

# Step 8.1 — start session
echo -e "${BLUE}  → POST /upload/session/start${NC}"
FNAME="kphotos_chunked_$(date +%s).bin"
START_RES=$(mktemp)
HTTP=$(curl -sS -o "$START_RES" -w "%{http_code}" \
    -X POST "$HOST_KDRIVE/3/drive/$DRIVE_ID/upload/session/start" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" \
    -d "{\"file_name\":\"$FNAME\",\"directory_id\":$TEST_FOLDER_ID,\"total_chunks\":2,\"total_size\":$BIG_SIZE,\"created_at\":$TEST_DATE,\"conflict\":\"version\"}")
echo "    HTTP $HTTP"
TOKEN=$(jq -r '.data.token // empty' < "$START_RES")
UPLOAD_HOST=$(jq -r '.data.upload_url // empty' < "$START_RES")
CHUNK_FILE_ID=$(jq -r '.data.file.id // empty' < "$START_RES")
echo "    session token received (redacted)"
echo "    upload host received (redacted)"
echo "    file_id=$CHUNK_FILE_ID"
rm -f "$START_RES"

if [[ -z "$TOKEN" ]]; then
    echo -e "  ${RED}✗${NC} Session start failed"
    mark FAIL "T8 Chunked start"
else
    mark OK "T8a Chunked start"
    CHUNK_HOST="${UPLOAD_HOST:-$HOST_KDRIVE}"

    # Step 8.2 — upload chunk 1
    echo -e "${BLUE}  → POST chunk 1${NC}"
    CHUNK1_RES=$(mktemp)
    HTTP=$(curl -sS -o "$CHUNK1_RES" -w "%{http_code}" \
        -X POST "$CHUNK_HOST/3/drive/$DRIVE_ID/upload/session/$TOKEN/chunk?chunk_number=1&chunk_size=$CHUNK1_SIZE" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$CHUNK1")
    echo "    HTTP $HTTP (response body omitted)"
    [[ "$HTTP" =~ ^2 ]] && mark OK "T8b Chunk 1 upload" || mark FAIL "T8b Chunk 1"
    rm -f "$CHUNK1_RES"

    # Step 8.3 — upload chunk 2
    echo -e "${BLUE}  → POST chunk 2${NC}"
    CHUNK2_RES=$(mktemp)
    HTTP=$(curl -sS -o "$CHUNK2_RES" -w "%{http_code}" \
        -X POST "$CHUNK_HOST/3/drive/$DRIVE_ID/upload/session/$TOKEN/chunk?chunk_number=2&chunk_size=$CHUNK2_SIZE" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$CHUNK2")
    echo "    HTTP $HTTP (response body omitted)"
    [[ "$HTTP" =~ ^2 ]] && mark OK "T8c Chunk 2 upload" || mark FAIL "T8c Chunk 2"
    rm -f "$CHUNK2_RES"

    # Step 8.4 — finish session (with past created_at)
    echo -e "${BLUE}  → POST finish${NC}"
    FINISH_RES=$(mktemp)
    HTTP=$(curl -sS -o "$FINISH_RES" -w "%{http_code}" \
        -X POST "$HOST_KDRIVE/3/drive/$DRIVE_ID/upload/session/$TOKEN/finish" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -d "{\"created_at\":$TEST_DATE,\"last_modified_at\":$TEST_DATE}")
    echo "    HTTP $HTTP"
    jq -C '{result: .result, file_id: .data.file.id, file_status: .data.file.status, created_at: .data.file.created_at}' < "$FINISH_RES" 2>/dev/null
    FINAL_ID=$(jq -r '.data.file.id // empty' < "$FINISH_RES")
    FINAL_CREATED=$(jq -r '.data.file.created_at // "null"' < "$FINISH_RES")
    if [[ -n "$FINAL_ID" ]]; then
        CREATED_IDS+=("$FINAL_ID")
        mark OK "T8d Chunked finish"
        assert_eq "Chunked file created_at" "$TEST_DATE" "$FINAL_CREATED" && mark OK "T8e Chunked date preserved" || mark FAIL "T8e Chunked date"
    else
        mark FAIL "T8d Chunked finish"
    fi
    rm -f "$FINISH_RES"
fi
rm -f "$CHUNK1" "$CHUNK2"

# ─── Cleanup ───────────────────────────────────────────────
echo
echo -e "${BOLD}▶ Cleanup — trashing created artifacts${NC}"
for id in "${CREATED_IDS[@]}"; do
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
        -X DELETE "$HOST_KDRIVE/2/drive/$DRIVE_ID/files/$id" \
        -H "Authorization: Bearer $PAT")
    echo "  trash id=$id → HTTP $code"
done

# Cleanup local files
rm -f "$JPEG_FILE" "$BIN_FILE" "$BIG_FILE"

# ─── Summary ───────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "                       SUMMARY"
echo "═══════════════════════════════════════════════════════"
pass=0; fail=0
for r in "${RESULTS[@]}"; do
    status="${r%%|*}"; name="${r#*|}"
    if [[ "$status" == "OK" ]]; then
        echo -e "  ${GREEN}✅ $name${NC}"
        pass=$((pass+1))
    else
        echo -e "  ${RED}❌ $name${NC}"
        fail=$((fail+1))
    fi
done
echo "═══════════════════════════════════════════════════════"
echo "  $pass passed, $fail failed"
echo

if [[ $fail -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}🎉 kPhotos is FULLY VIABLE with this PAT.${NC}"
    echo "  All critical operations work: upload, date preservation,"
    echo "  thumbnail, preview, download round-trip, rename,"
    echo "  full chunked upload sequence (for large videos)."
else
    echo -e "${YELLOW}⚠️  Some operations failed. Check details above.${NC}"
fi
