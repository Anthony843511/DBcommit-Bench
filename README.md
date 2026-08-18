# DBcommit-Bench & DBcommit-Agent

Official implementation & dataset for **DBcommit-Bench: SQL Test Generation for Change-aware Regression Testing of DBMSs**(Under review).

This work targets **change-aware regression testing for Database Management Systems (DBMSs)**. We build the first real-world benchmark for commit-level SQL test generation, and propose a multi-stage LLM reasoning agent to bridge the semantic gap between high-level SQL queries and low-level C kernel code of DBMSs.

---

## 📖 Abstract
DBMSs are continuously updated with massive code commits, which may introduce regressions. Currently, developers manually write SQL test cases to verify code changes, which is labor-intensive and hard to scale. Although LLMs show great potential for automated test generation, two major obstacles limit research in this field:
1. Lack of dedicated benchmarks for DBMS change-aware regression testing.
2. A huge semantic gap between SQL and DBMS internal C code.

To address these challenges:
- We present **DBcommit-Bench**, the first benchmark for change-aware DBMS regression testing, constructed from real commits of PostgreSQL and SQLite.
- We propose **DBcommit-Agent**, an LLM-based reasoning framework that decomposes SQL generation into four sequential stages.
- Extensive experiments prove our method outperforms traditional testing tools and vanilla LLM prompting strategies. Fine-tuning on our benchmark also consistently improves LLMs' domain capabilities.

 Datasets, code and evaluation scripts are fully open-sourced.
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

# Benchmark Results (Training Set)

| Method / Setting | DBMS | Change-aware Cov. | EffIdx | Line Cov. |
|---|---|---|---|---|
| DeepSeek-V4-Flash, Prompt | PostgreSQL | 42.44% | 2.272 | 33.90% |
| DeepSeek-V4-Flash, Agent | PostgreSQL | 58.22% | 3.467 | 38.80% |
| Qwen3-4B, Prompt | PostgreSQL | 18.67% | 1.158 | 25.50% |
| Qwen3-8B, Prompt | PostgreSQL | 26.67% | 1.582 | 25.80% |
| DeepSeek-V4-Flash, Prompt | SQLite | 64.29% | 3.706 | 40.60% |
| DeepSeek-V4-Flash, Agent | SQLite | 79.46% | 4.312 | 47.70% |
| Qwen3-4B | SQLite | 49.11% | 3.320 | 32.30% |
| Qwen3-8B | SQLite | 54.46% | 4.416 | 36.80% |

---

## To-do（push to GitHub）

| # | Content | Status |
|---|---|---|
| 1 | Execution-time cost check | ✅ |
| 2 | Open-source the expected-error classification & analysis (constraint/partition/permission/rule violations vs. syntax/hallucination/timeout/crash) | ⬜ |
| 3 | "intrinsic SQL difficulty" analysis and  sampled validation | ⬜ |
| 4 | Analyze retained/removed commits by year, subsystem, diff size, and type | ⬜|
| 5 | Add quick-start commands| part ✅ |
