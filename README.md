# DBcommit-Bench & DBcommit-Agent

Official implementation & dataset for **DBcommit-Bench: SQL Test Generation for Change-aware Regression Testing of DBMSs**.

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

All datasets, code and evaluation scripts will be fully open-sourced.
The dataset and code have been open-sourced, and we are actively organizing the remaining materials.
