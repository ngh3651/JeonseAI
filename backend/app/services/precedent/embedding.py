"""임베딩 백엔드 추상화 — Upstage API ↔ 오프라인 해시.

- 서비스: `UpstageEmbeddingBackend` — 국내 AI 연계 기업(Upstage) API. **AI는 Upstage만**(2026-10-22 결정).
  ⚠ 2026-10-23: 로컬 GPU 오픈모델 선택지(`LocalEmbeddingBackend`, 카카오 kanana)는 지웠다 — 대회 「국내 AI API
  호출 로그 제출 가이드」는 프로젝트의 AI 모델이 **100% 국내 AI 연계 기업**(업스테이지·KT·SKT·LG AI 연구원·NC AI)의
  모델이어야 한다고 못 박는다. 실제 서비스는 처음부터 Upstage만 썼다(기본값). 옛 코드는 git 기록에 있다.
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
# ⚠ 2026-10-21: 예전에는 import 순간 `os.environ`을 읽어, `backend/.env`가 읽히기 **전**의 값
#   (= 기본값)으로 굳었다. 이제 **부를 때** 읽는다(`.env`를 먼저 읽고, 플랫폼 값이 이긴다).
DEFAULT_UPSTAGE_EMBEDDING_URL = "https://api.upstage.ai/v1/embeddings"
DEFAULT_UPSTAGE_EMBEDDING_QUERY_MODEL = "embedding-query"
DEFAULT_UPSTAGE_EMBEDDING_PASSAGE_MODEL = "embedding-passage"


def _env(name: str, default: str) -> str:
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    return os.environ.get(name, "").strip() or default


def upstage_embedding_url() -> str:
    return _env("UPSTAGE_EMBEDDING_URL", DEFAULT_UPSTAGE_EMBEDDING_URL)


def upstage_query_model() -> str:
    return _env("UPSTAGE_EMBEDDING_QUERY_MODEL", DEFAULT_UPSTAGE_EMBEDDING_QUERY_MODEL)


def upstage_passage_model() -> str:
    return _env("UPSTAGE_EMBEDDING_PASSAGE_MODEL", DEFAULT_UPSTAGE_EMBEDDING_PASSAGE_MODEL)
_UPSTAGE_BATCH_SIZE = 32  # 인프라 수치 — 요청당 입력 수 (문서 상한 100 이내 보수 운용)
_REQUEST_TIMEOUT = 60



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
        return f"upstage:{upstage_passage_model()}"

    def _call(self, model: str, texts: list[str]) -> list[list[float]]:
        vectors: list[list[float]] = []
        for i in range(0, len(texts), _UPSTAGE_BATCH_SIZE):
            batch = texts[i : i + _UPSTAGE_BATCH_SIZE]
            resp = requests.post(
                upstage_embedding_url(),
                headers={"Authorization": f"Bearer {self._api_key}"},
                json={"model": model, "input": batch},
                timeout=_REQUEST_TIMEOUT,
            )
            resp.raise_for_status()
            data = sorted(resp.json()["data"], key=lambda d: d["index"])
            vectors.extend([d["embedding"] for d in data])
        return [_l2_normalize(v) for v in vectors]

    def embed_passages(self, texts: list[str]) -> list[list[float]]:
        return self._call(upstage_passage_model(), texts)

    def embed_query(self, text: str) -> list[float]:
        return self._call(upstage_query_model(), [text])[0]


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
    """백엔드 선택 — 환경변수 `PRECEDENT_EMBEDDING_BACKEND` (upstage | hash).

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
        raise ValueError(
            "로컬 임베딩(local)은 지웠어요 — AI는 국내 AI 연계 기업(Upstage)만 씁니다 (2026-10-23). upstage 또는 hash"
        )
    if name == "hash":
        return HashingEmbeddingBackend()
    raise ValueError(f"알 수 없는 임베딩 백엔드: {name} (upstage | hash)")
