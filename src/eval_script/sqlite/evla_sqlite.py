# -*- coding: utf-8 -*-
"""SQLite recall/precision evaluation v2 (fixed gcov path)."""
import json, os, re, sys
from bs4 import BeautifulSoup

TRIVIAL = re.compile(r"^\s*\{\s*\}$|^\s*\}\s*$|^\s*\}\s*;\s*$|^return\b|^\*|^/\*|^\*/|^//")

C_TYPES = {"int","char","bool","float","double","long","short","void","unsigned","signed","size_t","FILE","va_list","int8","int16","int32","int64","uint8","uint16","uint32","uint64","struct","union","enum","typedef"}
SQLITE_TYPES = {"sqlite3","sqlite3_int64","sqlite3_uint64","u8","u16","u32","u64","i8","i16","i32","i64","Expr","ExprList","Select","Table","Index","Vdbe","Parse","SrcList","WhereInfo","WhereLoop","WhereTerm","WhereClause","AggInfo","NameContext","Walker","Window","WindowList","Mem","VdbeOp","VdbeCursor","KeyInfo","UnpackedRecord","Schema","Hash","BtCursor","BtShared","Btree","BtreePayload","Pager","PgHdr","Pcache","Pcache1","DbPage","Wal","WalIterator","CollSeq","FuncDef","Column","Trigger","TriggerStep","FKey","Module","VTable","sqlite3_vtab","SrcItem","IdList","IncrMerger","JsonParse","JsonNode","JsonString"}

def is_meaningful(line):
    return not TRIVIAL.match(line)

def is_comment(s):
    return s.strip().startswith("*") or s.strip().startswith("/*") or s.strip().startswith("//")

def is_declaration(code):
    s = code.strip()
    if not s or s.startswith("*") or s.startswith("/*") or s.startswith("//"):
        return False
    first = s.split()[0] if s.split() else ""
    if first in ("if","for","while","switch","else","goto","do","case","return","break","continue"):
        return False
    rest = s
    for _ in range(4):
        tok = rest.split()[0] if rest.split() else ""
        if tok in ("static","const","extern","register","inline","volatile"):
            rest = rest[len(tok):].strip()
        else:
            break
    if not rest:
        return False
    first = rest.split()[0] if rest.split() else ""
    if not first:
        return False
    type_word = first.rstrip("*")
    if not type_word:
        return False
    is_type = type_word in C_TYPES or type_word in SQLITE_TYPES or (type_word[0].isupper() and type_word not in {"PG_RETURN","PG_GETARG"})
    if not is_type:
        return False
    after_type = rest[len(first):].strip()
    if not after_type:
        return False
    if after_type[0] == "*":
        after_type = after_type[1:].strip()
    if not after_type or after_type[0] == "(":
        return False
    next_tok = after_type.split()[0]
    if next_tok in ("[",".","->","=") or after_type[0] in ("[",".","->","="):
        return False
    return True

def count_meaningful_added(patches):
    t = 0
    for p in patches:
        for b in p.get("diff_blocks",[]):
            for l in b.get("added",[]):
                s = l.strip()
                if not s or not is_meaningful(s) or is_comment(s) or is_declaration(s):
                    continue
                t += 1
    return t

def find_gcov_path(file_path, coverage_dir):
    base = os.path.basename(file_path.replace("\\","/"))
    for p in [
        os.path.join(coverage_dir, "sqlite", "tsrc", base + ".gcov.html"),
        os.path.join(coverage_dir, "sqlite", base + ".gcov.html"),
        os.path.join(coverage_dir, "html", "sqlite", "tsrc", base + ".gcov.html"),
        os.path.join(coverage_dir, "html", "sqlite", base + ".gcov.html"),
    ]:
        if os.path.exists(p):
            return p
    return None

def parse_gcov(html_path):
    if not html_path or not os.path.exists(html_path):
        return {}
    with open(html_path, "r", encoding="utf-8", errors="ignore") as f:
        soup = BeautifulSoup(f, "html.parser")
    result = {}
    for a_tag in soup.find_all("a"):
        span_line = a_tag.find("span", class_="lineNum")
        if not span_line:
            continue
        try:
            line_no = int(span_line.text.strip())
        except ValueError:
            continue
        cov_span = a_tag.find("span", class_=re.compile("lineCov|lineNoCov|lineDead"))
        if not cov_span:
            continue
        raw = cov_span.text.strip()
        m = re.match(r"^\s*(\d+|#####)\s*:\s*(.*)", raw)
        count = 0
        gcov_code = ""
        if m:
            if m.group(1) != "#####":
                count = int(m.group(1))
            gcov_code = m.group(2)
        result[line_no] = {"count": count, "gcov_code": gcov_code}
    return result

