import json

input_file = ""
output_file = ""

target_dirs = [
    "parser/", "rewrite/", "optimizer/", "executor/", "nodes/",
    "commands/", "catalog/", "access/",
    "utils/adt/", "utils/sort/", "utils/fmgr/", "utils/cache/",
    "utils/mmgr/", "utils/mb/", "partitioning/", "foreign/",
    "tsearch/", "statistics/",
]
exclude_dirs = [
    "jit/", "replication/", "libpq/", "postmaster/",
    "bootstrap/", "port/", "main/",
]


def match_file(path):
    if not path.startswith("src/backend/"):
        return False
    for ex in exclude_dirs:
        if ex in path:
            return False
    return any(d in path for d in target_dirs)


def main():
    with open(input_file, "r", encoding="utf-8") as f:
        data = json.load(f)

    filtered = []
    for item in data:
        if "patches" not in item:
            continue
        mp = [p for p in item["patches"] if "file" in p and match_file(p["file"])]
        if mp:
            it = item.copy()
            it["patches"] = mp
            filtered.append(it)

    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(filtered, f, indent=2, ensure_ascii=False)

    print(f"Filtered: {len(filtered)}/{len(data)} records saved")


if __name__ == "__main__":
    main()
