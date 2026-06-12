

import json
import os
import re
import sys
from bs4 import BeautifulSoup

# Original file providing commit data; use test.json for test set, train.json for training set
JSON_PATH = ""  # Input JSON file
# Path to the coverage HTML report directory
COVERAGE_DIR = ""  # Coverage report dir
# Path to the evaluation result file
RESULT_PATH = ""  # Evaluation result output path

# Lines to skip when counting "meaningful" added lines
TRIVIAL = re.compile(r'^\s*\{\s*\}$|^\s*\}\s*$|^\s*\}\s*;\s*$|^return\b')

# Known C type keywords (used to detect variable/function declarations)
C_TYPES = {
    'int', 'char', 'bool', 'float', 'double', 'long', 'short', 'void',
    'unsigned', 'signed', 'size_t', 'FILE', 'va_list',
    'int8', 'int16', 'int32', 'int64',
    'uint8', 'uint16', 'uint32', 'uint64',
    'Oid', 'Datum', 'BlockNumber', 'OffsetNumber', 'Index', 'xid', 'xid8',
    'TransactionId', 'CommandId', 'SubTransactionId',
    'PartitionKey', 'PartitionDesc',
    'Relation', 'HeapTuple', 'HeapScanDesc', 'Snapshot',
    'StringInfo', 'StringInfoData',
    'List', 'ListCell',
    'Node', 'Expr', 'Plan', 'PlanState',
    'struct', 'union', 'enum', 'typedef',
}

# PG functions that look like types (uppercase first letter) but aren't
NON_TYPES = {
    'PG_RETURN', 'PG_GETARG', 'PG_ARGISNULL', 'PG_FREE',
    'PG_MODULE_MAGIC', 'PG_MAGIC',
    'XLogReadBufferForRedoExtended',
    'ExecInitStoredGenerated', 'ExecShutdownNode_walker',
    'SetUserIdAndSecContext', 'GetUserIdAndSecContext',
    'DropErrorMsgWrongType',
}


def is_meaningful(line):
    return not TRIVIAL.match(line)


def is_comment(line):
    """Check if a line is a C comment."""
    s = line.strip()
    return s.startswith('*') or s.startswith('/*') or s.startswith('//')


def is_declaration(code):
    """
    Check if a C code line is a function or variable declaration.
    Used to exclude boilerplate declarations from recall/precision eval.
    """
    s = code.strip()
    if not s:
        return False

    # Skip comment lines
    if s.startswith('*') or s.startswith('/*') or s.startswith('//'):
        return False

    # Control flow is not a declaration
    first = s.split()[0] if s.split() else ''
    if first in ('if', 'for', 'while', 'switch', 'else', 'goto', 'do',
                 'case', 'return', 'break', 'continue'):
        return False

    # Skip type qualifiers (static, const, extern, etc.)
    rest = s
    for _ in range(4):
        tok = rest.split()[0] if rest.split() else ''
        if tok in ('static', 'const', 'extern', 'register', 'inline', 'volatile'):
            rest = rest[len(tok):].strip()
        else:
            break

    if not rest:
        return False

    first = rest.split()[0] if rest.split() else ''
    if not first:
        return False

    # Strip pointer suffix
    type_word = first.rstrip('*')
    if not type_word:
        return False

    # Check if first word is a known type
    is_type = type_word in C_TYPES or (
        type_word[0].isupper() and type_word not in NON_TYPES
    )
    if not is_type:
        return False

    # After the type word, check what follows
    after_type = rest[len(first):].strip()
    if not after_type:
        return False

    # Skip * for pointer type
    if after_type[0] == '*':
        after_type = after_type[1:].strip()

    if not after_type:
        return False

    # If the next character is (, it's a function call, not a declaration
    if after_type[0] == '(':
        return False

    # If next token starts with [ . -> = it's likely a struct access/assign, not declaration
    next_tok = after_type.split()[0]
    if next_tok in ('[', '.', '->', '=') or after_type[0] in ('[', '.', '->', '='):
        return False

    # Remaining cases: TYPE followed by identifier (variable or function name) = declaration
    return True


# =========================================================
# 1. Count meaningful added lines from diff_blocks
# =========================================================


def collect_added_lines(patches):
    """Collect all meaningful added lines from diff_blocks."""
    lines = []
    for patch in patches:
        fpath = patch.get('file', '')
        for block in patch.get('diff_blocks', []):
            for line in block.get('added', []):
                stripped = line.strip()
                if not stripped or not is_meaningful(stripped):
                    continue
                if is_comment(stripped) or is_declaration(stripped):
                    continue
                lines.append({
                    'file': fpath,
                    'code': stripped
                })
    return lines


