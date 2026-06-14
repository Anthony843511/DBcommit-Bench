import json
import subprocess
import sys
import os
import shutil
import re


def prepare_database():
    """Copy database from source to destination"""
    source_dir = ""  # source db path
    dest_dir = ""  # target copy path

    print(f"\n{'=' * 60}", flush=True)
    print(f" Preparing database environment...", flush=True)
    print(f" Source: {source_dir}", flush=True)
    print(f" Target: {dest_dir}", flush=True)

    try:
        if os.path.exists(dest_dir):
            print(f" Removing old copy...", flush=True)
            shutil.rmtree(dest_dir)

        shutil.copytree(source_dir, dest_dir)

        print(f" Database copy successful! Ready.", flush=True)
        print(f"{'=' * 60}\n", flush=True)
        return dest_dir

    except Exception as e:
        print(f" Database copy failed: {e}", flush=True)
        sys.exit(1)


def extract_final_sql_anchored(text):
    """Extract SQL test cases from agent response"""

    # Prefer XML-format test_cases
    test_cases_match = re.search(r'<test_cases>(.*?)</test_cases>', text, re.DOTALL)
    if test_cases_match:
        print(f" Extracted XML-format test cases", flush=True)
        return test_cases_match.group(0).strip()

    # Fallback: extract ```sql blocks
    sql_blocks = re.findall(r'```sql\s*(.*?)\s*```', text, re.DOTALL)
    if sql_blocks:
        print(f" Extracted {len(sql_blocks)} SQL block(s)", flush=True)
        return sql_blocks[-1].strip()

    return None


def main():
    JSON_FILE = ""  # input (JSON, not JSONL)
    PYTHON_SCRIPT = ""  # agent script
    OUTPUT_FILE = ""  # output
    time = ""  # debug output dir

    if not os.path.exists(JSON_FILE):
        print(f" Error: file not found {JSON_FILE}")
        return

    db_path = prepare_database()

    env = os.environ.copy()
    env["PG_SOURCE_ROOT"] = db_path
    env["DB_PATH"] = db_path

    print(f" Processing file...", flush=True)

    # Read the entire JSON array
    try:
        with open(JSON_FILE, 'r', encoding='utf-8') as f:
            data_list = json.load(f)
    except json.JSONDecodeError as e:
        print(f" JSON parse error: {e}", flush=True)
        return
    except Exception as e:
        print(f" File read error: {e}", flush=True)
        return

    print(f" Loaded {len(data_list)} records", flush=True)

    # Truncate or create output file
    if os.path.exists(OUTPUT_FILE):
        os.remove(OUTPUT_FILE)

    success_count = 0
    error_count = 0
    skipped_count = 0

    for idx, data in enumerate(data_list):
        task_id = data.get("id", f"Item_{idx}")
        task_flag = data.get("flag", 0)

        # Only process flag=1 tasks
        if task_flag != 1:
            print(f" Skipping task {task_id} (flag={task_flag})")
            skipped_count += 1
            continue

        task_prompt = data.get("task_prompt_v1")
        if not task_prompt:
            print(f" Warning: task {task_id} has no task field, skipping")
            skipped_count += 1
            continue

        patches = data.get("patches", [])
        if patches and isinstance(patches, list) and len(patches) > 0:
            changed_file = patches[0].get("file", "unknown")
        else:
            changed_file = "unknown"

        print(f"\n{'=' * 60}", flush=True)
        print(f" Task ID: {task_id}", flush=True)
        print(f" Changed file: {changed_file}", flush=True)
        print(f" Task prompt length: {len(task_prompt)} chars", flush=True)
        print(f"{'=' * 60}", flush=True)

        cmd = [
            sys.executable,
            "-u",
            PYTHON_SCRIPT,
            "-t", changed_file,
            "-i", f"{task_id}",
            "-p", task_prompt,
            "-yolo"
        ]

        try:
            process = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env
            )

            full_output = ""

            for output_line in iter(process.stdout.readline, ''):
                if not output_line:
                    break

                print(output_line, end='', flush=True)
                full_output += output_line

                # Auto-send enter on completion signal
                if "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT" in output_line:
                    print("\n Detected task completion, auto-sending enter...", flush=True)
                    if process.stdin:
                        process.stdin.write('\n')
                        process.stdin.flush()

            try:
                process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                print(f" Task {task_id} timed out (120s)", flush=True)
                process.kill()
                error_count += 1
                continue

            print(f"\n Task {task_id} finished", flush=True)

            predicted_sql = extract_final_sql_anchored(full_output)

            if predicted_sql:
                print(f" SQL extracted successfully (length: {len(predicted_sql)} chars)", flush=True)
                success_count += 1
            else:
                print(f" Could not extract SQL", flush=True)
                debug_file = f"{time}/debug_task_{task_id}.txt"
                with open(debug_file, 'w', encoding='utf-8') as df:
                    df.write(full_output)
                print(f" Debug info saved to: {debug_file}", flush=True)

            result_data = {
                "instance_id": task_id,
                "db_id": task_flag,
                "changed_file": changed_file,
                "pred_sqls": [predicted_sql] if predicted_sql else ["FAILED"],
                "full_reasoning": full_output
            }

            with open(OUTPUT_FILE, 'a', encoding='utf-8') as f:
                f.write(json.dumps(result_data, ensure_ascii=False) + '\n')
                f.flush()

        except Exception as e:
            print(f" Task {task_id} error: {e}", flush=True)
            import traceback
            traceback.print_exc()
            error_count += 1

    # Print summary
    print(f"\n{'=' * 60}", flush=True)
    print(f" Summary:", flush=True)
    print(f"  Total tasks: {len(data_list)}", flush=True)
    print(f"  Succeeded: {success_count}", flush=True)
    print(f"  Skipped: {skipped_count}", flush=True)
    print(f"  Failed: {error_count}", flush=True)
    print(f"  Output file: {OUTPUT_FILE}", flush=True)
    print(f"{'=' * 60}", flush=True)


if __name__ == "__main__":
    main()
