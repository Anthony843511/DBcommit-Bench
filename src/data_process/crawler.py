import requests
from bs4 import BeautifulSoup
import time
import os
import json
import re
from datetime import datetime, timedelta
from urllib.parse import urljoin

BASE_LIST_URL = ""
BASE_DOMAIN = ""
OUTPUT_DIR = ""

START_DATE = datetime(2024, 1, 1)
END_DATE = datetime(2004, 1, 1)
STEP_DAYS = 1

DELAY_LIST = 1.0
DELAY_MSG_DETAIL = 1.5
DELAY_GIT_DIFF = 1.5

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
}


def get_next_id():
    max_id = 0
    if not os.path.exists(OUTPUT_DIR):
        return 1
    for fn in os.listdir(OUTPUT_DIR):
        if not fn.endswith('.json'):
            continue
        try:
            with open(os.path.join(OUTPUT_DIR, fn), 'r', encoding='utf-8') as f:
                d = json.load(f)
                cid = d.get('metadata', {}).get('id', 0)
                if isinstance(cid, int) and cid > max_id:
                    max_id = cid
        except (json.JSONDecodeError, IOError):
            continue
    return max_id + 1


def sanitize_filename(subject):
    safe = subject[7:] if subject.startswith("pgsql: ") else subject
    safe = re.sub(r'[<>:"/\\|?*]', '_', safe).strip()
    return safe[:150] + ".json"


def fetch_html(url):
    try:
        resp = requests.get(url, headers=HEADERS, timeout=20)
        resp.raise_for_status()
        resp.encoding = resp.apparent_encoding
        return resp.text
    except Exception as e:
        print(f"    [Error] {e}")
        return None


def extract_message_links(html, base_url):
    soup = BeautifulSoup(html, 'html.parser')
    table = soup.find('table')
    if not table:
        return []
    links = []
    for a in table.find_all('a', href=True):
        if '/message-id/' in a['href']:
            links.append((a.get_text(strip=True), urljoin(base_url, a['href'])))
    return links


def parse_message(html, msg_url):
    soup = BeautifulSoup(html, 'html.parser')
    text = soup.get_text()
    data = {"subject": "", "from": "", "date": "", "message_id": "",
            "body": "", "details_url": None, "source_url": msg_url}

    m = re.search(r'Subject:\s*(.+?)(?=Date:|Message-ID:|$)', text, re.DOTALL | re.IGNORECASE)
    if m: data['subject'] = m.group(1).strip()
    m = re.search(r'From:\s*(.+?)(?=To:|Subject:|$)', text, re.DOTALL | re.IGNORECASE)
    if m: data['from'] = m.group(1).strip()
    m = re.search(r'Date:\s*(.+?)(?=Message-ID:|$)', text, re.DOTALL | re.IGNORECASE)
    if m: data['date'] = m.group(1).strip()
    m = re.search(r'Message-ID:\s*(.+?)(?=Views:|$)', text, re.DOTALL | re.IGNORECASE)
    if m: data['message_id'] = m.group(1).strip()

    start = text.find("Lists:")
    end = text.find("Branch", start)
    if start != -1 and end != -1 and start < end:
        data['body'] = text[start + len("Lists:"):end].strip()

    for a in soup.find_all('a', href=True):
        if 'commitdiff' in a['href']:
            data['details_url'] = urljoin(msg_url, a['href'])
            break
    if not data['details_url']:
        m = re.search(r'Details\s*[-=]*\s*(https?://[^\s<"]+)', text)
        if m: data['details_url'] = m.group(1)

    return data if data['subject'] and data['details_url'] else None


def fetch_diff(url):
    html = fetch_html(url)
    if not html:
        return "[Error]"
    soup = BeautifulSoup(html, 'html.parser')
    for pre in soup.find_all('pre'):
        txt = pre.get_text()
        if txt.strip().startswith("diff --git"):
            return txt.strip()
    for div in soup.find_all(['div', 'pre']):
        txt = div.get_text().strip()
        if txt:
            return txt
    plain = soup.find('a', href=lambda x: x and 'commitdiff_plain' in x)
    if plain:
        ph = fetch_html(urljoin(url, plain['href']))
        if ph: return ph.strip()
    return soup.get_text().strip()


def save_json(msg, diff, cid):
    name = sanitize_filename(msg['subject'])
    path = os.path.join(OUTPUT_DIR, name)
    if os.path.exists(path):
        return False
    out = {"metadata": {"id": cid, "subject": msg['subject'], "from": msg['from'],
                        "date": msg['date'], "message_id": msg['message_id'],
                        "source_message_url": msg['source_url'],
                        "details_git_url": msg['details_url']},
           "email_body": msg['body'], "commit_diff_content": diff}
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"      [Saved] #{cid} {name}")
    return True


def main():
    nid = get_next_id()
    print(f"Resuming ID: {nid}")
    dt = START_DATE
    processed = skipped = 0
    while dt > END_DATE:
        ts = dt.strftime("%Y%m%d%H%M")
        url = f"{BASE_LIST_URL}{ts}/"
        print(f"\n[{dt.date()}] {ts}...")
        html = fetch_html(url)
        if not html:
            dt -= timedelta(days=STEP_DAYS)
            time.sleep(DELAY_LIST)
            continue
        links = extract_message_links(html, url)
        print(f"  {len(links)} messages.")
        for _, murl in links:
            mhtml = fetch_html(murl)
            if not mhtml: continue
            msg = parse_message(mhtml, murl)
            if not msg: continue
            if os.path.exists(os.path.join(OUTPUT_DIR, sanitize_filename(msg['subject']))):
                skipped += 1; continue
            if msg['details_url']:
                diff = fetch_diff(msg['details_url'])
                time.sleep(DELAY_GIT_DIFF)
            else:
                diff = "[No Link]"
            if save_json(msg, diff, nid):
                processed += 1; nid += 1
            time.sleep(DELAY_MSG_DETAIL)
        dt -= timedelta(days=STEP_DAYS)
        time.sleep(DELAY_LIST)
    print(f"\nDone. Saved: {processed}, Skipped: {skipped}")


if __name__ == "__main__":
    main()
