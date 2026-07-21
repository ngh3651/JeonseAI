"""판결요지 중심 청킹.

법률 텍스트 특성에 맞춘 전략:
- **판결요지·판시사항이 최상급 검색 단위다** — 대법원 판례의 요지는 편집자가 이미
  쟁점 단위로 요약해 둔 텍스트라, 임의 길이 슬라이딩 윈도우보다 의미 단위가 깨끗하다.
- 요지가 여러 쟁점([1], [2] … 번호 매김)으로 나뉘면 쟁점 단위로 분리한다.
- 전문(full_text)은 보조 검색 대상 — 문단 단위로 자르되 과길이만 방지한다.
  (전문 청크는 리콜 보강용이며, 노출 카드는 항상 문서(요지) 기준으로 조립된다.)

청크 크기 상한은 임베딩 모델 입력 한도(Upstage embedding 4000 토큰급)보다 훨씬
보수적으로 잡는다 — 짧고 균질한 청크가 코사인 유사도 변별에 유리하다.
"""

from __future__ import annotations

import re

from .models import PrecedentChunk, PrecedentDoc

# 인프라 수치(검색 품질 튜닝용 — 판정 아님)
MAX_CHUNK_CHARS = 900   # 요지 쟁점 하나가 대부분 200~600자 — 여유 상한
MIN_CHUNK_CHARS = 40    # 이보다 짧은 조각은 앞 청크에 붙인다

# 대법원 요지의 쟁점 번호 매김: "[1] …", "[2] …" / "가. …", "나. …"
_ISSUE_SPLIT_RE = re.compile(r"(?=\[\d{1,2}\]\s)")
_PARA_SPLIT_RE = re.compile(r"\n{2,}|(?<=[.。])\s*\n")


def _split_issues(text: str) -> list[str]:
    """요지를 쟁점 단위로 나눈다. 번호 매김이 없으면 통짜 유지."""
    parts = [p.strip() for p in _ISSUE_SPLIT_RE.split(text) if p.strip()]
    return parts if len(parts) > 1 else [text.strip()]


def _split_long(text: str, limit: int) -> list[str]:
    """상한 초과 텍스트를 문장 경계 우선으로 자른다."""
    if len(text) <= limit:
        return [text]
    sentences = re.split(r"(?<=[.다요])\s+", text)
    out: list[str] = []
    buf = ""
    for s in sentences:
        if buf and len(buf) + len(s) + 1 > limit:
            out.append(buf.strip())
            buf = s
        else:
            buf = f"{buf} {s}".strip()
    if buf.strip():
        out.append(buf.strip())
    return out


def _merge_short(parts: list[str]) -> list[str]:
    """너무 짧은 조각은 앞 조각에 합친다 (임베딩 노이즈 방지)."""
    merged: list[str] = []
    for p in parts:
        if merged and len(p) < MIN_CHUNK_CHARS:
            merged[-1] = f"{merged[-1]} {p}"
        else:
            merged.append(p)
    return merged


def chunk_document(doc: PrecedentDoc, *, include_full_text: bool = True) -> list[PrecedentChunk]:
    """판례 1건 → 검색 청크 목록. 요지(핵심) 먼저, 전문(보조)은 뒤에."""
    chunks: list[PrecedentChunk] = []

    def _add(section: str, text: str) -> None:
        chunks.append(
            PrecedentChunk(
                chunk_id=f"{doc.case_id}#{len(chunks)}",
                case_id=doc.case_id,
                section=section,
                text=text,
                risk_tags=list(doc.risk_tags),
            )
        )

    # 1) 판결요지·판시사항 — 쟁점 단위
    for issue in _split_issues(doc.holding):
        for piece in _merge_short(_split_long(issue, MAX_CHUNK_CHARS)):
            _add("판결요지", piece)

    # 2) 쉬운 요약(큐레이션) — 사용자 어휘로 쓰여 있어 질의 어휘와의 다리 역할
    if doc.summary_easy:
        _add("요약", doc.summary_easy)

    # 3) 전문 — 문단 단위 보조 청크
    if include_full_text and doc.full_text:
        for para in _PARA_SPLIT_RE.split(doc.full_text):
            para = para.strip()
            if len(para) < MIN_CHUNK_CHARS:
                continue
            for piece in _split_long(para, MAX_CHUNK_CHARS):
                _add("전문", piece)

    return chunks
