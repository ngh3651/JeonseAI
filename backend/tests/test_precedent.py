"""판례 RAG 모듈 테스트 — 파이프라인 정합성 + 가드레일 봉인.

핵심 봉인 대상:
- 판례는 설명 전용: rule_engine·report_builder는 precedent 모듈을 import하지 않는다.
- 보수적 노출 게이트: 미검증·태그 불일치·유사도 미달 → 노출 차단.
- 환각 차단: LLM이 검색 결과에 없는 case_id를 말하면 폐기, 금지어면 폴백.
- 문서 불완전 floor로 생긴 '확인 필요'에는 판례를 붙이지 않는다(과잉 매칭 방지).

전 테스트가 오프라인(해시 백엔드 + JSON 저장소 + tmp_path)으로 돈다 — 크레딧 0.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.schemas.internal import EvidenceVerdict, Grade, RuleVerdict
from app.services.precedent import explainer
from app.services.precedent.chunking import chunk_document
from app.services.precedent.embedding import HashingEmbeddingBackend, get_backend
from app.services.precedent.ingest import auto_tags, build_documents
from app.services.precedent.models import PrecedentDoc
from app.services.precedent.retrieval import HybridRetriever
from app.services.precedent.service import PrecedentService, tags_from_verdict
from app.services.precedent.store import JsonVectorStore


# ── 테스트 코퍼스 헬퍼 ──────────────────────────────────────────────────────

def make_doc(
    case_id: str,
    tags: list[str],
    holding: str,
    *,
    verified: bool = True,
    source_verified: bool | None = None,
) -> PrecedentDoc:
    """테스트 판례 1건.

    `source_verified`(출처 확인)가 노출 게이트다. `verified`(사람 문구 검수)는
    게이트가 아니라 화면 표시용이다 — 2026-08-07 검증 2단계 분리.
    지정하지 않으면 출처는 확인된 것으로 둔다(대부분의 테스트가 노출을 전제로 한다).
    """
    return PrecedentDoc(
        case_id=case_id,
        case_no=case_id.replace("prec-", ""),
        court="대법원",
        risk_tags=tags,
        holding=holding,
        summary_easy=f"{tags[0]} 관련 쉬운 요약이에요",
        outcome="임차인이 보증금을 돌려받지 못했어요",
        source_url="https://example.org/case",
        source_verified=(verified if source_verified is None else source_verified),
        verified=verified,
    )


TRUST_HOLDING = (
    "신탁계약의 내용이 신탁원부에 기재된 경우 수탁자 동의 없이 위탁자와 임대차계약을 "
    "체결한 임차인은 신탁회사에 보증금 반환을 청구할 수 없다"
)
MORTGAGE_HOLDING = (
    "선순위 저당권이 경매로 소멸하면 후순위 임차권도 함께 소멸하므로 임차인은 "
    "경락인에게 임차권의 효력을 주장할 수 없다"
)


@pytest.fixture()
def corpus_dir(tmp_path: Path) -> Path:
    """tmp 인덱스 — 해시 백엔드 + JSON 저장소로 소형 코퍼스를 적재한다."""
    docs = [
        make_doc("prec-trust", ["신탁등기"], TRUST_HOLDING),
        make_doc("prec-mortgage", ["선순위 채권", "경매"], MORTGAGE_HOLDING),
        make_doc("prec-unverified", ["신탁등기"], TRUST_HOLDING + " (미검증 사본)", verified=False),
    ]
    backend = HashingEmbeddingBackend()
    chunks = []
    for d in docs:
        chunks.extend(chunk_document(d))
    store = JsonVectorStore(tmp_path)
    store.rebuild(chunks, backend.embed_passages([c.text for c in chunks]), backend.signature)
    (tmp_path / "docs.jsonl").write_text(
        "\n".join(json.dumps(d.model_dump(), ensure_ascii=False) for d in docs), encoding="utf-8"
    )
    (tmp_path / "chunks.jsonl").write_text(
        "\n".join(json.dumps(c.model_dump(), ensure_ascii=False) for c in chunks), encoding="utf-8"
    )
    return tmp_path


@pytest.fixture()
def retriever(corpus_dir: Path) -> HybridRetriever:
    return HybridRetriever(
        corpus_dir, store=JsonVectorStore(corpus_dir), backend=HashingEmbeddingBackend()
    )


def make_verdict(evidences: list[EvidenceVerdict], grade: Grade = Grade.DANGER) -> RuleVerdict:
    return RuleVerdict(
        grade=grade,
        gauge_progress=0.2,
        deposit=120_000_000,
        market_price=200_000_000,
        senior_debt_amount=0,
        evidences=evidences,
    )


# ── 가드레일: 판정 경로와의 격리 ────────────────────────────────────────────

def test_rule_engine_does_not_import_precedent():
    """판례 모듈이 판정에 영향을 줄 코드 경로가 없다 — import 자체가 없어야 한다."""
    services = Path(__file__).resolve().parents[1] / "app" / "services"
    for name in ("rule_engine.py", "report_builder.py", "thresholds.py"):
        source = (services / name).read_text(encoding="utf-8")
        assert "precedent" not in source, f"{name}이 판례 모듈을 참조하면 안 된다"


def test_precedent_explanation_model_has_no_verdict_fields():
    """LLM 출력 모델에 판정·사건번호·조언 필드가 존재하지 않는다 (extra=forbid)."""
    from app.services.precedent.models import PrecedentExplanation

    with pytest.raises(Exception):
        PrecedentExplanation(
            case_id="x", easy_summary="요약이에요", common_point="공통점이에요", grade="위험"
        )
    with pytest.raises(Exception):
        PrecedentExplanation(
            case_id="x", easy_summary="요약이에요", common_point="공통점이에요", advice="조언"
        )


# ── 청킹 ───────────────────────────────────────────────────────────────────

def test_chunking_splits_numbered_issues():
    doc = make_doc(
        "prec-multi",
        ["신탁등기"],
        "[1] 첫 번째 쟁점의 요지는 신탁원부 기재의 대항력 문제다. "
        "[2] 두 번째 쟁점의 요지는 수탁자 동의 없는 임대차의 효력 문제다.",
    )
    chunks = chunk_document(doc)
    holding_chunks = [c for c in chunks if c.section == "판결요지"]
    assert len(holding_chunks) == 2
    assert holding_chunks[0].text.startswith("[1]")
    assert all(c.risk_tags == ["신탁등기"] for c in chunks)


def test_chunking_includes_easy_summary_and_full_text():
    doc = make_doc("prec-full", ["경매"], MORTGAGE_HOLDING)
    doc = doc.model_copy(update={"full_text": "첫 문단의 내용이 길게 이어진다 " * 5 + "\n\n" + "둘째 문단 " * 10})
    sections = {c.section for c in chunk_document(doc)}
    assert sections == {"판결요지", "요약", "전문"}
    assert "전문" not in {c.section for c in chunk_document(doc, include_full_text=False)}


# ── 임베딩 백엔드 ──────────────────────────────────────────────────────────

def test_hash_backend_is_deterministic_and_normalized():
    b = HashingEmbeddingBackend()
    v1 = b.embed_query("신탁등기 보증금")
    v2 = b.embed_query("신탁등기 보증금")
    assert v1 == v2
    assert abs(sum(x * x for x in v1) - 1.0) < 1e-9


def test_get_backend_falls_back_to_hash_without_key(monkeypatch):
    monkeypatch.setenv("UPSTAGE_API_KEY", "")
    monkeypatch.delenv("PRECEDENT_EMBEDDING_BACKEND", raising=False)
    assert get_backend().signature.startswith("hash:")


# ── 벡터 저장소 ────────────────────────────────────────────────────────────

def test_store_signature_mismatch_raises(corpus_dir: Path):
    store = JsonVectorStore(corpus_dir)
    qvec = HashingEmbeddingBackend().embed_query("아무 질의")
    with pytest.raises(RuntimeError, match="서명"):
        store.search(qvec, "upstage:embedding-passage", top_k=3)


def test_store_tag_filter(corpus_dir: Path):
    store = JsonVectorStore(corpus_dir)
    backend = HashingEmbeddingBackend()
    hits = store.search(
        backend.embed_query("신탁 임대차"), backend.signature, top_k=10, risk_tags=["경매"]
    )
    assert hits and all("경매" in c.risk_tags for c, _ in hits)


# ── 검색 + 보수적 게이트 ────────────────────────────────────────────────────

def test_retrieval_finds_matching_precedent(retriever: HybridRetriever):
    hits = retriever.search("신탁등기 수탁자 동의 없는 임대차 보증금", risk_tags=["신탁등기"], top_k=3)
    assert hits and hits[0].doc.case_id == "prec-trust"


def test_gate_blocks_unverified_docs(retriever: HybridRetriever):
    hits = retriever.search(TRUST_HOLDING, risk_tags=["신탁등기"], top_k=10)
    assert all(h.doc.verified for h in hits)
    ungated = retriever.search(TRUST_HOLDING, risk_tags=["신탁등기"], top_k=10, apply_gate=False)
    assert any(not h.doc.verified for h in ungated)  # 게이트가 실제로 거른 것인지 확인


def test_gate_blocks_tag_mismatch(retriever: HybridRetriever):
    hits = retriever.search("신탁등기 수탁자 동의", risk_tags=["임차권등기"], top_k=5)
    assert hits == []  # 코퍼스에 임차권등기 판례 없음 → 유사 문구만으로 노출되면 안 된다


def test_gate_blocks_low_similarity(corpus_dir: Path, monkeypatch):
    import app.services.precedent.retrieval as retrieval_mod

    r = HybridRetriever(
        corpus_dir, store=JsonVectorStore(corpus_dir), backend=HashingEmbeddingBackend()
    )
    monkeypatch.setitem(retrieval_mod.VECTOR_SIM_FLOOR, "hash", 0.99)  # 하한선을 극단으로
    assert r.search("신탁등기 수탁자", risk_tags=["신탁등기"], top_k=3) == []


# ── 판정 → 태그 파생 (과잉 매칭 방지) ──────────────────────────────────────

def test_tags_from_verdict_maps_signals():
    verdict = make_verdict(
        [
            EvidenceVerdict(
                id="jeonse_ratio", grade=Grade.DANGER, facts={"jeonse_ratio_pct": 95}
            ),
            EvidenceVerdict(
                id="senior_debt",
                grade=Grade.DANGER,
                facts={"mortgage_count": 2, "jeonse_right_count": 0, "unknown_amount_count": 0,
                       "lease_registration_count": 1},
            ),
            EvidenceVerdict(
                id="ownership",
                grade=Grade.DANGER,
                facts={"signals": {"신탁등기": 1, "압류": 0, "가압류": 2, "가처분": 0, "경매개시결정": 1}},
            ),
        ]
    )
    tags = tags_from_verdict(verdict)
    assert tags == ["전세가율", "선순위 채권", "임차권등기", "신탁등기", "압류·가압류", "경매"]


def test_tags_skip_doc_incomplete_floor_cautions():
    """문서 불완전 floor로 '확인 필요'가 된 카드(비율 정상·채권 0건)에는 태그를 달지 않는다."""
    verdict = make_verdict(
        [
            EvidenceVerdict(id="jeonse_ratio", grade=Grade.CAUTION, facts={"jeonse_ratio_pct": 60}),
            EvidenceVerdict(
                id="senior_debt",
                grade=Grade.CAUTION,
                facts={"mortgage_count": 0, "jeonse_right_count": 0, "unknown_amount_count": 0,
                       "lease_registration_count": 0},
            ),
            EvidenceVerdict(id="insurance", grade=Grade.CAUTION, facts={}),
        ],
        grade=Grade.CAUTION,
    )
    assert tags_from_verdict(verdict) == []


def test_tags_include_jeonse_only_above_caution_threshold():
    verdict = make_verdict(
        [EvidenceVerdict(id="jeonse_ratio", grade=Grade.CAUTION, facts={"jeonse_ratio_pct": 85})],
        grade=Grade.CAUTION,
    )
    assert tags_from_verdict(verdict) == ["전세가율"]


# ── 서비스 조립 + 환각 차단 ─────────────────────────────────────────────────

def _danger_trust_verdict() -> RuleVerdict:
    return make_verdict(
        [
            EvidenceVerdict(
                id="ownership",
                grade=Grade.DANGER,
                detail_text="신탁등기 1건 (유효 기준, 말소 제외)",
                facts={"signals": {"신탁등기": 1, "압류": 0, "가압류": 0, "가처분": 0, "경매개시결정": 0}},
            )
        ]
    )


def test_service_returns_honest_fallback_when_no_risk(retriever: HybridRetriever):
    svc = PrecedentService(retriever=retriever)
    section = svc.match_for_verdict(make_verdict([], grade=Grade.GOOD))
    assert section.cases == []
    assert "위험 신호가 발견되지 않았어요" in (section.fallback_text or "")


def test_explanation_source_labels_are_honest(retriever: HybridRetriever, monkeypatch):
    """폴백이면 '자동 생성', LLM 성공이면 'AI 생성' — 라벨 정직성(decisions.md 2026-07-09)."""
    svc = PrecedentService(retriever=retriever)
    # 키 없음 → 폴백 경로
    section = svc.match_for_verdict(_danger_trust_verdict(), explain=True)
    assert section.explanation_source == "자동 생성"
    # LLM 성공 경로
    ok = json.dumps(
        {"cases": [{"case_id": "prec-trust", "easy_summary": "법원이 이렇게 판단했어요",
                    "common_point": "신탁등기 신호가 같아요"}]},
        ensure_ascii=False,
    )
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")
    monkeypatch.setattr(explainer, "_call_solar", lambda messages, api_key: ok)
    section = svc.match_for_verdict(_danger_trust_verdict(), explain=True)
    assert section.explanation_source.startswith("AI 생성")


def test_service_builds_cases_with_citation_fields(retriever: HybridRetriever):
    svc = PrecedentService(retriever=retriever)
    section = svc.match_for_verdict(_danger_trust_verdict())
    assert section.cases, "신탁 위험이면 신탁 판례가 나와야 한다"
    for case in section.cases:
        assert case["caseNo"]  # 사건번호 필수
        assert case["sourceUrl"]  # 출처 필수
        assert case["summary"].strip()


def test_explainer_discards_fabricated_case_ids(retriever: HybridRetriever, monkeypatch):
    """LLM이 검색 결과에 없는 판례를 인용하면 그 항목은 폐기 → 폴백 문구가 나간다."""
    fabricated = json.dumps(
        {"cases": [{"case_id": "prec-없는판례", "easy_summary": "지어낸 설명이에요",
                    "common_point": "지어낸 공통점이에요"}]},
        ensure_ascii=False,
    )
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")
    monkeypatch.setattr(explainer, "_call_solar", lambda messages, api_key: fabricated)
    svc = PrecedentService(retriever=retriever)
    section = svc.match_for_verdict(_danger_trust_verdict(), explain=True)
    assert section.cases
    for case in section.cases:
        assert "지어낸" not in case["summary"]  # 폴백(큐레이션 요약)이 쓰였다
        assert case["summary"] == "신탁등기 관련 쉬운 요약이에요"


def test_explainer_banned_phrase_falls_back(retriever: HybridRetriever, monkeypatch):
    banned = json.dumps(
        {"cases": [{"case_id": "prec-trust", "easy_summary": "이 집은 문제가 없습니다",
                    "common_point": "걱정 마세요"}]},
        ensure_ascii=False,
    )
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")
    monkeypatch.setattr(explainer, "_call_solar", lambda messages, api_key: banned)
    svc = PrecedentService(retriever=retriever)
    section = svc.match_for_verdict(_danger_trust_verdict(), explain=True)
    assert all("문제가 없습니다" not in c["summary"] for c in section.cases)


def test_explainer_no_key_uses_fallback(retriever: HybridRetriever):
    # conftest가 UPSTAGE_API_KEY=""로 고정 → 호출 없이 폴백 (크레딧 0 보장)
    svc = PrecedentService(retriever=retriever)
    section = svc.match_for_verdict(_danger_trust_verdict(), explain=True)
    assert section.cases and section.cases[0]["summary"] == "신탁등기 관련 쉬운 요약이에요"


def test_advice_passes_through_untouched(retriever: HybridRetriever, monkeypatch):
    """advice(큐레이션 조언)는 LLM 성공 여부와 무관하게 문서 값 그대로다."""
    ok = json.dumps(
        {"cases": [{"case_id": "prec-trust", "easy_summary": "법원이 이렇게 판단했어요",
                    "common_point": "신탁등기 신호가 같아요"}]},
        ensure_ascii=False,
    )
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")
    monkeypatch.setattr(explainer, "_call_solar", lambda messages, api_key: ok)
    svc = PrecedentService(retriever=retriever)
    section = svc.match_for_verdict(_danger_trust_verdict(), explain=True)
    assert section.cases[0]["advice"] is None  # make_doc은 advice를 만들지 않는다 — LLM이 채우면 실패


# ── 적재 파이프라인 ────────────────────────────────────────────────────────

def test_auto_tags_keyword_rules():
    assert "신탁등기" in auto_tags("부동산담보신탁계약과 신탁원부")
    assert "임차권등기" in auto_tags("임차권등기명령에 따른 등기")
    assert "압류·가압류" in auto_tags("가압류등기 후의 임대차")
    assert auto_tags("전혀 무관한 행정 사건") == []


def test_build_documents_joins_seed_and_raw():
    raw = [{
        "prec_id": "999999",
        "case_no": "2019다300095, 300101",
        "case_name": "건물인도등청구",
        "court": "대법원",
        "decided": "20220217",
        "holding_summary": "",
        "holding_points": TRUST_HOLDING,
        "full_text": "전문 텍스트 " * 20,
        "source_url": "https://law.example/999999",
    }]
    seeds = [{
        "case_no": "2019다300095",
        "court": "대법원",
        "risk_tags": ["신탁등기"],
        "summary_easy": "쉬운 요약이에요",
        "advice": "신탁원부를 확인하세요",
        "source_urls": ["https://casenote.example/2019다300095"],
        "verified": True,
    }]
    docs = build_documents(raw_docs=raw, seed_cases=seeds)
    assert len(docs) == 1
    doc = docs[0]
    assert doc.case_id == "prec-999999"  # raw와 조인됨
    assert doc.holding == TRUST_HOLDING  # 요지 없으면 판시사항으로
    assert doc.decided == "2022-02-17"
    assert doc.advice == "신탁원부를 확인하세요"
    assert doc.verified


def test_build_documents_auto_tags_raw_without_seed():
    raw = [{
        "prec_id": "888888",
        "case_no": "99다59306",
        "case_name": "구상금",
        "court": "대법원",
        "decided": "20000211",
        "holding_summary": MORTGAGE_HOLDING,
        "holding_points": "",
        "full_text": "",
        "source_url": "https://law.example/888888",
    }]
    docs = build_documents(raw_docs=raw, seed_cases=[])
    assert len(docs) == 1
    assert "경매" in docs[0].risk_tags  # 키워드 자동 태깅
    # 출처는 공식이라도 사람 검수 전에는 노출 금지 — verified는 큐레이션 검수로만 승격
    assert docs[0].verified is False
