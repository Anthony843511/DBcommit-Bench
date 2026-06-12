#!/bin/bash
# ============================================================
# run_sqlite_coverage.sh (adapted for yike)
#
# Usage:
#   ./run_sqlite_coverage.sh \
#     --sql-file   /path/to/dataset.sql \
#     --json-file  /path/to/results.json \
#     --report-dir /path/to/report \
#     [--skip-build] [--skip-clean]
# ============================================================

set -euo pipefail

# ================= Configuration =================
SQLITE_SOURCE_DIR=""  # SQLite source dir
WORKSPACE_BASE=""  # Workspace base dir

# Defaults
CUSTOM_SQL_FILE=""
JSON_DATASET_FILE="${WORKSPACE_BASE}/data/recall_test_results.json"
REPORT_DIR=""
EVAL_RESULT_PATH=""
LOG_SAVE_DIR=""

# Scripts
CHECK_EXEC_SCRIPT=""  # Execution check script
EVAL_SCRIPT=""  # Evaluation script

# ================= Parameter parsing =================
SKIP_BUILD=false
SKIP_CLEAN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true; shift ;;
        --skip-clean) SKIP_CLEAN=true; shift ;;
        --sql-file) CUSTOM_SQL_FILE="$2"; shift 2 ;;
        --sql-file=*) CUSTOM_SQL_FILE="${1#*=}"; shift ;;
        --json-file) JSON_DATASET_FILE="$2"; shift 2 ;;
        --json-file=*) JSON_DATASET_FILE="${1#*=}"; shift ;;
        --report-dir) REPORT_DIR="$2"; shift 2 ;;
        --report-dir=*) REPORT_DIR="${1#*=}"; shift ;;
        --eval-result) EVAL_RESULT_PATH="$2"; shift 2 ;;
        --eval-result=*) EVAL_RESULT_PATH="${1#*=}"; shift ;;
        --log-save-dir) LOG_SAVE_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Validate required params
if [ -z "$CUSTOM_SQL_FILE" ]; then
    echo "ERROR: --sql-file is required"
    exit 1
fi
if [ ! -f "$CUSTOM_SQL_FILE" ]; then
    echo "ERROR: SQL file not found: $CUSTOM_SQL_FILE"
    exit 1
fi

# Derive names from SQL filename
SQL_BASENAME=$(basename "$CUSTOM_SQL_FILE" .sql)
if [ -z "$REPORT_DIR" ]; then
    REPORT_DIR="${WORKSPACE_BASE}/report/${SQL_BASENAME}"
fi
if [ -z "$EVAL_RESULT_PATH" ]; then
    EVAL_RESULT_PATH="${WORKSPACE_BASE}/data/git_${SQL_BASENAME}_result.json"
fi
if [ -z "$LOG_SAVE_DIR" ]; then
    LOG_SAVE_DIR="${WORKSPACE_BASE}/logs"
fi

