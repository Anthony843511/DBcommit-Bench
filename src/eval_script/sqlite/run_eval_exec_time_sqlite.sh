#!/bin/bash

set -euo pipefail
export LC_ALL=C LANG=C

# ================= Configuration =================
CUSTOM_SQL_FILE="${1:-}"
SQLITE3_BIN="${SQLITE3_BIN:-sqlite3}"
DB=":memory:"
OUT=""
TIME_BIN="${TIME_BIN:-}"

# ================= Argument parsing =================
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --sqlite3)   SQLITE3_BIN="$2"; shift 2 ;;
        --db)        DB="$2"; shift 2 ;;
        --out)       OUT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$CUSTOM_SQL_FILE" ] || [ ! -f "$CUSTOM_SQL_FILE" ]; then
    echo "ERROR: SQL file required and must exist: $CUSTOM_SQL_FILE"
    exit 1
fi
if ! command -v "$SQLITE3_BIN" >/dev/null 2>&1; then
    echo "ERROR: sqlite3 binary not found: $SQLITE3_BIN"
    exit 1
fi
if [ -z "$OUT" ]; then
    OUT="${CUSTOM_SQL_FILE}.exec_time.txt"
fi
if [ -z "$TIME_BIN" ]; then
    echo "ERROR: TIME_BIN is empty (set TIME_BIN, e.g. GNU time path)"
    exit 1
fi
if [ ! -x "$TIME_BIN" ]; then
    echo "ERROR: $TIME_BIN not found (GNU time required)"
    exit 1
fi

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

# ================= Execute SQL and time it =================
log "Executing SQL workload: $CUSTOM_SQL_FILE"
log "Target: $SQLITE3_BIN $DB < $CUSTOM_SQL_FILE"

TIME_LOG="${OUT}.time"
START=$(date +%s.%N)
set +e
"$TIME_BIN" -v -o "$TIME_LOG" \
    "$SQLITE3_BIN" "$DB" < "$CUSTOM_SQL_FILE" \
    > "${OUT}.sqlite.log" 2>&1
RC=$?
END=$(date +%s.%N)
set -e
WALL=$(echo "$END $START" | awk '{printf "%.4f", $1-$2}')

ERRORS=$(grep -c -iE "error( near line)?(:|\.)|Parse error|Error near" "${OUT}.sqlite.log" || true)
STMTS=$(grep -o ";" "$CUSTOM_SQL_FILE" | wc -l)

# Extract GNU time fields
ELAPSED_TIME=$(grep -E "Elapsed \(wall clock\)" "$TIME_LOG" | sed -E 's/.*:\s*//' || true)
USER_TIME=$(grep -E "User time" "$TIME_LOG" | sed -E 's/.*:\s*//' || true)
SYS_TIME=$(grep -E "System time" "$TIME_LOG" | sed -E 's/.*:\s*//' || true)
MAXRSS=$(grep -E "Maximum resident set size" "$TIME_LOG" | sed -E 's/.*:\s*//' || true)

echo "=============================="
echo "Execution-time report"
echo "  SQL file:          $CUSTOM_SQL_FILE"
echo "  sqlite3 exit code: $RC"
echo "  statements:        $STMTS"
echo "  errors:            $ERRORS"
echo "  wall clock (s):    $WALL   (GNU time: ${ELAPSED_TIME:-n/a})"
echo "  user / sys time:   ${USER_TIME:-n/a} / ${SYS_TIME:-n/a}"
echo "  max RSS:           ${MAXRSS:-n/a} KB"
echo "=============================="

# ================= Save =================
{
    echo "mode=whole-file"
    echo "sql_file=$CUSTOM_SQL_FILE"
    echo "sqlite3_bin=$SQLITE3_BIN db=$DB"
    echo "sqlite3_exit=$RC"
    echo "statements=$STMTS"
    echo "errors=$ERRORS"
    echo "wall_clock_sec=$WALL"
    echo "gnu_time_elapsed=${ELAPSED_TIME:-}"
    echo "user_time=${USER_TIME:-}"
    echo "sys_time=${SYS_TIME:-}"
    echo "max_rss_kb=${MAXRSS:-}"
} > "$OUT"
log "Results saved to: $OUT"
log "sqlite3 output saved to: ${OUT}.sqlite.log"
log "GNU time output saved to: $TIME_LOG"
