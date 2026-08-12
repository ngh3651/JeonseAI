# -*- coding: utf-8 -*-
r"""판례 검수 대조표를 만든다 — 사람이 원문과 대조해 `verified`를 올리기 위한 것.

왜 필요한가:
  `source_verified`(출처 확인)와 `verified`(사람 문구 검수)를 나눈 뒤, 검수 전 판례도
  화면에 나간다. 출처는 법제처 공식 API라 확실하지만 **쉬운 말 요약이 원문과 맞는지는
  사람이 읽어야** 안다. 심사위원이 사건번호를 찍어 원문과 대조했을 때 어긋나면
  "실제 법원 판결"이라는 차별점이 통째로 무너진다.

무엇을 만드나:
  화면에 실제로 뜰 가능성이 높은 판례(위험 태그별 상위 후보)를 모아,
  **우리가 보여줄 요약**과 **판결문 원문 판시사항**을 나란히 놓은 표를 만든다.
  검수자는 둘을 비교해 ○/✗만 표시하면 된다.

검수 결과 반영:
  맞으면 `backend/data/precedents/seed_cases.json`에 해당 판례를 추가하고
  `verified: true`로 둔다 → 재색인하면 노출 순서에서 앞으로 온다.
  틀리면 그 판례를 raw에서 빼거나, 요약이 문제면 `summary_easy`를 직접 써 넣는다.

사용법
  backend/.venv/Scripts/python.exe backend/scripts/make_review_sheet.py
  backend/.venv/Scripts/python.exe backend/scripts/make_review_sheet.py --per-tag 3

  ⚠ 실행하면 Solar를 한 번 호출한다(요약 생성). 크레딧이 든다.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services.precedent import explainer  # noqa: E402
from app.services.precedent.models import RISK_TAGS  # noqa: E402
from app.services.precedent.service import PrecedentService  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / "docs" / "precedent-review-sheet.md"

# 원문은 길다. 검수자가 읽을 만큼만 싣고, 판단이 애매하면 링크로 가게 한다.
_HOLDING_CHARS = 700


def _trim(text: str, limit: int = _HOLDING_CHARS) -> str:
    t = " ".join((text or "").split())
    return t if len(t) <= limit else t[: limit - 1] + "…"


def main() -> None:
    ap = argparse.ArgumentParser(description="판례 검수 대조표 생성")
    ap.add_argument("--per-tag", type=int, default=2, help="위험 태그당 후보 수 (기본 2)")
    args = ap.parse_args()

    svc = PrecedentService()

    # 태그별 상위 후보를 모은다 — 화면에 실제로 뜰 판례가 검수 대상이다.
    picked: dict[str, object] = {}
    tag_of: dict[str, list[str]] = {}
    for tag in RISK_TAGS:
        for m in svc.search_by_tags([tag])[: args.per_tag]:
            picked.setdefault(m.doc.case_id, m)
            tag_of.setdefault(m.doc.case_id, []).append(tag)

    matches = list(picked.values())
    if not matches:
        raise SystemExit("[오류] 검색 결과가 없습니다. 색인을 먼저 만드세요.")

    print(f"검수 후보 {len(matches)}건 — 요약 생성 중 (⚠ Solar 크레딧 소모)")
    explanations, source = explainer.explain_matches(matches, {"위험_태그": list(RISK_TAGS)})
    print(f"요약 생성: {source}")

    todo = [m for m in matches if not m.doc.verified]
    done = [m for m in matches if m.doc.verified]

    lines: list[str] = [
        "# 판례 검수 대조표",
        "",
        "> **하는 일**: 왼쪽(우리가 앱에서 보여줄 요약)이 오른쪽(판결문 원문)과 맞는지 확인합니다.",
        "> 법률 지식이 많이 필요하지 않습니다 — **요약이 원문에 없는 말을 지어냈는지**만 보시면 됩니다.",
        "",
        "확인할 것 세 가지:",
        "1. 요약이 원문에 **없는 사실**을 말하고 있지 않은가 (금액·연도·당사자를 지어내지 않았는가)",
        "2. **결과**가 뒤집히지 않았는가 (임차인이 졌는데 이겼다고 하거나, 그 반대)",
        "3. 이 판례가 그 **위험 태그와 실제로 관련**이 있는가",
        "",
        "판단이 애매하면 사건번호 링크로 원문 전체를 보실 수 있습니다.",
        "",
        f"- 검수 대상: **{len(todo)}건** (이미 검수됨: {len(done)}건)",
        "- 검수 후: 맞으면 `backend/data/precedents/seed_cases.json`에 추가하고 `verified: true`,",
        "  틀리면 이 문서에 무엇이 틀렸는지 적어 주세요.",
        "",
        "---",
        "",
    ]

    for i, m in enumerate(todo, start=1):
        doc = m.doc
        exp = explanations.get(doc.case_id)
        summary = exp.easy_summary if exp else "(요약 생성 실패 — 폴백 문구가 나갑니다)"
        tags = ", ".join(dict.fromkeys(tag_of.get(doc.case_id, [])))

        lines += [
            f"## {i}. {doc.court} {doc.case_no}",
            "",
            f"- **사건명**: {doc.title or '(없음)'}",
            f"- **위험 태그**: {tags}",
            f"- **선고일**: {doc.decided or '(없음)'}",
            f"- **원문**: {doc.source_url}",
            "",
            "**우리가 보여줄 요약**",
            "",
            f"> {summary}",
            "",
            f"**결과 표시**: {doc.outcome or '(LLM 분류로 채워짐 — 원문과 맞는지 함께 봐 주세요)'}",
            "",
            "**판결문 원문 (판시사항·판결요지)**",
            "",
            f"```\n{_trim(doc.holding)}\n```",
            "",
            "**검수 결과**: ☐ 맞음   ☐ 틀림 → 무엇이 틀렸나: ",
            "",
            "---",
            "",
        ]

    if done:
        lines += [
            "## 이미 검수된 판례 (참고)",
            "",
            *[f"- {m.doc.court} {m.doc.case_no} — {m.doc.title or ''}" for m in done],
            "",
        ]

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n생성 완료 → {OUT}")
    print(f"  검수 대상 {len(todo)}건 / 이미 검수됨 {len(done)}건")


if __name__ == "__main__":
    main()
