## Quick Strart(Running & Evaluation Environment）
This repository is tested and evaluated under the environment specified below. 
### 1.Basic Environment
- OS: Ubuntu 22.04
- C Compiler: GCC 11.2.1 (for compiling database source code)
- Code Coverage Tool: lcov 1.16 (for calculating line coverage)

### 2.Database Kernels
- PostgreSQL 13.23
- SQLite 3.53.1

### 3.`run_eval.sh` — Configuration
When evaluating a different SQL file, adjust the parameters below according to the file under test:

| Variable | Meaning | Example value (`<repo>/...` = repo-root-relative) |
|---|---|---|
| `PG_SOURCE_DIR` | PostgreSQL **source dir** (build artifacts live here) | e.g. `<repo>/postgresql-13.23` |
| `PG_INSTALL_DIR` | Coverage-build PG install prefix; defaults to `${PG_SOURCE_DIR}/install_coverage/` | default is fine |
| `WORKSPACE_DIR` | This evaluation's **working dir** (data/logs/coverage report all go here) | e.g. `<repo>/output/workspace/pg_test_agent` |
| `REPORT_DIR` | Coverage HTML report output dir; defaults to `${WORKSPACE_DIR}/report` | default is fine |
| `CUSTOM_SQL_FILE` | **SQL file under test** (the generated SQL) | e.g. `<repo>/output/SQL/gen_sql/xxxx.sql` |
| `LOG_SAVE_DIR` | Directory where run logs are persisted (saved as `${LOG_SAVE_DIR}/run_<timestamp>.log`) | e.g. `<repo>/output/result/eval_result/` |
| `SOCKET_DIR` | PostgreSQL socket dir; **in real evaluation = workspace dir** | `$WORKSPACE_DIR` |
| `PORT` | Port | `55432` |
| `JSON_DATASET_FILE` | Ground-truth JSON for Change Cov. evaluation | e.g. `<repo>/data/test.json` |
| `EVAL_RESULT_PATH` | Output path of the Change Cov. result JSON | e.g. `<repo>/output/result/eval_result/pg_test_agent_result.json` |
| `EVAL_SCRIPT` | Python script for evaluation | e.g. `<repo>/src/eval_script/pg/eval_pg.py` (present here) |
| `ENABLE_BRANCH_COVERAGE` | Whether to enable branch coverage (1=enabled, 0=disabled) | `1` |

### 4.Usage

```bash
# 1) Edit the config block at the top, fill in the required values
vim run_eval.sh

# 2) Run 
./run_eval.sh
```

### 5. `run_eval_exec_time.sh` (PG execution-time check) — Usage

```bash
# Environment: coverage PG bin/lib in PATH + GNU time path
export PATH="$PG_SOURCE_DIR/install_coverage/bin:$PATH"
export LD_LIBRARY_PATH="$PG_SOURCE_DIR/install_coverage/lib:$LD_LIBRARY_PATH"
export TIME_BIN=/usr/bin/time            # to fill in: GNU time path (must support -v)

# Usage
./run_eval_exec_time.sh <sql_file> \
    [--socket-dir DIR] [--port PORT] [--db DB] [--out RESULT.txt]

# Example (repo sample SQL; socket=workspace, port, db consistent with run_eval.sh)
./run_eval_exec_time.sh data/sql/pg_test_example.sql \
    --socket-dir "$WORKSPACE_DIR" \
    --port 55432 --db regression \
    --out output/result/exec_time.txt
```