def find_gcov_match(gcov_data, target_line, target_code, window=30):
    target_clean = target_code.strip()
    if not target_clean:
        info = gcov_data.get(target_line)
        if info:
            return (target_line, info["count"], info["gcov_code"], "exact")
        return (None, None, None, "not_found")
    info_at_target = gcov_data.get(target_line)
    if info_at_target and info_at_target["gcov_code"].strip() == target_clean:
        return (target_line, info_at_target["count"], info_at_target["gcov_code"], "exact")
    lo = max(1, target_line - window)
    hi = max(gcov_data.keys()) + 1 if gcov_data else target_line + window + 1
    best_fuzzy = None
    for line_no in range(lo, min(hi, target_line + window + 1)):
        info = gcov_data.get(line_no)
        if not info:
            continue
        clean = info["gcov_code"].strip()
        if clean == target_clean:
            mt = "fuzzy" if line_no != target_line else "exact"
            return (line_no, info["count"], info["gcov_code"], mt)
        if best_fuzzy is None and (target_clean in clean or clean in target_clean):
            best_fuzzy = (line_no, info["count"], info["gcov_code"], "fuzzy")
    if best_fuzzy:
        return best_fuzzy
    if info_at_target:
        return (target_line, info_at_target["count"], info_at_target["gcov_code"], "line_only")
    return (None, None, None, "not_found")

def collect_matched_lines(match_info):
    lines = []
    seen = set()
    for patch in match_info.get("patches",[]):
        fpath = patch.get("file","")
        for block in patch.get("blocks",[]):
            if not block.get("matched",False):
                continue
            for li in block.get("lines",[]):
                code = li["code"]
                if is_comment(code) or is_declaration(code):
                    continue
                key = (fpath, li["source_line"])
                if key in seen:
                    continue
                seen.add(key)
                lines.append({"file":fpath,"line_no":li["source_line"],"code":code})
    return lines

def evaluate_dataset(json_path, coverage_dir):
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data,dict):
        data = [data]
    results = {}
    g_total = g_matched = g_covered = g_not_found = 0
    gcov_cache = {}
    for idx, item in enumerate(data):
        iid = item.get("id","idx%d"%idx)
        total_added = count_meaningful_added(item.get("patches",[]))
        matched_lines = collect_matched_lines(item.get("match_info",{}))
        total_matched = len(matched_lines)
        covered = not_found = 0
        line_details = []
        for ml in matched_lines:
            fpath = ml["file"]
            html_path = find_gcov_path(fpath, coverage_dir)
            if html_path is None:
                not_found += 1
                line_details.append({"file":fpath,"line_no":ml["line_no"],"gcov_line_no":None,"code":ml["code"],"gcov_code":None,"gcov_count":None,"covered":False,"match_type":"gcov_not_found"})
                continue
            if html_path not in gcov_cache:
                gcov_cache[html_path] = parse_gcov(html_path)
            gcov_line_no, count, gcov_code, match_type = find_gcov_match(gcov_cache[html_path], ml["line_no"], ml["code"], window=30)
            is_covered = count is not None and count > 0
            if is_covered:
                covered += 1
            if gcov_line_no is None:
                not_found += 1
            line_details.append({"file":fpath,"line_no":ml["line_no"],"gcov_line_no":gcov_line_no,"code":ml["code"],"gcov_code":gcov_code or "","gcov_count":count,"covered":is_covered,"match_type":match_type or "not_found"})
        recall = total_matched/total_added if total_added>0 else 0.0
        precision = covered/total_matched if total_matched>0 else 0.0
        prec_excl = covered/(total_matched-not_found) if (total_matched-not_found)>0 else 0.0
        results[str(iid)] = {"subject":item.get("subject",""),"total_added":total_added,"total_matched":total_matched,"not_found":not_found,"covered":covered,"recall":round(recall,4),"precision":round(precision,4),"precision_excl_not_found":round(prec_excl,4),"line_details":line_details}
        g_total += total_added
        g_matched += total_matched
        g_covered += covered
        g_not_found += not_found
        print("  id=%s added=%d matched=%d not_found=%d covered=%d recall=%.4f precision=%.4f prec_excl_nf=%.4f" % (iid,total_added,total_matched,not_found,covered,recall,precision,prec_excl), flush=True)
    gr = g_matched/g_total if g_total>0 else 0.0
    gp = g_covered/g_matched if g_matched>0 else 0.0
    gpe = g_covered/(g_matched-g_not_found) if (g_matched-g_not_found)>0 else 0.0
    print("\n" + "="*50)
    print("COVERAGE SUMMARY (%s)" % json_path)
    print("="*50)
    print("Items:               %d" % len(data))
    print("Meaningful added:    %d" % g_total)
    print("Matched in source:   %d" % g_matched)
    print("Not found in gcov:   %d" % g_not_found)
    print("Covered (executed):  %d" % g_covered)
    print("Recall (matched/added):   %.4f" % gr)
    print("Precision (covered/matched): %.4f" % gp)
    print("Change-aware Cov:    %.4f" % gpe)
    return {"results":results,"summary":{"n_items":len(data),"total_meaningful_added":g_total,"total_matched":g_matched,"total_not_found":g_not_found,"total_covered":g_covered,"global_recall":round(gr,4),"global_precision":round(gp,4),"global_precision_excl_not_found":round(gpe,4)}}

if __name__ == "__main__":
    json_path = sys.argv[1] if len(sys.argv)>1 else ""  # Input JSON file
    coverage_dir = sys.argv[2] if len(sys.argv)>2 else ""  # Coverage report dir
    result_path = sys.argv[3] if len(sys.argv)>3 else ""  # Output result path
    eval_data = evaluate_dataset(json_path, coverage_dir)
    out_dir = os.path.dirname(result_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(result_path, "w", encoding="utf-8") as f:
        json.dump(eval_data, f, indent=2, ensure_ascii=False)
    print("\nResults saved to: %s" % result_path)
