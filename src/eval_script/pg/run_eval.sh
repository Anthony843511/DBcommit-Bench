#!/bin/bash
set -e
export LC_ALL=C
export LANG=C
set -x

# ================= Configuration =================
PG_SOURCE_DIR=""  # PostgreSQL source dir
PG_INSTALL_DIR="${PG_SOURCE_DIR}/install_coverage/"
WORKSPACE_DIR=""  # Workspace dir
REPORT_DIR="${WORKSPACE_DIR}/report"
#CUSTOM_SQL_FILE=""  # Custom SQL file
CUSTOM_SQL_FILE=""  # Custom SQL file
# ---- Persistent log save ----
LOG_SAVE_DIR=""  # Log save dir
SOCKET_DIR="$WORKSPACE_DIR"
PORT=55432
# ---- Recall evaluation config ----
JSON_DATASET_FILE=""  # Dataset JSON file
EVAL_RESULT_PATH=""  # Evaluation result path
EVAL_SCRIPT=""  # Evaluation script path
# branch Coverage ----
ENABLE_BRANCH_COVERAGE=1




save_log() {
    mkdir -p "$LOG_SAVE_DIR"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    cp "$LOG_FILE" "${LOG_SAVE_DIR}/run_${TIMESTAMP}.log"
    echo "[INFO] Log saved: ${LOG_SAVE_DIR}/run_${TIMESTAMP}.log"
}
trap save_log EXIT


# ================= Argument parsing =================
SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
    esac
