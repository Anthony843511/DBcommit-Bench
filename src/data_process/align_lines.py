import json
import os
import re

SRC = ""
INPUTS = {}


def strip_c_comments(text):
    result = []; i = 0; in_block = False; in_string = False; q = None
    while i < len(text):
        if in_block:
            if text[i:i+2] == '*/': in_block = False; i += 2
            else: i += 1
        elif in_string:
            if text[i] == '\\' and i+1 < len(text):
                result.append(text[i]); result.append(text[i+1]); i += 2
            elif text[i] == q: in_string = False; result.append(text[i]); i += 1
            else: result.append(text[i]); i += 1
        else:
            if text[i] in '"\'':
                in_string = True; q = text[i]; result.append(text[i]); i += 1
            elif text[i:i+2] == '/*': in_block = True; i += 2
            elif text[i:i+2] == '//':
                while i < len(text) and text[i] != '\n': i += 1
            else: result.append(text[i]); i += 1
    return ''.join(result)


def get_func_lines(text):
    clean = strip_c_comments(text)
    return [l.strip() for l in clean.split('\n') if l.strip() and not l.strip().startswith('#')]


TRIVIAL = re.compile(
    r'^\{$|^\{\s*\}$|^\}\s*$|^\}\s*;\s*$|^return\b'
)


def is_meaningful(line):
    return not TRIVIAL.match(line)


def is_comment_line(line):
    s = line.strip()
    return s.startswith('*') or s.startswith('/*') or s.startswith('//')


def get_meaningful_lines(text):
    return [l for l in get_func_lines(text) if is_meaningful(l) and not is_comment_line(l)]


def get_meaningful_lines_with_pos(text):
    result = []
    for i, line in enumerate(text.split('\n')):
        stripped = strip_c_comments(line).strip()
        if stripped and not stripped.startswith('#') and is_meaningful(stripped) and not is_comment_line(stripped):
            result.append((stripped, i + 1))
    return result


def sliding_window_match(added, src_with_pos):
    n = len(added)
    m = len(src_with_pos)
    if n <= 1 or m < n:
        return False, 0.0, []
    best_matches = 0; best_pairs = []; best_pos = 0
    for i in range(m - n + 1):
        matches = sum(1 for j in range(n) if added[j] == src_with_pos[i + j][0])
        pairs = [(added[j], src_with_pos[i + j][1]) for j in range(n) if added[j] == src_with_pos[i + j][0]]
        if matches > best_matches:
            best_matches = matches; best_pairs = pairs; best_pos = i
    rate = best_matches / n if n > 0 else 0.0
    return rate >= 0.6, rate, best_pairs


sql_rules = [
    ('src/backend/parser/', True), ('src/pl/', True),
    ('src/include/parser/', True), ('src/backend/commands/', True),
    ('src/backend/tcop/', True), ('src/backend/executor/', True),
    ('src/backend/optimizer/', True), ('src/backend/jit/', True),
    ('src/backend/utils/adt/', True), ('src/backend/utils/fmgr/', True),
    ('src/backend/catalog/', True), ('src/include/catalog/', True),
    ('src/backend/access/', True), ('src/backend/replication/', True),
    ('src/backend/utils/misc/guc', True), ('src/backend/postgres_fdw/', True),
    ('contrib/', True), ('src/backend/access/transam/', True),
    ('src/backend/utils/misc/superuser.c', True), ('src/backend/libpq/auth.c', True),
    ('src/backend/libpq/be-secure.c', True),
]
internal_rules = [
    'src/backend/storage/', 'src/backend/postmaster/', 'src/backend/libpq/',
    'src/backend/utils/mmgr/', 'src/backend/utils/resowner/', 'src/backend/utils/cache/',
    'src/backend/utils/hash/', 'src/backend/utils/sort/', 'src/backend/utils/init/',
    'src/backend/utils/error/', 'src/backend/lib/', 'src/backend/statistics/',
    'src/backend/main/', 'src/backend/port/', 'src/backend/snowball/',
    'src/port/', 'src/common/', 'src/timezone/',
]


def is_sql_verifiable(commit):
    for p in commit.get('patches', []):
        f = p.get('file', '')
        for prefix, _ in sql_rules:
            if f.startswith(prefix):
                return True
        for prefix in internal_rules:
            if f.startswith(prefix):
                return False
        for b in p.get('diff_blocks', []):
            if b.get('added'):
                return True
    return False


def process_commit(item, file_cache):
    patches = item.get('patches', [])
    if not patches:
        return 0, None

    all_match = True
    info_patches = []

    for p in patches:
        fpath = p.get('file', '').replace('\\', '/')
        full = os.path.join(SRC, fpath)

        if not os.path.exists(full):
            all_match = False
            info_patches.append({"file": fpath, "blocks": [], "error": "not_found"})
            continue

        if full not in file_cache:
            try:
                with open(full, 'r', encoding='utf-8', errors='replace') as sf:
                    file_cache[full] = sf.read()
            except Exception:
                file_cache[full] = None

        src_text = file_cache[full]
        if src_text is None:
            all_match = False
            info_patches.append({"file": fpath, "blocks": [], "error": "read_error"})
            continue

        src_with_pos = get_meaningful_lines_with_pos(src_text)
        patch_match = False
        block_infos = []

        for bi, b in enumerate(p.get('diff_blocks', [])):
            added = b.get('added', [])
            if not added:
                continue
            added_meaningful = get_meaningful_lines('\n'.join(added))
            if len(added_meaningful) <= 1:
                continue
            matched, rate, pairs = sliding_window_match(added_meaningful, src_with_pos)
            if matched: patch_match = True
            block_infos.append({
                "block": bi, "match_rate": round(rate, 2), "matched": matched,
                "lines": [{"code": p[0], "source_line": p[1]} for p in pairs]
            })

        info_patches.append({"file": fpath, "blocks": block_infos, "patch_matched": patch_match})
        if not patch_match: all_match = False

    sql_ok = is_sql_verifiable(item)
    flag = 1 if (all_match and sql_ok) else 0
    return flag, {"matched": flag == 1, "patches": info_patches}


def main():
    for IN_FILE, OUT_FILE in INPUTS.items():
        print(f'\n{"="*60}')
        print(f'{IN_FILE} -> {OUT_FILE}')
        print(f'{"="*60}')

        with open(IN_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)

        file_cache = {}
        flag1 = 0
        total = len(data)

        for idx, item in enumerate(data):
            fg, info = process_commit(item, file_cache)
            item['flag'] = fg
            item['match_info'] = info
            if fg == 1: flag1 += 1
            if (idx + 1) % 50 == 0 or idx == 0 or idx == total - 1:
                print(f'  {idx+1}/{total} (flag=1: {flag1})')

        with open(OUT_FILE, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

        print(f'Saved: {OUT_FILE}')
        print(f'flag=1: {flag1}/{total} = {flag1/total*100:.1f}%')


if __name__ == "__main__":
    main()
