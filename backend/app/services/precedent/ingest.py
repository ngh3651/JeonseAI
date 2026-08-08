"""수집~적재 파이프라인 — raw(법제처 공식) + 시드 큐레이션 → 청킹 → 임베딩 → 벡터DB.

데이터 소스 2종을 사건번호로 조인한다:
- `data/precedents/raw/prec-*.json` : collect_precedents.py가 저장한 법제처 공식 원문.
- `data/precedents/seed_cases.json` : 팀 큐레이션(쉬운 요약·결과·조언·위험 태그).
  큐레이션이 있으면 그 태그·문구를 쓰고, 없는 raw 문서는 키워드 규칙으로 자동 태깅한다
  (규칙 기반 — LLM 미개입. 태그는 검색 필터일 뿐 판정에 영향 없음).

산출물 (data/precedents/index/):
- docs.jsonl / chunks.jsonl : 검색기(retrieval.py)가 로드하는 코퍼스
- 벡터 인덱스 (chroma/ 또는 vectors.json)
- meta.json : 임베딩 서명·건수·적재 시각 (재현성 추적)
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from .chunking import chunk_document
from .embedding import EmbeddingBackend, get_backend
from .models import PrecedentDoc
from .store import DEFAULT_INDEX_DIR, VectorStore, get_store

_PRECEDENT_DATA_DIR = DEFAULT_INDEX_DIR.parent  # backend/data/precedents

# 자동 태깅 키워드 규칙 (raw 대량 수집분용 — 큐레이션 태그가 항상 우선)
_AUTO_TAG_RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("신탁등기", ("신탁",)),
    ("임차권등기", ("임차권등기",)),
    ("압류·가압류", ("가압류", "압류", "가처분")),
    ("경매", ("경매", "경락", "낙찰", "배당")),
    ("선순위 채권", ("근저당", "저당권", "채권최고액", "우선변제권")),
    # "편취" 단독은 전세 무관 일반 사기 판례까지 태깅해 제외 (rule-auditor 재감사 2026-07-22)
    ("전세가율", ("전세사기", "깡통", "갭투자")),
    ("대항력", ("대항력", "전입신고", "확정일자")),
    ("보증보험", ("보증보험", "주택도시보증공사", "보증금반환보증")),
)


def _norm_case_no(s: str) -> str:
    return "".join((s or "").split())


def _case_no_parts(raw_case_no: str) -> list[str]:
    """'2019다300095, 300101' → ['2019다300095', '300101'] (정확 일치 조인용)."""
    return [_norm_case_no(p) for p in (raw_case_no or "").split(",") if p.strip()]


def auto_tags(text: str) -> list[str]:
    return [tag for tag, keywords in _AUTO_TAG_RULES if any(k in text for k in keywords)]


def load_raw_docs(raw_dir: Path | None = None) -> list[dict]:
    raw_dir = raw_dir or (_PRECEDENT_DATA_DIR / "raw")
    docs = []
    if raw_dir.exists():
        for p in sorted(raw_dir.glob("prec-*.json")):
            docs.append(json.loads(p.read_text(encoding="utf-8")))
    return docs


def load_seed_cases(path: Path | None = None) -> list[dict]:
    path = path or (_PRECEDENT_DATA_DIR / "seed_cases.json")
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    return [c for c in data.get("cases", []) if isinstance(c, dict)]


def _fmt_decided(s: str | None) -> str | None:
    """본문 API의 8자리(20250415) → 2025-04-15. 이미 구분자 있으면 그대로."""
    if not s:
        return None
    s = s.strip()
    if len(s) == 8 and s.isdigit():
        return f"{s[:4]}-{s[4:6]}-{s[6:]}"
    return s


def build_documents(
    raw_docs: list[dict] | None = None, seed_cases: list[dict] | None = None
) -> list[PrecedentDoc]:
    """raw + 큐레이션 조인 → PrecedentDoc 목록. (임베딩 없음 — 순수 변환)"""
    raw_docs = load_raw_docs() if raw_docs is None else raw_docs
    seed_cases = load_seed_cases() if seed_cases is None else seed_cases

    raw_by_part: dict[str, dict] = {}
    for rd in raw_docs:
        for part in _case_no_parts(rd.get("case_no", "")):
            raw_by_part.setdefault(part, rd)

    docs: list[PrecedentDoc] = []
    used_raw_ids: set[str] = set()

    # 1) 큐레이션 항목 (raw 공식 원문이 있으면 요지·전문을 가져와 합친다)
    for seed in seed_cases:
        key = _norm_case_no(seed.get("case_no", ""))
        raw = raw_by_part.get(key)
        holding = ""
        full_text = None
        title = None
        source_url = (seed.get("source_urls") or [None])[0] or seed.get("source_url", "")
        if raw:
            used_raw_ids.add(raw["prec_id"])
            holding = raw.get("holding_summary") or raw.get("holding_points") or ""
            full_text = raw.get("full_text") or None
            title = raw.get("case_name") or None
        if not holding:
            holding = seed.get("holding", "")
        if not holding:
            print(f"  건너뜀(요지 없음): {seed.get('case_no')} — raw 수집 또는 holding 기입 필요")
            continue
        docs.append(
            PrecedentDoc(
                case_id=f"prec-{raw['prec_id']}" if raw else f"seed-{key}",
                case_no=seed.get("case_no", ""),
                court=seed.get("court") or (raw.get("court") if raw else "") or "법원 미상",
                decided=_fmt_decided(seed.get("decided") or (raw.get("decided") if raw else None)),
                title=title,
                risk_tags=list(seed.get("risk_tags", [])),
                holding=holding,
                outcome=seed.get("outcome"),
                summary_easy=seed.get("summary_easy"),
                advice=seed.get("advice"),
                source_url=source_url,
                full_text=full_text,
                # 큐레이션 시드는 출처 링크가 있으면 출처 확인된 것으로 본다.
                #   (seed_cases.json에 source_verified를 따로 적어 두면 그 값이 우선)
                source_verified=bool(
                    seed.get("source_verified", bool(source_url))
                ),
                verified=bool(seed.get("verified", False)),
                curated_by=seed.get("curated_by"),
                collected_at=seed.get("date"),
            )
        )

    # 2) 큐레이션 없는 raw(대량 수집분) — 자동 태깅으로 편입
    for rd in raw_docs:
        if rd["prec_id"] in used_raw_ids:
            continue
        holding = rd.get("holding_summary") or rd.get("holding_points") or ""
        if not holding:
            continue
        tag_basis = " ".join([rd.get("case_name", ""), rd.get("holding_points", ""), holding])
        docs.append(
            PrecedentDoc(
                case_id=f"prec-{rd['prec_id']}",
                case_no=rd.get("case_no", ""),
                court=rd.get("court") or "법원 미상",
                decided=_fmt_decided(rd.get("decided")),
                title=rd.get("case_name"),
                risk_tags=auto_tags(tag_basis),
                holding=holding,
                source_url=rd.get("source_url", ""),
                full_text=rd.get("full_text") or None,
                # 출처는 법제처 공식 원문이고 source_url이 실재한다 → 노출 허용.
                #   (2026-08-07: 원래 AND 조건 하나로 묶여 있어 148건이 통째로 막혔다.
                #    두 축을 분리해, 출처는 자동 확인하고 문구 검수는 따로 표시한다.)
                source_verified=bool(rd.get("source_url")),
                # 문구는 아직 사람이 읽지 않았다 — 카드에 "검수 전" 표시가 붙는다.
                verified=False,
                curated_by=None,
                collected_at=rd.get("_collected_at"),
            )
        )

    return docs


def ingest(
    *,
    index_dir: Path | None = None,
    backend: EmbeddingBackend | None = None,
    store: VectorStore | None = None,
    include_full_text: bool = True,
    verbose: bool = True,
) -> dict:
    """전체 적재 실행 — 문서 조립 → 청킹 → 임베딩 → 벡터DB 재구축 → 코퍼스 파일 기록.

    반환: meta dict (서명·건수). **대량 임베딩의 GPU 실행 지점**은 backend 선택뿐이다
    (embedding.py 참고) — 이 함수 자체는 백엔드가 무엇이든 동일하게 돈다.
    """
    index_dir = Path(index_dir or DEFAULT_INDEX_DIR)
    backend = backend or get_backend()
    store = store if store is not None else get_store(index_dir)

    docs = build_documents()
    chunks = []
    for doc in docs:
        chunks.extend(chunk_document(doc, include_full_text=include_full_text))
    if verbose:
        print(f"문서 {len(docs)}건 → 청크 {len(chunks)}개 · 임베딩 백엔드 {backend.signature}")

    t0 = time.perf_counter()
    vectors = backend.embed_passages([c.text for c in chunks])
    if verbose:
        print(f"임베딩 완료 ({time.perf_counter() - t0:.1f}초)")

    store.rebuild(chunks, vectors, backend.signature)

    index_dir.mkdir(parents=True, exist_ok=True)
    (index_dir / "docs.jsonl").write_text(
        "\n".join(json.dumps(d.model_dump(), ensure_ascii=False) for d in docs) + "\n",
        encoding="utf-8",
    )
    (index_dir / "chunks.jsonl").write_text(
        "\n".join(json.dumps(c.model_dump(), ensure_ascii=False) for c in chunks) + "\n",
        encoding="utf-8",
    )
    meta = {
        "signature": backend.signature,
        "doc_count": len(docs),
        "chunk_count": len(chunks),
        "ingested_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "verified_docs": sum(1 for d in docs if d.verified),
    }
    (index_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    if verbose:
        print(f"적재 완료 → {index_dir} (검증 문서 {meta['verified_docs']}/{meta['doc_count']})")
    return meta
