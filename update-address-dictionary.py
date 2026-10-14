#!/usr/bin/env python3
"""Build a local spelling reference from Japan Post's public UTF-8 address data."""
import csv, io, json, zipfile, urllib.request, hashlib, datetime
from pathlib import Path
url = 'https://www.post.japanpost.jp/service/search/zipcode/download/utf/zip/utf_ken_all.zip'
raw = urllib.request.urlopen(url, timeout=60).read()
with zipfile.ZipFile(io.BytesIO(raw)) as z:
    rows = csv.reader(io.StringIO(z.read(z.namelist()[0]).decode('utf-8-sig')))
    entries = sorted({(r[6], r[7], r[4], r[8], r[5]) for r in rows if len(r) >= 9 and not any(x in r[8] for x in ['以下に掲載', '（', 'その他'])})
out = Path(__file__).parent / 'Resources' / 'addresses.json'
out.write_text(json.dumps(entries, ensure_ascii=False, separators=(',', ':')))
out.with_suffix('.source.json').write_text(json.dumps({'source': url, 'retrieved': datetime.date.today().isoformat(), 'sha256': hashlib.sha256(raw).hexdigest(), 'entries': len(entries), 'description': '日本郵便の郵便番号データを町域の表記・読みの照合用に加工。番地・人物との対応は検証しない。', 'terms': 'https://www.post.japanpost.jp/service/search/zipcode/download/utf-readme.html'}, ensure_ascii=False, indent=2))
print(len(entries), out.stat().st_size)
