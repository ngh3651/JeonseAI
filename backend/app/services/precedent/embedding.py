"""임베딩 백엔드 추상화 — Upstage API ↔ 로컬 GPU 오픈모델 ↔ 오프라인 해시.

교체 규칙 (미션 요건: "GPU 실행 지점을 코드에 명시"):
- 개발·시연(현재): `UpstageEmbeddingBackend` — 국내 API, 소량(시드 수십 건) 임베딩.
- **대량 배치(GPU 실행 지점)**: `LocalEmbeddingBackend` — 판례 수만 건을 대회 GPU에서
  1회성으로 임베딩할 때 사용. sentence-transformers 설치 + `PRECEDENT_EMBEDDING_BACKEND=local`
  환경변수만 바꾸면 파이프라인 나머지는 무변경. (상세 계획: docs/precedent-rag.md §GPU)
- 테스트·오프라인: `HashingEmbeddingBackend` — 결정적 문자 n-gram 해시. 네트워크·크레딧
  없이 파이프라인 전체(청킹→적재→검색→게이트)를 검증한다.

주의: 백엔드가 다르면 벡터 공간이 다르다 — 인덱스 메타에 백엔드 서명을 기록하고,
검색 시 질의 임베딩 백엔드와 인덱스 서명이 다르면 명시적 에러를 낸다(store.py).
"""

from __future__ import annotations

import hashlib
import math
import os
from pathlib import Path
from typing import Protocol

import requests
from dotenv import load_dotenv

_BACKEND_ROOT = Path(__file__).resolve().parents[3]

# [Upstage Embeddings — 공식 문서 확인값. 모델·URL 교체는 환경변수로]
UPSTAGE_EMBEDDING_URL = os.environ.get(
    "UPSTAGE_EMBEDDING_URL", "https://api.upstage.ai/v1/embeddings"
)
UPSTAGE_EMBEDDING_QUERY_MODEL = os.environ.get(
    "UPSTAGE_EMBEDDING_QUERY_MODEL", "embedding-query"
)
UPSTAGE_EMBEDDING_PASSAGE_MODEL = os.environ.get(
    "UPSTAGE_EMBEDDING_PASSAGE_MODEL", "embedding-passage"
)
_UPSTAGE_BATCH_SIZE = 32  # 인프라 수치 — 요청당 입력 수 (문서 상한 100 이내 보수 운용)
_REQUEST_TIMEOUT = 60

# 로컬 GPU 백엔드 기본 모델 — 카카오 공식 배포(모델 사용 기준: decisions.md 2026-07-22).
# 초기 후보 KURE-v1은 "개인·학계 외산 베이스 파인튜닝 배제" 기준에 따라 교체.
# 주의: kanana 임베딩은 512토큰 권장 — 대량 배치 전 청킹 길이·평가셋 A/B 확인 (precedent-rag.md §3)
LOCAL_EMBEDDING_MODEL = os.environ.get(
    "PRECEDENT_LOCAL_MODEL", "kakaocorp/kanana-nano-2.1b-embedding"
)


class EmbeddingBackend(Protocol):
    """임베딩 백엔드 인터페이스 — 파이프라인은 이 프로토콜에만 의존한다."""

    @property
    def signature(self) -> str:
        """인덱스와 질의의 벡터 공간 일치를 검증하는 서명 (예: 'upstage:embedding-passage')."""
        ...

    def embed_passages(self, texts: list[str]) -> list[list[float]]: ...

    def embed_query(self, text: str) -> list[float]: ...


def _l2_normalize(vec: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vec))
    return [x / norm for x in vec] if norm > 0 else vec


class UpstageEmbeddingBackend:
    """Upstage 임베딩 API (국내 스택). query/passage 비대칭 모델을 구분 사용한다."""

    def __init__(self, api_key: str | None = None) -> None:
        if api_key is None:
            load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
            api_key = os.environ.get("UPSTAGE_API_KEY", "").strip()
        if not api_key:
            raise RuntimeError("UPSTAGE_API_KEY가 없어 Upstage 임베딩 백엔드를 쓸 수 없어요")
        self._api_key = api_key

    @property
    def signature(self) -> str:
        return f"upstage:{UPSTAGE_EMBEDDING_PASSAGE_MODEL}"

    def _call(self, model: str, texts: list[str]) -> list[list[float]]:
        vectors: list[list[float]] = []
        for i in range(0, len(texts), _UPSTAGE_BATCH_SIZE):
            batch = texts[i : i + _UPSTAGE_BATCH_SIZE]
            resp = requests.post(
                UPSTAGE_EMBEDDING_URL,
                headers={"Authorization": f"Bearer {self._api_key}"},
                json={"model": model, "input": batch},
                timeout=_REQUEST_TIMEOUT,
            )
            resp.raise_for_status()
            data = sorted(resp.json()["data"], key=lambda d: d["index"])
            vectors.extend([d["embedding"] for d in data])
        return [_l2_normalize(v) for v in vectors]

    def embed_passages(self, texts: list[str]) -> list[list[float]]:
        return self._call(UPSTAGE_EMBEDDING_PASSAGE_MODEL, texts)

    def embed_query(self, text: str) -> list[float]:
        return self._call(UPSTAGE_EMBEDDING_QUERY_MODEL, [text])[0]


