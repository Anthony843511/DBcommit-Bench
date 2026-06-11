# DBcommit-Bench & DBcommit-Agent

Official implementation & dataset for **DBcommit-Bench: SQL Test Generation for Change-aware Regression Testing of DBMSs** (ICDE 2026).

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

All datasets, code and evaluation scripts are fully open-sourced.

---

## 🎯 Key Contributions
1. **Novel Benchmark (DBcommit-Bench)**
   The first public benchmark for commit-level SQL test generation in DBMS regression testing.
   - PostgreSQL: 656 valid SQL-coverable commits (filtered from 9,784 raw commits)
   - SQLite: 2,495 valid SQL-coverable commits (filtered from 33,985 raw commits)
   - Complete data filtering pipeline & line number alignment with sliding-window algorithm
   - Four standardized evaluation metrics for fair comparison

2. **Multi-stage LLM Agent (DBcommit-Agent)**
   A dedicated reasoning framework to resolve the SQL-C semantic gap:
   `Commit Understanding → Code Localization → Context Retrieval → SQL Generation`
   Outperforms random SQL generators and direct LLM prompting on both complex and lightweight DBMSs.

3. **Comprehensive Evaluations**
   We evaluate traditional DBMS testing tools, vanilla LLM prompts, our agent and LLM fine-tuning. We also analyze model efficiency, cost, failure cases and cross-DBMS generalization.

4. **Open Resources**
   Release all raw data, preprocessed commits, agent code, evaluation tools and LoRA fine-tuning scripts for community research.

---

## 📊 Benchmark Statistics
### Commit Collection & Filtering
| DBMS | Raw Commits | After Basic Filtering | Final SQL-Coverable Commits |
| :--- | :--- | :--- | :--- |
| PostgreSQL | 9,784 | 784 | 656 |
| SQLite | 33,985 | 2,670 | 2,495 |