def is_control_only(code):
    s = code.strip()
    if not s:
        return True
    if re.match(r'^\{\s*\}|^\}\s*;?\s*$', s):
        return True
    if re.match(r'^(continue|break)\s*;?\s*$', s):
        return True
    if re.match(r'^else\s*(?:\{|$)', s):
        return True
    if re.match(r'^goto\s+\w+\s*;?\s*$', s):
        return True
    return False


def count_meaningful_added(patches):
    total = 0
    for patch in patches:
        for block in patch.get('diff_blocks', []):
            for line in block.get('added', []):
                stripped = line.strip()
                if not stripped or not is_meaningful(stripped):
                    continue
                if is_comment(stripped) or is_declaration(stripped):
                    continue
                total += 1
    return total


# =========================================================
# 2. Path mapping: source file -> gcov HTML
# =========================================================

def find_gcov_path(file_path, coverage_dir):
    """
    Map src/... file path to gcov HTML report path.
    Tries multiple conventions since report may strip src/backend/ etc.
    """
    rel = file_path.replace('\\', '/')

    candidates = []

    # report/relpath.gcov.html  (keep full path as-is)
    candidates.append(os.path.join(coverage_dir, 'report', rel + '.gcov.html'))

    # Strip src/ prefix
    if rel.startswith('src/'):
        no_src = rel[4:]
        candidates.append(os.path.join(coverage_dir, 'report', no_src + '.gcov.html'))

        # Strip src/backend/ -> backend/ prefix
        if no_src.startswith('backend/'):
            no_backend = no_src[8:]
            candidates.append(os.path.join(coverage_dir, 'report', no_backend + '.gcov.html'))

    for path in candidates:
        if os.path.exists(path):
            return path
    return None


# =========================================================
# 3. Parse gcov HTML -> {line_no: execution_count}
# =========================================================

def parse_gcov(html_path):
    """Parse a gcov HTML file and return {line_no: {'count': int, 'gcov_code': str}}."""
    if not html_path or not os.path.exists(html_path):
        return {}

    with open(html_path, 'r', encoding='utf-8', errors='ignore') as f:
        soup = BeautifulSoup(f, 'html.parser')

    result = {}
    for a_tag in soup.find_all('a'):
        span_line = a_tag.find('span', class_='lineNum')
        if not span_line:
            continue

        try:
            line_no = int(span_line.text.strip())
        except ValueError:
            continue

        cov_span = a_tag.find('span', class_=re.compile('lineCov|lineNoCov|lineDead'))
        if not cov_span:
            continue

        raw = cov_span.text.strip()
        # Format: "  123 : code" or "##### : code" (dead/unreachable)
        match = re.match(r'^\s*(\d+|#####)\s*:\s*(.*)', raw)
        count = 0
        gcov_code = ''
        if match:
            if match.group(1) != '#####':
                count = int(match.group(1))
            gcov_code = match.group(2)

        result[line_no] = {'count': count, 'gcov_code': gcov_code}

    return result


def find_gcov_match(gcov_data, target_line, target_code, window=1):
    """
    Find the best matching line in gcov data within ±window of target_line.

    First tries exact trimmed-code match at the target line.
    Then searches ±window for exact trimmed-code match.
    Then searches ±window for substring match.
    Falls back to the target line if it exists in gcov data.

    Returns (gcov_line_no, count, gcov_code, match_type)
    match_type: 'exact', 'fuzzy', 'line_only', 'not_found'
    """
    target_clean = target_code.strip()
    if not target_clean:
        gcov_info = gcov_data.get(target_line)
        if gcov_info:
            return (target_line, gcov_info['count'], gcov_info['gcov_code'], 'exact')
        return (None, None, None, 'not_found')

    # 1. Try exact line first
    gcov_info = gcov_data.get(target_line)
    if gcov_info and gcov_info['gcov_code'].strip() == target_clean:
        return (target_line, gcov_info['count'], gcov_info['gcov_code'], 'exact')

    # 2. Search ±window for exact content match
    lo = max(1, target_line - window)
    hi = max(gcov_data.keys()) + 1 if gcov_data else target_line + window + 1

    best_fuzzy = None
    for line_no in range(lo, min(hi, target_line + window + 1)):
        info = gcov_data.get(line_no)
        if not info:
            continue
        gcov_clean = info['gcov_code'].strip()
        if gcov_clean == target_clean:
            match_type = 'fuzzy' if line_no != target_line else 'exact'
            return (line_no, info['count'], info['gcov_code'], match_type)
        # Substring match as fallback
        if best_fuzzy is None and (target_clean in gcov_clean or gcov_clean in target_clean):
            best_fuzzy = (line_no, info['count'], info['gcov_code'], 'fuzzy')

    if best_fuzzy:
        return best_fuzzy

    # 3. Fallback: target line exists in gcov (but content didn't match)
    if gcov_info:
        return (target_line, gcov_info['count'], gcov_info['gcov_code'], 'line_only')

    # 4. Truly not found
    return (None, None, None, 'not_found')


