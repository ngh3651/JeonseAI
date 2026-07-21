"""하이브리드 검색 — BM25(키워드) + 벡터(의미) + 위험 태그 필터 + 보수적 노출 게이트.

법률 텍스트는 순수 임베딩 유사도만으로는 변별이 약할 수 있어(전문용어·한자어 밀도),
세 신호를 결합한다:
1. **위험 태그 필터**: 규칙 엔진 판정에서 파생된 태그(신탁등기 등)와 겹치는 판례만 후보.
   — 관련 없는 판례가 유사 문구만으로 올라오는 오탐을 구조적으로 차단.
2. **BM25**: 법률 고유어(임차권등기명령, 채권최고액 …)의 정확 일치 신호.
3. **벡터 코사인**: 표현이 달라도 의미가 닿는 판례를 잡는 신호.
결합은 RRF(Reciprocal Rank Fusion) — BM25 점수의 스케일 문제 없이 순위만으로 융합.

노출 게이트 (보수적 — 미달이면 결과에서 제외, 폴백 문구로):
- `doc.verified == True` (출처 검증 안 된 판례는 절대 노출 금지)
- 판정 태그와 교집합 ≥ 1 (판정과 무관한 판례 노출 금지)
- 벡터 유사도 ≥ 하한선 (의미적으로 먼 판례 노출 금지)
"""

from __future__ import annotations

import json
import math
import re
from collections import Counter
from pathlib import Path

from .embedding import EmbeddingBackend, get_backend
from .models import PrecedentChunk, PrecedentDoc, RetrievedPrecedent
from .store import DEFAULT_INDEX_DIR, VectorStore, get_store

# ── 검색 파라미터 (인프라 수치 — 판정 아님. 평가셋 루프로 캘리브레이션) ──────
RETRIEVE_K = 12          # 융합 전 후보 폭 (벡터·BM25 각각)
RRF_K = 60               # RRF 상수 (관행값 60 — Cormack et al.)
WEIGHT_VECTOR = 1.0      # RRF 융합 가중 (벡터)
WEIGHT_KEYWORD = 1.0     # RRF 융합 가중 (BM25)
BM25_K1 = 1.5
BM25_B = 0.75

# 노출 게이트 하한선 — 백엔드별 코사인 분포가 달라 서명 접두어로 구분한다.
# (upstage 4096차원 실측: 관련 쌍 0.55~0.75 / 무관 쌍 0.3대 — 평가셋 캘리브레이션 값)
VECTOR_SIM_FLOOR = {
    "upstage": 0.45,
    "local": 0.45,
    "hash": 0.15,  # 해시 백엔드는 어휘 중첩 근사라 분포가 낮다 (개발·테스트 전용)
}


def _tokenize(text: str) -> list[str]:
    """한국어 간이 토크나이저 — 어절 + 문자 바이그램 (형태소 분석기 의존성 없이).

    법률 텍스트의 복합명사(임차권등기명령 등)가 어절 단위로만 매칭되지 않도록
    바이그램을 함께 넣어 부분 일치 신호를 확보한다.
    """
    words = re.findall(r"[가-힣A-Za-z0-9]+", text)
    tokens: list[str] = []
    for w in words:
        tokens.append(w)
        if re.match(r"^[가-힣]+$", w) and len(w) >= 2:
            tokens.extend(w[i : i + 2] for i in range(len(w) - 1))
    return tokens


class _BM25:
    """소규모 코퍼스용 BM25 — 외부 의존성 없이 결정적으로 동작한다."""

    def __init__(self, corpus: list[list[str]]) -> None:
        self._corpus_tf = [Counter(doc) for doc in corpus]
        self._doc_len = [len(doc) for doc in corpus]
        self._avg_len = (sum(self._doc_len) / len(self._doc_len)) if corpus else 0.0
        df: Counter = Counter()
        for tf in self._corpus_tf:
            df.update(tf.keys())
        n = len(corpus)
        self._idf = {
            term: math.log(1 + (n - d + 0.5) / (d + 0.5)) for term, d in df.items()
        }

    def scores(self, query_tokens: list[str]) -> list[float]:
        out = []
        for tf, dl in zip(self._corpus_tf, self._doc_len):
            s = 0.0
            for t in query_tokens:
                if t not in tf:
                    continue
                idf = self._idf.get(t, 0.0)
                freq = tf[t]
                denom = freq + BM25_K1 * (1 - BM25_B + BM25_B * dl / (self._avg_len or 1.0))
                s += idf * freq * (BM25_K1 + 1) / denom
            out.append(s)
        return out


