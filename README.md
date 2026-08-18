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
| 1 | Execution-time cost check | ⬜ |
| 2 | Open-source the expected-error classification & analysis (constraint/partition/permission/rule violations vs. syntax/hallucination/timeout/crash) | ⬜ |
| 3 | "intrinsic SQL difficulty" analysis and  sampled validation | ⬜ |
| 4 | Analyze retained/removed commits by year, subsystem, diff size, and type | ⬜|
| 5 | Add quick-start commands| ⬜|
