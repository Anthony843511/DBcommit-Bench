# Data Processing Pipeline

This directory contains four scripts that form a sequential pipeline for collecting, parsing, filtering, and aligning commit data for DBcommit-Bench.

## Pipeline Overview

```
crawler.py  →  parse_diff.py  →  filter_commits.py  →  align_lines.py
```