done

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
err()  { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

# ================= Step 0: Cleanup =================
log "=== Step 0: Clean environment ==="

pkill -9 postgres 2>/dev/null || true
sleep 5

log "Remove old gcda (keep gcno!)"
find "$PG_SOURCE_DIR" -name "*.gcda" -delete

rm -rf "$WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR" "$REPORT_DIR"

LOG_FILE="${WORKSPACE_DIR}/run.log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [ "$SKIP_BUILD" = false ]; then
    find "$PG_SOURCE_DIR" -name "*.gcno" -delete
    rm -rf "$PG_INSTALL_DIR"
fi

# ================= Step 1: Build =================
log "=== Step 1: Full PostgreSQL build (coverage) ==="

cd "$PG_SOURCE_DIR"

if [ "$SKIP_BUILD" = false ]; then
    find "$PG_SOURCE_DIR" -name "*.gcno" -delete
    make clean || true

    ./configure --enable-coverage --without-readline --without-icu --prefix="$PG_INSTALL_DIR"
    if ! make -j4; then
        err "Build failed, exiting"
        exit 1
    fi
    if ! make install; then
        err "make install failed, exiting"
        exit 1
    fi
    log "Build complete"
else
    log "Skipping build (--skip-build)"
fi

# ================= Step 2: Environment =================
log "=== Step 2: Set environment variables ==="

export PATH="$PG_INSTALL_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$PG_INSTALL_DIR/lib:$LD_LIBRARY_PATH"

echo "postgres path: $(which postgres)"
echo "psql path: $(which psql)"

# ================= Step 3: Initialize database =================
log "=== Step 3: Initialize database ==="

MY_TEST_DATA="${WORKSPACE_DIR}/data"
initdb --locale=C -D "$MY_TEST_DATA"

# ================= Step 4: Start postgres =================
log "=== Step 4: Start PostgreSQL ==="

mkdir -p "$SOCKET_DIR"
chmod 700 "$SOCKET_DIR"

"$PG_INSTALL_DIR/bin/pg_ctl" \
    -D "$MY_TEST_DATA" \
    -l "$WORKSPACE_DIR/server.log" \
    -o "-k $SOCKET_DIR -p $PORT" \
    start

sleep 3

log "Check postgres process"
ps aux | grep postgres | grep -v grep

log "Verify PostgreSQL instance version"
psql -h "$SOCKET_DIR" -p $PORT -d postgres -c "SELECT version();"

# ================= Step 5: Create database =================
log "=== Step 5: Create database ==="

createdb -h "$SOCKET_DIR" -p $PORT regression

# ================= Step 6: Execute SQL =================
log "=== Step 6: Execute SQL workload ==="

TOTAL_CASES_EST=$(grep -cE "^-- (===== Test Case|Source: debug_task_|Test [0-9]+|Test [Cc]ase [0-9]+)" "$CUSTOM_SQL_FILE" || true)
log "Estimated test cases: $TOTAL_CASES_EST"

set +e
psql -h "$SOCKET_DIR" -p $PORT -d regression -f "$CUSTOM_SQL_FILE" -a > "$WORKSPACE_DIR/psql_output.log" 2>&1
PSQL_EXIT=$?
set -e

read AWK_OUT <<< $(awk '
BEGIN { t=0; h=0; f=0; a=0 }
/^-- (===== Test Case|Source: debug_task_|Test [0-9]+|Test [Cc]ase [0-9]+)/ {
    if (a && h) { t++; fl[t]=f }
    h=0; f=0; a=1
    next
}
/ERROR:/ { if (a) f=1 }
{ if (a && !/^[[:space:]]*(--|$)/) h=1 }
END {
    if (a && h) { t++; fl[t]=f }
    s=0; for(i=1;i<=t;i++) if(!fl[i]) s++
    printf "%d %d %d\n", t, s, t-s
}
' "$WORKSPACE_DIR/psql_output.log")

if [ -z "$AWK_OUT" ]; then
    TOTAL_CASES=0
    SUCCESS_CASES=0
    FAILED_CASES=0
else
    TOTAL_CASES=$(echo "$AWK_OUT" | awk '{print $1}')
    SUCCESS_CASES=$(echo "$AWK_OUT" | awk '{print $2}')
    FAILED_CASES=$(echo "$AWK_OUT" | awk '{print $3}')
fi
if [ "$TOTAL_CASES" -gt 0 ]; then
    CASE_SUCCESS_RATE=$(echo "scale=4; $SUCCESS_CASES / $TOTAL_CASES * 100" | bc)
else
    CASE_SUCCESS_RATE=0
fi

TOTAL_STMTS=$(grep -o ";" "$CUSTOM_SQL_FILE" | wc -l)
ERROR_STMTS=$(grep -c "ERROR:" "$WORKSPACE_DIR/psql_output.log" 2>/dev/null || echo 0)
STMT_SUCCESS_RATE=$(echo "scale=4; ($TOTAL_STMTS - $ERROR_STMTS) / $TOTAL_STMTS * 100" | bc)

log "========== SQL Execution Stats =========="
log "[Case] Total: $TOTAL_CASES case, Success: $SUCCESS_CASES, Failed: $FAILED_CASES, Rate: ${CASE_SUCCESS_RATE}%"
log "[SQL]  Total: $TOTAL_STMTS stmts, Success: $((TOTAL_STMTS - ERROR_STMTS)), Failed: $ERROR_STMTS, Rate: ${STMT_SUCCESS_RATE}%"

# ================= Step 7: Stop database =================
log "=== Step 7: Stop PostgreSQL (flush gcda) ==="

"$PG_INSTALL_DIR/bin/pg_ctl" \
    -D "$MY_TEST_DATA" \
    stop -m fast

sleep 6

# ================= Step 8: Check gcda =================
log "=== Step 8: Check coverage data ==="

TOTAL_GCDA=$(find "$PG_SOURCE_DIR" -name "*.gcda" | wc -l)
BACKEND_GCDA=$(find "$PG_SOURCE_DIR/src/backend" -name "*.gcda" | wc -l)
GCNO_COUNT=$(find "$PG_SOURCE_DIR/src/backend" -name "*.gcno" | wc -l)

echo "Total gcda files: $TOTAL_GCDA"
echo "backend gcda files: $BACKEND_GCDA"
echo "backend gcno files: $GCNO_COUNT"

if [ "$BACKEND_GCDA" -lt 100 ]; then
    err "backend coverage is near zero, SQL did not reach the kernel!"
    exit 1
fi

# ================= Step 9: Coverage report (v5: with branch coverage) =================
log "=== Step 9: Generate coverage report (with branch coverage) ==="

cd "$PG_SOURCE_DIR"

LCOV_OPTS=""
GENHTML_OPTS=""
if [ "$ENABLE_BRANCH_COVERAGE" = "1" ]; then
    LCOV_OPTS="--rc lcov_branch_coverage=1 --gcov-tool /opt/rh/devtoolset-11/root/usr/bin/gcov"
    GENHTML_OPTS="--branch-coverage"
    log "Branch coverage enabled"
fi

lcov --capture $LCOV_OPTS \
    --directory "$PG_SOURCE_DIR" \
    --output-file "$WORKSPACE_DIR/coverage.info"

lcov $LCOV_OPTS \
    --remove "$WORKSPACE_DIR/coverage.info" '/usr/*' \
    --output-file "$WORKSPACE_DIR/coverage_filtered.info"

genhtml $GENHTML_OPTS \
    "$WORKSPACE_DIR/coverage_filtered.info" \
    --output-directory "$REPORT_DIR"

# ================= Coverage Summary =================
log "=== Coverage Summary ==="

LINE_COVERAGE=$(lcov --summary "$WORKSPACE_DIR/coverage_filtered.info" 2>&1 | grep "lines......" | awk '{print $2}' | tr -d '%')
FUNC_COVERAGE=$(lcov --summary "$WORKSPACE_DIR/coverage_filtered.info" 2>&1 | grep "functions." | awk '{print $2}' | tr -d '%')

if [ "$ENABLE_BRANCH_COVERAGE" = "1" ]; then
    BRANCH_COVERAGE=$(lcov --summary "$WORKSPACE_DIR/coverage_filtered.info" 2>&1 | grep "branches." | awk '{print $2}' | tr -d '%')
    log "Line coverage: ${LINE_COVERAGE}%"
    log "Function coverage: ${FUNC_COVERAGE}%"
    log "Branch coverage: ${BRANCH_COVERAGE}%"
else
    log "Line coverage: ${LINE_COVERAGE}%"
    log "Function coverage: ${FUNC_COVERAGE}%"
    log "Branch coverage: not enabled"
fi

# ================= Step 10: Recall evaluation =================
log "=== Step 10: Recall/Precision evaluation ==="

if [ -f "$JSON_DATASET_FILE" ]; then
    log "Running recall evaluation: JSON=$JSON_DATASET_FILE, COVERAGE=$WORKSPACE_DIR, OUTPUT=$EVAL_RESULT_PATH"
    python3 "$EVAL_SCRIPT" "$JSON_DATASET_FILE" "$WORKSPACE_DIR" "$EVAL_RESULT_PATH"
    log "Recall evaluation complete, results saved to: $EVAL_RESULT_PATH"
else
    err "JSON dataset file not found: $JSON_DATASET_FILE, skipping recall evaluation"
fi

# ================= Done =================
log "=== Done ==="
log "Report path: file://$REPORT_DIR/index.html"
log "Case-level SQL execution rate: ${CASE_SUCCESS_RATE}%  ($SUCCESS_CASES/$TOTAL_CASES)"
if [ "$ENABLE_BRANCH_COVERAGE" = "1" ]; then
    log "Branch coverage: ${BRANCH_COVERAGE}%"
fi

# Clean gcda/gcno
find "$PG_SOURCE_DIR" -name "*.gcda" -delete
find "$PG_SOURCE_DIR" -name "*.gcno" -delete
log "gcda/gcno cleaned"