# =========================================================
# 4. Collect matched source lines from match_info
# =========================================================

def collect_matched_lines(match_info):
    """Collect {file, line_no, code} from match_info (only matched blocks).
    Filters out comments and declarations; deduplicates by (file, line_no).
    """
    lines = []
    seen = set()
    for patch in match_info.get('patches', []):
        file_path = patch.get('file', '')
        for block in patch.get('blocks', []):
            if not block.get('matched', False):
                continue
            for line_info in block.get('lines', []):
                code = line_info['code']
                if is_comment(code) or is_declaration(code):
                    continue
                key = (file_path, line_info['source_line'])
                if key in seen:
                    continue
                seen.add(key)
                lines.append({
                    'file': file_path,
                    'line_no': line_info['source_line'],
                    'code': code
                })
    return lines


# =========================================================
# 5. Evaluate a single dataset
# =========================================================

def evaluate_dataset(json_path, coverage_dir):
    with open(json_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    if isinstance(data, dict):
        data = [data]

    results = {}
    global_total_added = 0
    global_matched = 0
    global_covered = 0
    global_not_found = 0
    gcov_cache = {}  # html_path -> {line_no: {'count': int, 'gcov_code': str}}

    for item in data:
        item_id = item.get('id', 'unknown')
        patches = item.get('patches', [])
        match_info = item.get('match_info', {})

        # --- meaningful added lines ---
        total_added = count_meaningful_added(patches)

        # --- matched lines from match_info ---
        matched_lines = collect_matched_lines(match_info)
        total_matched = len(matched_lines)

        # --- check gcov coverage for each matched line ---
        covered = 0
        not_found = 0
        line_details = []

        for ml in matched_lines:
            fpath = ml['file']
            html_path = find_gcov_path(fpath, coverage_dir)

            if html_path is None:
                not_found += 1
                line_details.append({
                    'file': fpath,
                    'line_no': ml['line_no'],
                    'gcov_line_no': None,
                    'code': ml['code'],
                    'gcov_code': None,
                    'gcov_count': None,
                    'covered': False,
                    'match_type': 'gcov_not_found'
                })
                continue

            if html_path not in gcov_cache:
                gcov_cache[html_path] = parse_gcov(html_path)

            gcov_line_no, count, gcov_code, match_type = find_gcov_match(
                gcov_cache[html_path], ml['line_no'], ml['code'],
            )
            is_covered = count is not None and count > 0
            if is_covered:
                covered += 1
            if gcov_line_no is None:
                not_found += 1

            line_details.append({
                'file': fpath,
                'line_no': ml['line_no'],
                'gcov_line_no': gcov_line_no,
                'code': ml['code'],
                'gcov_code': gcov_code or '',
                'gcov_count': count,
                'covered': is_covered,
                'match_type': match_type or 'not_found'
            })

        recall = total_matched / total_added if total_added > 0 else 0.0
        precision = covered / total_matched if total_matched > 0 else 0.0

        exec_lines = [ld for ld in line_details if not is_control_only(ld['code'])]
        exec_matched = len(exec_lines)
        exec_covered = sum(1 for ld in exec_lines if ld['covered'])
        precision_excl_ctrl = exec_covered / exec_matched if exec_matched > 0 else 0.0
        precision_excl_not_found = covered / (total_matched - not_found) if (total_matched - not_found) > 0 else 0.0

        results[str(item_id)] = {
            'subject': item.get('subject', ''),
            'total_added': total_added,
            'total_matched': total_matched,
            'not_found': not_found,
            'covered': covered,
            'recall': round(recall, 4),
            'precision': round(precision, 4),
            'precision_excl_ctrl': round(precision_excl_ctrl, 4),
            'precision_excl_not_found': round(precision_excl_not_found, 4),
            'line_details': line_details
        }

        global_total_added += total_added
        global_matched += total_matched
        global_covered += covered
        global_not_found += not_found

        subj_short = item.get('subject', '')[:60]
        print()
        print("=" * 80)
        print("id={}: {}".format(item_id, subj_short))
        print("=" * 80)

        added_lines = collect_added_lines(patches)
        matched_set = {(ml['file'], ml['code']) for ml in matched_lines}
        print()
        print("[RECALL]   added={}, matched={}, recall={:.4f}".format(
            total_added, total_matched, recall))
        print("  Meaningful added lines ({} lines):".format(total_added))
        mc = uc = 0
        for al in added_lines:
            is_matched = (al['file'], al['code']) in matched_set
            tag = "  [MATCHED]  " if is_matched else "  [NOT-FOUND]"
            if is_matched:
                mc += 1
            else:
                uc += 1
            print("  {} file={} | {}".format(tag, al['file'], al['code']))
        print("  -> Result: matched={}, not_matched={}".format(mc, uc))

        print()
        print("[PRECISION] matched={}, not_found={}, covered={}, precision={:.4f} (excl_ctrl: {:.4f}, excl_not_found: {:.4f})".format(
            total_matched, not_found, covered, precision, precision_excl_ctrl, precision_excl_not_found))
        print("  Matched lines ({} lines):".format(total_matched))
        cc = mc2 = nf = 0
        for ld in line_details:
            gcov_str = str(ld['gcov_count']) if ld['gcov_count'] is not None else "NO_GCOV"
            ctrl_tag = " [CTRL]" if is_control_only(ld['code']) else ""
            mt = ld.get('match_type', '')
            mt_tag = " [FUZZY]" if mt == 'fuzzy' else " [LINE_ONLY]" if mt == 'line_only' else " [NO_GCOV]" if mt == 'gcov_not_found' else " [NOT_FOUND]" if mt == 'not_found' else ""
            ln_tag = ""
            if mt == 'fuzzy' and ld.get('gcov_line_no') is not None and ld['gcov_line_no'] != ld['line_no']:
                ln_tag = f" (gcov_L{ld['gcov_line_no']})"
            tag = "  [COVERED] " if ld['covered'] else "  [MISSED]  "
            if ld['covered']:
                cc += 1
            elif mt == 'gcov_not_found' or mt == 'not_found':
                nf += 1
            else:
                mc2 += 1
            print("  {}{}{}{} file={}:{} gcov={} | {}".format(
                tag, ctrl_tag, mt_tag, ln_tag, ld['file'], ld['line_no'], gcov_str, ld['code']))
        print("  -> Result: covered={}, missed={}, not_found={} (matched={}, exec_matched={})".format(cc, mc2, nf, total_matched, exec_matched))
        print()

    global_recall = global_matched / global_total_added if global_total_added > 0 else 0.0
    global_precision = global_covered / global_matched if global_matched > 0 else 0.0
    global_precision_excl_not_found = global_covered / (global_matched - global_not_found) if (global_matched - global_not_found) > 0 else 0.0

    all_exec_matched = 0
    all_exec_covered = 0
    for r in results.values():
        for ld in r['line_details']:
            if not is_control_only(ld['code']):
                all_exec_matched += 1
                if ld['covered']:
                    all_exec_covered += 1
    global_precision_excl_ctrl = all_exec_covered / all_exec_matched if all_exec_matched > 0 else 0.0

    summary = {
        'n_items': len(data),
        'total_meaningful_added': global_total_added,
        'total_matched': global_matched,
        'total_not_found': global_not_found,
        'total_covered': global_covered,
        'global_recall': round(global_recall, 4),
        'global_precision': round(global_precision, 4),
        'global_precision_excl_ctrl': round(global_precision_excl_ctrl, 4),
        'global_precision_excl_not_found': round(global_precision_excl_not_found, 4)
    }

    print(f"\n{'='*50}")
    print(f"SUMMARY ({json_path})")
    print(f"{'='*50}")
    print(f"Items:               {len(data)}")
    print(f"Meaningful added:    {global_total_added}")
    print(f"Matched in source:   {global_matched}")
    print(f"Not found in gcov:   {global_not_found}")
    print(f"Covered (executed):  {global_covered}")
    print(f"Recall (matched/added):   {global_recall:.4f}")
    print(f"Precision (covered/matched): {global_precision:.4f}")
    print(f"Precision excl. control flow: {global_precision_excl_ctrl:.4f}")
    print(f"Change-aware Cov:    {global_precision_excl_not_found:.4f}")

    return {'results': results, 'summary': summary}


# =========================================================
# 6. Main
# =========================================================

if __name__ == '__main__':
    json_path = sys.argv[1] if len(sys.argv) > 1 else JSON_PATH
    coverage_dir = sys.argv[2] if len(sys.argv) > 2 else COVERAGE_DIR
    result_path = sys.argv[3] if len(sys.argv) > 3 else RESULT_PATH

    eval_data = evaluate_dataset(json_path, coverage_dir)

    out_dir = os.path.dirname(result_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(result_path, 'w', encoding='utf-8') as f:
        json.dump(eval_data, f, indent=2, ensure_ascii=False)

    print(f"\nResults saved to: {result_path}")