class HybridRetriever:
    """문서·청크 코퍼스 로드 + 벡터 저장소 + BM25를 묶은 검색기.

    코퍼스 파일(ingest.py 산출):
    - index/docs.jsonl   : PrecedentDoc 전체 (case_id → 문서 렌더링용)
    - index/chunks.jsonl : PrecedentChunk 전체 (BM25 코퍼스 = 벡터 인덱스와 동일 청크)
    """

    def __init__(
        self,
        index_dir: Path | None = None,
        *,
        store: VectorStore | None = None,
        backend: EmbeddingBackend | None = None,
    ) -> None:
        self._index_dir = Path(index_dir or DEFAULT_INDEX_DIR)
        self._store = store if store is not None else get_store(self._index_dir)
        self._backend = backend if backend is not None else get_backend()
        self._docs: dict[str, PrecedentDoc] = {}
        self._chunks: list[PrecedentChunk] = []
        self._load_corpus()
        self._bm25 = _BM25([_tokenize(c.text) for c in self._chunks])

    def _load_corpus(self) -> None:
        docs_path = self._index_dir / "docs.jsonl"
        chunks_path = self._index_dir / "chunks.jsonl"
        if docs_path.exists():
            for line in docs_path.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    doc = PrecedentDoc(**json.loads(line))
                    self._docs[doc.case_id] = doc
        if chunks_path.exists():
            for line in chunks_path.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    self._chunks.append(PrecedentChunk(**json.loads(line)))

    @property
    def corpus_size(self) -> int:
        return len(self._chunks)

    def _sim_floor(self) -> float:
        prefix = self._backend.signature.split(":", 1)[0]
        return VECTOR_SIM_FLOOR.get(prefix, max(VECTOR_SIM_FLOOR.values()))

    def search(
        self,
        query_text: str,
        *,
        risk_tags: list[str] | None = None,
        top_k: int = 3,
        apply_gate: bool = True,
    ) -> list[RetrievedPrecedent]:
        """질의 → 문서 단위 상위 top_k. 게이트 통과 결과만 반환한다(빈 목록 허용)."""
        if not self._chunks:
            return []

        # 1) 벡터 후보 (저장소가 태그 필터를 함께 적용)
        qvec = self._backend.embed_query(query_text)
        vec_hits = self._store.search(
            qvec, self._backend.signature, top_k=RETRIEVE_K, risk_tags=risk_tags or None
        )
        vec_rank = {chunk.chunk_id: (r, score) for r, (chunk, score) in enumerate(vec_hits)}

        # 2) BM25 후보 (동일 태그 필터를 파이썬 쪽에서 적용)
        qtok = _tokenize(query_text)
        kw_scores = self._bm25.scores(qtok)
        kw_pairs = [
            (c, s)
            for c, s in zip(self._chunks, kw_scores)
            if s > 0 and (not risk_tags or set(c.risk_tags) & set(risk_tags))
        ]
        kw_pairs.sort(key=lambda t: t[1], reverse=True)
        kw_pairs = kw_pairs[:RETRIEVE_K]
        kw_max = kw_pairs[0][1] if kw_pairs else 1.0
        kw_rank = {c.chunk_id: (r, s) for r, (c, s) in enumerate(kw_pairs)}

        # 3) RRF 융합 (청크 단위)
        chunk_by_id = {c.chunk_id: c for c in self._chunks}
        for chunk, _ in vec_hits:
            chunk_by_id.setdefault(chunk.chunk_id, chunk)
        fused: dict[str, float] = {}
        for cid, (r, _) in vec_rank.items():
            fused[cid] = fused.get(cid, 0.0) + WEIGHT_VECTOR / (RRF_K + r + 1)
        for cid, (r, _) in kw_rank.items():
            fused[cid] = fused.get(cid, 0.0) + WEIGHT_KEYWORD / (RRF_K + r + 1)

        # 4) 문서 단위 집계 — 문서의 최고 청크 점수로 대표
        best_by_case: dict[str, tuple[str, float]] = {}
        for cid, score in fused.items():
            case_id = chunk_by_id[cid].case_id
            if case_id not in best_by_case or score > best_by_case[case_id][1]:
                best_by_case[case_id] = (cid, score)

        ranked = sorted(best_by_case.items(), key=lambda t: t[1][1], reverse=True)

        # 5) 결과 조립 + 보수적 노출 게이트
        floor = self._sim_floor()
        results: list[RetrievedPrecedent] = []
        for case_id, (cid, hybrid) in ranked:
            doc = self._docs.get(case_id)
            if doc is None:
                continue
            chunk = chunk_by_id[cid]
            vec_score = vec_rank.get(cid, (None, 0.0))[1]
            kw_score = (kw_rank.get(cid, (None, 0.0))[1] / kw_max) if kw_max > 0 else 0.0
            matched = sorted(set(doc.risk_tags) & set(risk_tags or []))
            if apply_gate:
                if not doc.verified:
                    continue  # 출처 미검증 판례는 노출 금지
                if risk_tags and not matched:
                    continue  # 판정과 무관한 판례 노출 금지
                if vec_score < floor:
                    continue  # 의미 유사도 하한 미달 — 노출 금지 (지어붙이기 방지)
            results.append(
                RetrievedPrecedent(
                    doc=doc,
                    chunk=chunk,
                    vector_score=round(vec_score, 4),
                    keyword_score=round(kw_score, 4),
                    hybrid_score=round(hybrid, 6),
                    matched_tags=matched,
                )
            )
            if len(results) >= top_k:
                break
        return results
