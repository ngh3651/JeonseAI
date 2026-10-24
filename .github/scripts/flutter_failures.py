"""flutter test 실패를 GitHub annotation으로 — 이름 목록 1개 + 실패마다 1개(최대 9개, 각 30줄).

한 단계에 annotation은 10개까지이고, 한 덩어리에 몰면 앞부분만 남고 잘린다(2026-10-24).
사용: python3 .github/scripts/flutter_failures.py flutter-test.clean.log
"""
import re
import sys

esc = lambda t: t.replace('%', '%25').replace('\r', '').replace('\n', '%0A')  # noqa: E731
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
mark = re.compile(r'\[E\]|❌')
names = sorted({l.strip() for l in lines if mark.search(l)})
print(f'::error title=실패한 테스트 {len(names)}개::' + esc('\n'.join(names[:30])))
blocks, seen = [], set()
for i, l in enumerate(lines):
    if mark.search(l) and l.strip() not in seen:
        seen.add(l.strip())
        keep = [x for x in lines[i:i + 45] if '<asynchronous suspension>' not in x and not re.match(r'^#[0-9]', x)]
        blocks.append('\n'.join(keep[:30]))
for n, b in enumerate(blocks[:9], 1):
    print(f'::error title=실패 내용 {n}::' + esc(b))
