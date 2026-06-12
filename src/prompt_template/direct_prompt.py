import json
import os
import time
from openai import OpenAI

# ---------------------------------------------------------
# Configure API
# ---------------------------------------------------------
API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")

client = OpenAI(
    api_key=API_KEY,
    base_url="https://api.deepseek.com"
)

def generate_sql_tests_deepseek(input_path, output_path):
    if not os.path.exists(input_path):
        print(f"Error: input file not found {input_path}")
        return

    commits = []
    processed_ids = set()

    # 1. Try to load existing progress (resume checkpoint logic)
    if os.path.exists(output_path):
        print(f"Existing output file detected, attempting to resume progress...")
        try:
            with open(output_path, 'r', encoding='utf-8') as f:
                commits = json.load(f)
            for c in commits:
                if "generated_sql_tests" in c and not c["generated_sql_tests"].startswith("Generation failed"):
                    processed_ids.add(c.get("id"))
            print(f"Resumed: found {len(processed_ids)} completed commits.")
        except json.JSONDecodeError:
            print("Output file is malformed or empty, will re-read the original input file and start fresh.")
            commits = []

    # 2. If no progress (first run) or read failed, load the original input file
    if not commits:
        with open(input_path, 'r', encoding='utf-8') as f:
            commits = json.load(f)

    total_commits = len(commits)
    pending_commits = total_commits - len(processed_ids)
    print(f"Task started: {total_commits} total records, {pending_commits} pending...\n")

    for i, commit in enumerate(commits):
        commit_id = commit.get("id")

        # 3. Skip if already processed (resume support)
        if commit_id in processed_ids:
            continue

        subject = commit.get("subject", "")
        message = commit.get("email_body", "")

        all_diffs = ""
        for patch in commit.get("patches", []):
            all_diffs += f"File: {patch.get('file')}\n"
            all_diffs += f"Diff:\n{patch.get('raw_diff')}\n\n"

        if not all_diffs.strip():
            print(f"[{i+1}/{total_commits}] Commit ID {commit_id} has no code changes, skipping.")
            commit["generated_sql_tests"] = "No code changes"
            with open(output_path, 'w', encoding='utf-8') as f:
                json.dump(commits, f, ensure_ascii=False, indent=2)
            continue

        # ---------------------------------------------------------
        # Prompt configuration
        # ---------------------------------------------------------
        system_prompt = (
            "You are an expert PostgreSQL kernel developer and QA testing engineer. "
            "Your task is to generate PostgreSQL test scripts that exercise newly added or modified C code paths "
            "so that their code coverage can be measured. "
            "Output strictly using the provided XML-like tags, no extra text."
        )

        user_prompt = f"""I have modified the C source code of PostgreSQL. Below are the commit details and the code diff.

[Commit Subject]: {subject}
[Commit Message]: {message}

[Code Diff]:
{all_diffs}

Please analyze the C source code changes. Then write exactly 5 self-contained SQL test cases that exercise the new or modified code paths.

Requirements:
1. Coverage only — the SQL just needs to reach the new code paths. No need to verify output correctness.
2. Self-contained — each test must independently CREATE tables/data, execute the target query, and DROP afterwards.
3. Diverse — cover normal case, edge cases (NULL, empty, duplicates), invalid/error-triggering cases, and different call sites if applicable.
4. Output format — wrap everything in <test_cases>...</test_cases>, each case in <test_case id="N"> with <description> and <sql>. No markdown, no extra text outside the XML tags.

Use EXACTLY this structure:

<test_cases>
    <test_case id="1">
        <description>Briefly explain which code path this test targets.</description>
        <sql>
-- Setup
DROP TABLE IF EXISTS test_t1 CASCADE;
CREATE TABLE test_t1 (id INT);
INSERT INTO test_t1 VALUES (1);

-- Execution
SELECT * FROM test_t1 WHERE id = 1;

-- Teardown
DROP TABLE IF EXISTS test_t1 CASCADE;
        </sql>
    </test_case>
</test_cases>
"""

        print(f"[{i+1}/{total_commits}] Requesting DeepSeek API for Commit ID {commit_id}...")

        try:
            response = client.chat.completions.create(
                model="deepseek-chat",
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt}
                ],
                temperature=0.2,
                max_tokens=8192,
                timeout=120
            )

            generated_sql = response.choices[0].message.content
            commit["generated_sql_tests"] = generated_sql
            print(f"   Generated successfully!")

        except Exception as e:
            print(f"   API request failed: {e}")
            commit["generated_sql_tests"] = f"Generation failed: {e}"

        # 4. Save in real-time: overwrite output file after each API call
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(commits, f, ensure_ascii=False, indent=2)
        print(f"   Progress saved.\n")

        time.sleep(1)

    print(f"All done! Final results saved to: {output_path}")

if __name__ == "__main__":
    INPUT_FILE = ""  # Input file path
    OUTPUT_FILE = ""  # Output file path
    generate_sql_tests_deepseek(INPUT_FILE, OUTPUT_FILE)