class LocalEmbeddingBackend:
    """로컬 오픈모델 (sentence-transformers) — **대량 임베딩 배치의 GPU 실행 지점**.

    대회 GPU에서: `pip install sentence-transformers` 후
    `PRECEDENT_EMBEDDING_BACKEND=local python scripts/ingest_precedents.py --reembed`
    한 줄이면 전체 인덱스가 로컬 모델 벡터로 재구축된다.
    """

    def __init__(self, model_name: str = LOCAL_EMBEDDING_MODEL) -> None:
        try:
            from sentence_transformers import SentenceTransformer  # 선택 의존성
        except ImportError as e:
            raise RuntimeError(
                "sentence-transformers가 설치되어 있지 않아요. 이 백엔드는 대량 임베딩용 "
                "GPU 환경에서 쓰는 것이 기본입니다 (docs/precedent-rag.md §GPU 참고)"
            ) from e
        self._model_name = model_name
        self._model = SentenceTransformer(model_name)

    @property
    def signature(self) -> str:
        return f"local:{self._model_name}"

    def embed_passages(self, texts: list[str]) -> list[list[float]]:
        vecs = self._model.encode(texts, normalize_embeddings=True, batch_size=64)
        return [list(map(float, v)) for v in vecs]

    def embed_query(self, text: str) -> list[float]:
        return self.embed_passages([text])[0]


class HashingEmbeddingBackend:
    """결정적 오프라인 임베딩 — 문자 n-gram 해시 벡터 (테스트·개발 전용).

    의미 임베딩이 아니라 어휘 중첩 근사라 품질은 낮지만, 네트워크·크레딧 없이
    파이프라인 전 구간을 결정적으로 검증할 수 있다. 실서비스 노출 경로에는 쓰지 않는다.
    """

    def __init__(self, dim: int = 512, ngram: tuple[int, int] = (2, 3)) -> None:
        self._dim = dim
        self._ngram = ngram

    @property
    def signature(self) -> str:
        return f"hash:dim{self._dim}"

    def _embed_one(self, text: str) -> list[float]:
        vec = [0.0] * self._dim
        cleaned = "".join(text.split())
        for n in range(self._ngram[0], self._ngram[1] + 1):
            for i in range(max(0, len(cleaned) - n + 1)):
                gram = cleaned[i : i + n]
                h = int.from_bytes(hashlib.md5(gram.encode("utf-8")).digest()[:4], "little")
                vec[h % self._dim] += 1.0
        return _l2_normalize(vec)

    def embed_passages(self, texts: list[str]) -> list[list[float]]:
        return [self._embed_one(t) for t in texts]

    def embed_query(self, text: str) -> list[float]:
        return self._embed_one(text)


def get_backend(name: str | None = None) -> EmbeddingBackend:
    """백엔드 선택 — 환경변수 `PRECEDENT_EMBEDDING_BACKEND` (upstage | local | hash).

    미지정 시: UPSTAGE_API_KEY가 있으면 upstage, 없으면 hash(오프라인)로 폴백.
    (conftest.py가 테스트에서 키를 비우므로 테스트는 자동으로 hash를 쓴다 — 크레딧 0.)
    """
    if name is None:
        name = os.environ.get("PRECEDENT_EMBEDDING_BACKEND", "").strip().lower()
    if not name:
        load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
        name = "upstage" if os.environ.get("UPSTAGE_API_KEY", "").strip() else "hash"
    if name == "upstage":
        return UpstageEmbeddingBackend()
    if name == "local":
        return LocalEmbeddingBackend()
    if name == "hash":
        return HashingEmbeddingBackend()
    raise ValueError(f"알 수 없는 임베딩 백엔드: {name} (upstage | local | hash)")
