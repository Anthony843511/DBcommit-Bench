"""
Extract SQL test cases from generated JSON results
- Each commit's SQL saved to parsed_sql/<id>/ directory
- All SQL merged into gen_sql/ directory
"""
import json
import re
import os

INPUT_JSON = ""  # Input JSON file path
INPUT_NAME = ""
OUTPUT_DIR = ""  # Output directory for per-commit SQL files
MERGED_SQL_DIR = ""  # Directory for merged SQL file
MERGED_SQL_FILE = os.path.join(MERGED_SQL_DIR, "all_gen_sql.sql")


def extract_sql_blocks(text):
    return [b.strip() for b in re.findall(r"<sql>(.*?)</sql>", text, re.DOTALL)]


def clean_sql(sql):
    import textwrap
    lines = [line.rstrip() for line in sql.splitlines()]
    text = textwrap.dedent('\n'.join(lines))
    result = []
    in_copy = False
    for line in text.split('\n'):
        stripped = line.lstrip()
        if re.match(r"COPY\s", stripped) and "FROM STDIN" in stripped:
            in_copy = True
            result.append(line)
        elif in_copy and stripped == "\\." and line != stripped:
            result.append(stripped)
            in_copy = False
        elif in_copy:
            result.append(stripped)
        else:
            result.append(line)
    return '\n'.join(result).strip()


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(MERGED_SQL_DIR, exist_ok=True)

    with open(INPUT_JSON, "r") as f:
        data = json.load(f)

    if isinstance(data, dict):
        data = [data]

    all_sqls = []
    total_cases = 0

    for item in data:
        commit_id = item.get("id", "unknown")
        raw_sql_text = item.get("generated_sql_tests", "")
        sql_blocks = extract_sql_blocks(raw_sql_text)

        if not sql_blocks:
            continue

        cleaned_blocks = [clean_sql(sql) for sql in sql_blocks]
        for cleaned in cleaned_blocks:
            all_sqls.append((commit_id, cleaned))
            total_cases += 1

        # One file per commit, containing all test cases for that commit
        file_path = os.path.join(OUTPUT_DIR, "test_{}.sql".format(commit_id))
        with open(file_path, "w") as f:
            f.write("-- ===== Commit {} =====\n".format(commit_id))
            f.write("-- Source: {} - {}\n\n".format(item.get("commit", ""), item.get("subject", "")))
            for idx, cleaned in enumerate(cleaned_blocks):
                f.write("-- --- Test Case {} ---\n".format(idx + 1))
                f.write(cleaned + "\n\n")

    with open(MERGED_SQL_FILE, "w") as f:
        f.write("\\pset pager off\n")
        f.write("SET statement_timeout = 5000;\n")
        f.write("SET lock_timeout = 1000;\n")
        f.write("SET idle_in_transaction_session_timeout = 5000;\n\n")
        for i, (cid, sql) in enumerate(all_sqls):
            f.write("-- ===== Test Case {} (commit {}) =====\n".format(i + 1, cid))
            f.write(sql + "\n\n")

    print("Extraction complete:")
    print("- Input records: {}".format(len(data)))
    print("- SQL cases extracted: {}".format(total_cases))
    print("- Individual SQL dir: {}/<id>/".format(OUTPUT_DIR))
    print("- Merged SQL file: {}".format(MERGED_SQL_FILE))


if __name__ == "__main__":
    main()
