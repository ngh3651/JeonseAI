#!/usr/bin/env python3
"""문서 양산 방지 검사 — 허용 목록 밖의 .md 파일이 저장소에 있으면 실패한다.

왜: 2026-10 이전에 docs/에 문서가 40개 넘게 쌓였고, 서로 다른 말을 하는 문서 때문에
사람도 Claude도 현재 상태를 헷갈렸다. 정답은 코드이고, 현재 상태는 docs/NOW.md 하나에만 적는다.
측정 결과·세션 기록은 새 문서 대신 PR 설명에 쓴다. (CLAUDE.md §0)

실행: python3 scripts/check_docs.py   (CI가 PR마다 실행한다)
"""
import subprocess
import sys

ALLOWED = {
    "README.md",
    "CLAUDE.md",
    "docs/NOW.md",
    "docs/decisions.md",
    "docs/competition-facts.md",
    "docs/api-contract.md",
    "docs/personas.md",
    "backend/data/README.md",
    "backend/data/precedents/README.md",
    "frontend/README.md",
}
# 도구·플랫폼이 쓰는 폴더 (사람이 읽는 프로젝트 문서가 아님)
ALLOWED_PREFIXES = (".claude/", ".github/", "frontend/ios/", "frontend/android/")


def main() -> int:
    out = subprocess.run(
        ["git", "-c", "core.quotepath=off", "ls-files", "-z", "--", "*.md"],
        capture_output=True, check=True,
    ).stdout.decode("utf-8")
    files = [f for f in out.split("\0") if f]
    bad = [f for f in files if f not in ALLOWED and not f.startswith(ALLOWED_PREFIXES)]
    if bad:
        print("허용 목록 밖의 문서가 있습니다. 새 문서를 만들지 말고")
        print("내용을 docs/NOW.md · docs/decisions.md · PR 설명으로 옮기세요:")
        for f in bad:
            print(f"  - {f}")
        print("(꼭 필요한 문서라면 사람이 승인한 뒤 scripts/check_docs.py의 ALLOWED에 추가)")
        return 1
    print(f"문서 검사 통과 ({len(files)}개)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
