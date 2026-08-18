#!/bin/bash

set -euo pipefail
export LC_ALL=C LANG=C

# ================= Configuration =================
CUSTOM_SQL_FILE="${1:-}"
SOCKET_DIR="${PG_SOCKET_DIR:-}"
PORT="${PG_PORT:-55432}"
DB="${PG_DB:-regression}"
OUT=""
TIME_BIN="${TIME_BIN:-}"

# ================= Argument parsing =================
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --socket-dir) SOCKET_DIR="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --db)         DB="$2"; shift 2 ;;
        --out)        OUT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$CUSTOM_SQL_FILE" ] || [ ! -f "$CUSTOM_SQL_FILE" ]; then
    echo "ERROR: SQL file required and must exist: $CUSTOM_SQL_FILE"
    exit 1
fi
if ! command -v psql >/dev/null 2>&1; then
    echo "ERROR: psql not found in PATH (export PATH=\"\$PG_INSTALL_DIR/bin:\$PATH\")"
    exit 1
fi
if [ -z "$OUT" ]; then
    OUT="${CUSTOM_SQL_FILE}.exec_time.txt"
fi
if [ -z "$SOCKET_DIR" ]; then
    echo "ERROR: socket dir is empty (set PG_SOCKET_DIR or pass --socket-dir)"
    exit 1
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
log "Target: psql -h $SOCKET_DIR -p $PORT -d $DB -f $CUSTOM_SQL_FILE"

TIME_LOG="${OUT}.time"
START=$(date +%s.%N)
set +e
"$TIME_BIN" -v -o "$TIME_LOG" \
    psql -X -h "$SOCKET_DIR" -p "$PORT" -d "$DB" -f "$CUSTOM_SQL_FILE" \
    > "${OUT}.psql.log" 2>&1
RC=$?
END=$(date +%s.%N)
set -e
WALL=$(echo "$END $START" | awk '{printf "%.4f", $1-$2}')

ERRORS=$(grep -c -iE "(^| )error(:|\.)" "${OUT}.psql.log" || true)
STMTS=$(grep -o ";" "$CUSTOM_SQL_FILE" | wc -l)

# Extract GNU time fields
ELAPSED_TIME=$(grep -E "Elapsed \(wall clock\)" "$TIME_LOG" | sed -E 's/.*:\s*//' || true)
USER_TIME=$(grep -E "User time" "$TIME_LOG" | sed -E 's/.*:\s*//' || true)
SYS_TIME=$(grep -E "System time" "$TIME_LOG" | sed -E 's/.*:\s*//' || true)
MAXRSS=$(grep -E "Maximum resident set size" "$TIME_LOG" | sed -E 's/.*:\s*//' || true)

echo "=============================="
echo "Execution-time report"
echo "  SQL file:        $CUSTOM_SQL_FILE"
echo "  psql exit code:  $RC"
echo "  statements:      $STMTS"
echo "  errors:          $ERRORS"
echo "  wall clock (s):  $WALL   (GNU time: ${ELAPSED_TIME:-n/a})"
echo "  user / sys time: ${USER_TIME:-n/a} / ${SYS_TIME:-n/a}"
echo "  max RSS:         ${MAXRSS:-n/a} KB"
echo "=============================="

# ================= Save =================
{
    echo "mode=whole-file"
    echo "sql_file=$CUSTOM_SQL_FILE"
    echo "socket_dir=$SOCKET_DIR port=$PORT db=$DB"
    echo "psql_exit=$RC"
    echo "statements=$STMTS"
    echo "errors=$ERRORS"
    echo "wall_clock_sec=$WALL"
    echo "gnu_time_elapsed=${ELAPSED_TIME:-}"
    echo "user_time=${USER_TIME:-}"
    echo "sys_time=${SYS_TIME:-}"
    echo "max_rss_kb=${MAXRSS:-}"
} > "$OUT"
log "Results saved to: $OUT"
log "psql output saved to: ${OUT}.psql.log"
log "GNU time output saved to: $TIME_LOG"