# Logging
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${WORKSPACE_BASE}/workspace/${SQL_BASENAME}/run.log"
mkdir -p "$(dirname "$LOG_FILE")" "$REPORT_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
err()  { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

save_log() {
    mkdir -p "$LOG_SAVE_DIR"
    cp "$LOG_FILE" "${LOG_SAVE_DIR}/${SQL_BASENAME}_${TIMESTAMP}.log"
    log "Log saved: ${LOG_SAVE_DIR}/${SQL_BASENAME}_${TIMESTAMP}.log"
}
trap save_log EXIT

log "=== Starting eval for: $SQL_BASENAME ==="
log "SQL: $CUSTOM_SQL_FILE"
log "JSON: $JSON_DATASET_FILE"
log "Report: $REPORT_DIR"
log "Result: $EVAL_RESULT_PATH"

# ================= Step 0: Clean =================
log "=== Step 0: Clean ==="
if [ "$SKIP_CLEAN" = false ]; then
    log "Removing old .gcda..."
    find "$SQLITE_SOURCE_DIR" -name "*.gcda" -delete
    rm -rf "$REPORT_DIR"
fi
mkdir -p "$REPORT_DIR"

# ================= Step 1: Build =================
log "=== Step 1: Build SQLite with gcov ==="
cd "$SQLITE_SOURCE_DIR"

if [ "$SKIP_BUILD" = false ]; then
    make clean 2>/dev/null || true
    ./configure --gcov --linemacros
    make -j"$(nproc)" sqlite3
    log "Build complete."
else
    log "Skip build (--skip-build)"
fi

SQLITE3_BIN="${SQLITE_SOURCE_DIR}/sqlite3"
if [ ! -x "$SQLITE3_BIN" ]; then
    err "sqlite3 not found at $SQLITE3_BIN"
    exit 1
fi
log "sqlite3 version: $($SQLITE3_BIN --version 2>/dev/null || echo 'unknown')"

# ================= Step 2: Run SQL =================
log "=== Step 2: Run SQL workload ==="
set +e
"$SQLITE3_BIN" :memory: < "$CUSTOM_SQL_FILE" 2>&1 | tail -20
SQLITE_RC=$?
set -e
log "sqlite3 exit code: $SQLITE_RC"

# Track execution success
log "--- Checking execution success rates ---"
if [ -f "$CHECK_EXEC_SCRIPT" ]; then
    EXEC_RESULT=$(python3 "$CHECK_EXEC_SCRIPT" "$CUSTOM_SQL_FILE" "$SQLITE3_BIN" 2>/dev/null || echo '{"total_cases":0,"successful_cases":0,"case_execution_success_rate":0,"total_sql_statements":0,"successful_sql_statements":0,"sql_execution_success_rate":0}')
    echo "$EXEC_RESULT"
else
    log "WARNING: check_sql_execution.py not found"
fi

# ================= Step 3: Check gcda =================
log "=== Step 3: Check coverage data ==="
TOTAL_GCDA=$(find "$SQLITE_SOURCE_DIR" -name "*.gcda" | wc -l)
log "Total .gcda: $TOTAL_GCDA"
if [ "$TOTAL_GCDA" -lt 1 ]; then
    err "No .gcda files found!"
fi

# ================= Step 4: Generate report =================
log "=== Step 4: Generate lcov report ==="
export PATH="/opt/rh/devtoolset-11/root/usr/bin:$PATH"

cd "$SQLITE_SOURCE_DIR"
WORK_DATA_DIR="${WORKSPACE_BASE}/workspace/${SQL_BASENAME}"
mkdir -p "$WORK_DATA_DIR"

lcov --capture \
     --directory "$SQLITE_SOURCE_DIR" \
     --output-file "${WORK_DATA_DIR}/coverage.info" \
     --rc branch_coverage=1

lcov --remove "${WORK_DATA_DIR}/coverage.info" \
     '/usr/*' '*/test/*' '*/tool/*' '*/ext/*' \
     --output-file "${WORK_DATA_DIR}/coverage_filtered.info" \
     --rc branch_coverage=1

genhtml "${WORK_DATA_DIR}/coverage_filtered.info" \
        --output-directory "$REPORT_DIR" \
        --rc branch_coverage=1 \
        --title "SQLite Coverage - ${SQL_BASENAME}"

# Coverage summary
log "=== Coverage Summary ==="
LINE_C=$(lcov --summary "${WORK_DATA_DIR}/coverage_filtered.info" 2>&1 | grep "lines......" | awk '{print $2}' | tr -d '%')
FUNC_C=$(lcov --summary "${WORK_DATA_DIR}/coverage_filtered.info" 2>&1 | grep "functions." | awk '{print $2}' | tr -d '%')
BRANCH_C=$(lcov --summary "${WORK_DATA_DIR}/coverage_filtered.info" 2>&1 | grep "branches." | awk '{print $2}' | tr -d '%')
log "Line coverage: ${LINE_C}%"
log "Function coverage: ${FUNC_C}%"
log "Branch coverage: ${BRANCH_C}%"

# ================= Step 5: Recall/Precision =================
log "=== Step 5: Recall/Precision evaluation ==="
if [ -f "$JSON_DATASET_FILE" ] && [ -f "$EVAL_SCRIPT" ]; then
    log "Running recall eval..."
    python3 "$EVAL_SCRIPT" "$JSON_DATASET_FILE" "$REPORT_DIR" "$EVAL_RESULT_PATH"
    log "Recall eval done: $EVAL_RESULT_PATH"
else
    err "JSON dataset or eval script not found, skipping recall eval"
fi

# ================= Done =================
log "=== Done! ==="
log "Report: file://${REPORT_DIR}/index.html"
log "Result: $EVAL_RESULT_PATH"
log "Line: ${LINE_C}%, Func: ${FUNC_C}%, Branch: ${BRANCH_C}%"

# Clean gcda for next run
find "$SQLITE_SOURCE_DIR" -name "*.gcda" -delete
log "gcda cleaned"
