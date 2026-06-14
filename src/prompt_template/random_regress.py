import json
import os
import time
from openai import OpenAI

# ---------------------------------------------------------
# DeepSeek API config
# ---------------------------------------------------------
API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")

client = OpenAI(
    api_key=API_KEY,
    base_url="https://api.deepseek.com"
)

def generate_random_sql(input_path, output_path):
    if not os.path.exists(input_path):
        print(f"Error: input file not found {input_path}")
        return

    commits = []
    processed_ids = set()

    if os.path.exists(output_path):
        print(f"Existing output file detected, attempting to resume...")
        try:
            with open(output_path, "r", encoding="utf-8") as f:
                commits = json.load(f)
            for c in commits:
                if "generated_sql_tests" in c and not c["generated_sql_tests"].startswith("Generation failed"):
                    processed_ids.add(c.get("id"))
            print(f"Resumed: {len(processed_ids)} completed commits found.")
        except json.JSONDecodeError:
            print("Output file is invalid or empty, will re-read input and start from scratch.")
            commits = []

    if not commits:
        with open(input_path, "r", encoding="utf-8") as f:
            commits = json.load(f)

    total_items = len(commits)
    pending = total_items - len(processed_ids)
    print(f"Starting: {total_items} total records, {pending} pending...\n")

    for i, item in enumerate(commits):
        item_id = item.get("id")

        if item_id in processed_ids:
            continue

        system_prompt = "You are an expert PostgreSQL kernel developer and QA testing engineer."

        user_prompt = """Generate 5 self-contained SQL test cases for PostgreSQL regression testing.

Each test case must include setup (CREATE/INSERT), execution, and teardown (DROP).

Cover a diverse range of PostgreSQL features: DML (SELECT/INSERT/UPDATE/DELETE), DDL (CREATE/ALTER), data types, joins, subqueries, aggregations, window functions, CTEs, etc.

Output ONLY the XML test cases — no analysis, no explanation, no markdown before or after.

Use EXACTLY this format:

<test_cases>
    <test_case id="1">
        <description>Briefly explain what this tests.</description>
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
</test_cases>"""

        print(f"[{i+1}/{total_items}] Requesting random SQL generation for Item ID {item_id}...")

        try:
            response = client.chat.completions.create(
                model="deepseek-chat",
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt}
                ],
                temperature=0.9,
                max_tokens=8192,
                timeout=120,
            )

            generated_sql = response.choices[0].message.content
            item["generated_sql_tests"] = generated_sql
            print(f"   Generation successful!")

        except Exception as e:
            print(f"   API request failed: {e}")
            item["generated_sql_tests"] = f"Generation failed: {e}"

        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(commits, f, ensure_ascii=False, indent=2)
        print(f"   Progress saved.\n")

        time.sleep(0.5)

    print(f"All done! Final results saved to: {output_path}")

if __name__ == "__main__":
    INPUT_FILE = ""  # Input JSON file path
    OUTPUT_FILE = ""  # Output results file path
    generate_random_sql(INPUT_FILE, OUTPUT_FILE)
