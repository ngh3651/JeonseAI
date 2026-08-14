"""용어 은행 — `data/terms.json` 하나가 두 표면의 원천 (2026-08-05 신설).

왜 만들었나:
용어 설명이 두 곳에 **따로** 하드코딩돼 있었다 —
  · 리포트 근거 카드 툴팁: `fallback_texts.TERM_GLOSSARY` (근거 id별 고정 dict, 8개)
  · 용어 챗봇: `dummy_data._GLOSSARY` (6개)
같은 용어를 두 곳에서 다르게 설명할 수 있는 구조였고, 실제로 '신탁등기' 설명이 서로
달랐다. 게다가 근거 id에 미리 매어 둔 방식이라 **LLM이 쓴 단어에 툴팁이 붙지 않았다** —
'대항력'을 설명에 써도 사전에 없으면 그냥 검은 글씨였다.

그래서:
  ⑴ 데이터를 파일 하나로 모으고(비개발 팀원이 직접 채울 수 있게),
  ⑵ 근거 id 고정 매핑 대신 **문장을 훑어 등장한 용어만** 붙인다(`attach`).

⚠ 계약 무변경: 결과는 지금과 같은 `termGlossary: dict[str, str]`이다(계약 §2.2).
  앱은 "용어가 easyExplanation 본문에 등장해야 함"을 전제하는데, 이 방식이 그 전제를
  **오히려 더 잘 지킨다** — 등장하지 않은 용어는 애초에 담기지 않는다.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path

_log = logging.getLogger("jeonseai")

TERMS_PATH = Path(__file__).resolve().parents[2] / "data" / "terms.json"


@dataclass(frozen=True)
class Term:
    term: str
    description: str
    aliases: tuple[str, ...] = field(default_factory=tuple)
    chatbot_chip: bool = False
    verified: bool = False  # 근거를 댈 수 있는가 — false면 응답에서 제외한다
    source: str = ""  # 근거 또는 '무엇을 확인해야 하는가'

    @property
    def surfaces(self) -> tuple[str, ...]:
        """문장에서 이 용어로 볼 표기들 — 정식 명칭 + 별칭."""
        return (self.term, *self.aliases)


_cache: list[Term] | None = None  # 파일 전체(검수 대기 포함)


def _load_raw() -> list[Term]:
    """파일에 적힌 **전부**(검수 대기 포함). 파일이 깨져도 빈 목록으로 끝난다.

    응답에 나가는 경로는 이 함수를 직접 쓰지 않는다 — `load()`가 검수 게이트다.
    """
    global _cache
    if _cache is not None:
        return _cache
    try:
        raw = json.loads(TERMS_PATH.read_text(encoding="utf-8"))
        items = raw.get("terms") or []
        out: list[Term] = []
        for x in items:
            term = str(x.get("term") or "").strip()
            desc = str(x.get("description") or "").strip()
            if not term or not desc:
                continue
            out.append(
                Term(
                    term=term,
                    description=desc,
                    aliases=tuple(str(a).strip() for a in (x.get("aliases") or []) if str(a).strip()),
                    chatbot_chip=bool(x.get("chatbot_chip")),
                    verified=bool(x.get("verified")),
                    source=str(x.get("source") or "").strip(),
                )
            )
        _cache = out
    except Exception as e:  # noqa: BLE001 — 용어 파일이 리포트를 죽이지 못한다
        _log.error(f"[용어] terms.json 을 읽지 못했어요 — 툴팁 없이 진행 ({type(e).__name__}: {e})")
        _cache = []
    return _cache


def load() -> list[Term]:
    """**검수된 용어만** — 응답에 나가는 것은 전부 이 함수를 지난다.

    ⚠ 2026-08-05: `verified=false`인 항목은 여기서 **걸러진다.** 사용자는 툴팁 문장을
      사실로 읽는데, 35개 설명문이 팀 검수를 받지 않았다. 근거를 댈 수 없는 설명은
      **안 보여주는 편이 낫다** — 밑줄이 안 붙을 뿐 아무것도 깨지지 않는다.
      검수 대기 목록: `docs/terms-review-queue.md`
    """
    return [t for t in _load_raw() if t.verified]


def load_all() -> list[Term]:
    """검수 대기분까지 **전부** — 검수 큐 문서 생성 등 도구용."""
    return _load_raw()


def reload() -> list[Term]:
    """캐시 비우고 다시 읽기 (테스트·편집 후 확인용)."""
    global _cache
    _cache = None
    return load()


def chatbot_terms() -> list[Term]:
    """용어 챗봇 추천 칩에 띄울 것만."""
    return [t for t in load() if t.chatbot_chip]


def lookup(query: str) -> Term | None:
    """사용자 입력에서 용어 찾기 — 별칭 포함, **가장 긴 표기 우선**.

    가장 긴 것을 먼저 보는 이유: '근저당권'을 물었는데 '근저당'이 먼저 걸리면
    덜 정확한 설명이 나간다.
    """
    q = (query or "").strip()
    if not q:
        return None
    best: tuple[int, Term] | None = None
    for t in load():
        for surface in t.surfaces:
            if surface and surface in q and (best is None or len(surface) > best[0]):
                best = (len(surface), t)
    return best[1] if best else None


def _spaced_pattern(surface: str) -> re.Pattern[str]:
    """`우선변제권` → `우선[ \\t]*변제[ \\t]*권` 처럼 **글자 사이 공백을 허용**하는 패턴.

    왜 필요한가 (2026-08-14 실측): LLM이 쓴 문장은 `"우선 변제권"`, `"근저당 권"`처럼
    용어를 띄어 쓴다. 정확 일치만 보던 예전 방식은 그때 툴팁을 **조용히 빠뜨렸다** —
    화면에는 어려운 말이 그대로 남고 밑줄만 없다(사용자는 뜻을 알 길이 없다).

    ⚠ 줄바꿈은 허용하지 않는다(`[ \\t]`). 문단이 갈린 곳에서 용어가 이어졌다고 보면
      엉뚱한 자리에 밑줄이 붙는다.
    """
    return re.compile(r"[ \t]*".join(re.escape(ch) for ch in surface))


def attach(text: str) -> dict[str, str]:
    """문장에 **실제로 등장한** 용어만 골라 `termGlossary` 형태로 (2026-08-05).

    같은 용어가 별칭으로 등장하면 **문장에 쓰인 그 표기**를 키로 쓴다 — 앱이
    `easyExplanation.indexOf(키)`로 위치를 찾기 때문이다(report_screen.dart:506).
    키가 본문에 없으면 툴팁이 붙지 않는다. 그래서 띄어 쓴 표기를 찾았을 때도
    **본문에 나타난 그 형태 그대로**(`"우선 변제권"`)를 키로 쓴다.

    긴 표기를 먼저 잡아 짧은 표기에 가려지지 않게 한다('근저당권' vs '근저당').
    """
    if not text:
        return {}
    pairs: list[tuple[str, str]] = []
    for t in load():
        for surface in t.surfaces:
            if not surface:
                continue
            m = _spaced_pattern(surface).search(text)
            if m:
                pairs.append((m.group(0), t.description))
    if not pairs:
        return {}
    # 긴 표기 우선. 짧은 표기가 긴 표기의 부분 문자열이면 짧은 쪽은 버린다 —
    # 둘 다 담으면 앱이 '근저당'을 먼저 찾아 '근저당권'을 반으로 자른다.
    pairs.sort(key=lambda p: -len(p[0]))
    chosen: dict[str, str] = {}
    for surface, desc in pairs:
        if any(surface != k and surface in k for k in chosen):
            continue
        chosen.setdefault(surface, desc)
    return chosen
