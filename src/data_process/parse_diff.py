import os
import json
import re

input_dir = ""
output_file = ""


def clean_line(line):
    return line.replace("\xa0", " ").replace("​", "").rstrip("\n")


def parse_diff(text):
    patches = []
    cur_file = cur_func = None
    before = after = []
    blocks = []

    for line in text.splitlines():
        line = clean_line(line)

        if line.startswith("diff --git"):
            if cur_file:
                patches.append({"file": cur_file, "function": cur_func,
                                "before_code": before, "after_code": after,
                                "raw_diff": text, "diff_blocks": blocks})
            cur_file = cur_func = None
            before = after = []
            blocks = []
            parts = line.split()
            if len(parts) >= 4:
                p = parts[3]
                cur_file = p[2:] if p.startswith("b/") else p
            continue

        if line.startswith("@@"):
            m = re.search(r"@@.*@@\s*(.*)", line)
            if m: cur_func = m.group(1).strip()
            blocks.append({"removed": [], "added": []})
            continue

        if line.startswith("-") and not line.startswith("---"):
            clean = line[1:]
            before.append(clean)
            if blocks: blocks[-1]["removed"].append(clean)
            continue

        if line.startswith("+") and not line.startswith("+++"):
            clean = line[1:]
            after.append(clean)
            if blocks: blocks[-1]["added"].append(clean)
            continue

        before.append(line)
        after.append(line)

    if cur_file:
        patches.append({"file": cur_file, "function": cur_func,
                        "before_code": before, "after_code": after,
                        "raw_diff": text, "diff_blocks": blocks})
    return patches


def process_folder(folder):
    all_data = []
    for fn in os.listdir(folder):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(folder, fn), "r", encoding="utf8") as f:
            d = json.load(f)
        m = d["metadata"]
        all_data.append({
            "id": m.get("id"), "subject": m.get("subject", ""),
            "author": m.get("from", ""), "date": m.get("date", ""),
            "message_id": m.get("message_id", ""),
            "source_message_url": m.get("source_message_url", ""),
            "details_git_url": m.get("details_git_url", ""),
            "email_body": d.get("email_body", ""),
            "patches": parse_diff(d.get("commit_diff_content", ""))
        })
    all_data.sort(key=lambda x: x["id"])
    return all_data


def main():
    merged = process_folder(input_dir)
    with open(output_file, "w", encoding="utf8") as f:
        json.dump(merged, f, indent=2, ensure_ascii=False)
    print("Done, commits:", len(merged))


if __name__ == "__main__":
    main()
