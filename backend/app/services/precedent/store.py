"""벡터 저장소 — Chroma(주력) + 무의존 JSON 저장소(폴백·테스트), 인터페이스 뒤 교체.

선택 근거 (야간 결정 — decisions.md 2026-07-22 append 참고):
- **Chroma PersistentClient**: 로컬 파일 영속(폴더 복사 = 이전), 코사인 검색·메타데이터
  필터 내장, Python 3.14 설치·동작 검증 완료. 추후 GPU 서버로 옮길 때는
  ⑴ persist 폴더를 그대로 복사하거나 ⑵ chroma를 서버 모드로 띄우고 HttpClient로 교체
  (이 파일의 `ChromaVectorStore`만 수정) — 파이프라인 나머지는 무변경.
- **JsonVectorStore**: 의존성 0(표준 라이브러리만). 테스트가 결정적으로 돌고,
  chromadb 설치가 막힌 환경(팀원 노트북 등)에서도 파이프라인이 산다.
- 판례 수십만 청크까지는 정확(비근사) 코사인 검색으로 충분하다 — HNSW 근사가 필요한
  규모(수백만+)가 되면 그때 chroma 설정만 조정한다.

벡터 공간 서명: 인덱스는 임베딩 백엔드 서명(embedding.py)을 메타로 기록하고,
질의 시 서명이 다르면 명시적 에러 — 서로 다른 모델의 벡터를 섞어 검색하는 사고 방지.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Protocol

from .models import PrecedentChunk

_BACKEND_ROOT = Path(__file__).resolve().parents[3]
#: 저장소에 들어 있는 기본 위치(로컬 개발). 클라우드에서는 `PRECEDENT_INDEX_DIR`로 볼륨 아래를 가리킨다.
DEFAULT_INDEX_DIR = _BACKEND_ROOT / "data" / "precedents" / "index"
#: 판례 원본·시드·제외 목록이 있는 곳 — 저장소에 들어 있다(인덱스 위치와 상관없이 고정).
PRECEDENT_DATA_DIR = _BACKEND_ROOT / "data" / "precedents"


def current_index_dir() -> Path:
    """지금 쓰는 판례 인덱스 위치 — **부를 때마다** `PRECEDENT_INDEX_DIR`을 읽는다 (2026-10-21).

    Chroma가 이 폴더에 **쓴다** → 클라우드에서는 쓰기 가능한 영구 볼륨이어야 한다(`/data/precedents-index`).
    """
    from ... import settings  # 순환 import 방지 — 부를 때 읽는다

    return settings.precedent_index_dir()

_SIG_MISMATCH_MSG = (
    "인덱스 임베딩 서명({indexed})과 질의 백엔드 서명({query})이 달라요. "
    "같은 백엔드로 재적재(scripts/ingest_precedents.py)하거나 백엔드를 맞춰 주세요"
)


class VectorStore(Protocol):
    """파이프라인이 의존하는 인터페이스 — 구현(Chroma/JSON)은 교체 가능."""

    def rebuild(self, chunks: list[PrecedentChunk], vectors: list[list[float]], signature: str) -> None: ...

    def search(
        self, query_vector: list[float], signature: str, *, top_k: int, risk_tags: list[str] | None = None
    ) -> list[tuple[PrecedentChunk, float]]: ...

    def count(self) -> int: ...


def _cosine(a: list[float], b: list[float]) -> float:
    # 저장 벡터는 적재 시 L2 정규화되어 있으나, 방어적으로 재정규화한다
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na > 0 and nb > 0 else 0.0


class JsonVectorStore:
    """무의존 폴백 저장소 — 단일 JSON 파일 영속 + 전수 코사인 검색."""

    def __init__(self, index_dir: Path | None = None) -> None:
        self._path = Path(index_dir or current_index_dir()) / "vectors.json"
        self._chunks: list[PrecedentChunk] = []
        self._vectors: list[list[float]] = []
        self._signature: str | None = None
        if self._path.exists():
            self._load()

    def _load(self) -> None:
        raw = json.loads(self._path.read_text(encoding="utf-8"))
        self._signature = raw.get("signature")
        self._chunks = [PrecedentChunk(**c) for c in raw.get("chunks", [])]
        self._vectors = raw.get("vectors", [])

    def rebuild(self, chunks: list[PrecedentChunk], vectors: list[list[float]], signature: str) -> None:
        if len(chunks) != len(vectors):
            raise ValueError("청크 수와 벡터 수가 다릅니다")
        self._chunks = list(chunks)
        self._vectors = [list(v) for v in vectors]
        self._signature = signature
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "_안내": "판례 벡터 인덱스(자동 생성). 손으로 편집하지 않는다 — scripts/ingest_precedents.py로 재생성.",
            "signature": signature,
            "chunks": [c.model_dump() for c in self._chunks],
            "vectors": self._vectors,
        }
        self._path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

    def search(
        self, query_vector: list[float], signature: str, *, top_k: int, risk_tags: list[str] | None = None
    ) -> list[tuple[PrecedentChunk, float]]:
        if not self._chunks:
            return []
        if self._signature != signature:
            raise RuntimeError(_SIG_MISMATCH_MSG.format(indexed=self._signature, query=signature))
        scored = []
        for chunk, vec in zip(self._chunks, self._vectors):
            if risk_tags and not (set(chunk.risk_tags) & set(risk_tags)):
                continue
            scored.append((chunk, _cosine(query_vector, vec)))
        scored.sort(key=lambda t: t[1], reverse=True)
        return scored[:top_k]

    def count(self) -> int:
        return len(self._chunks)


class ChromaVectorStore:
    """Chroma 영속 저장소. 메타데이터 필터(위험 태그)는 태그별 불리언 컬럼으로 표현한다.

    (chroma의 where 필터는 리스트 컬럼을 지원하지 않아, risk_tags를
    `tag:신탁등기 = True` 형태의 개별 키로 평탄화해 저장한다.)
    """

    COLLECTION = "precedents"

    def __init__(self, index_dir: Path | None = None) -> None:
        import chromadb  # 선택 의존성 — 설치 확인은 get_store()가 담당

        base = Path(index_dir or current_index_dir())
        self._client = chromadb.PersistentClient(path=str(base / "chroma"))
        self._col = self._client.get_or_create_collection(
            self.COLLECTION, metadata={"hnsw:space": "cosine"}
        )

    def rebuild(self, chunks: list[PrecedentChunk], vectors: list[list[float]], signature: str) -> None:
        if len(chunks) != len(vectors):
            raise ValueError("청크 수와 벡터 수가 다릅니다")
        # 재적재는 전체 교체 — 부분 upsert로 낡은 청크가 남는 사고 방지
        self._client.delete_collection(self.COLLECTION)
        self._col = self._client.get_or_create_collection(
            self.COLLECTION, metadata={"hnsw:space": "cosine"}
        )
        if not chunks:
            return
        metadatas = []
        for c in chunks:
            md: dict = {
                "case_id": c.case_id,
                "section": c.section,
                "signature": signature,
                "risk_tags": ",".join(c.risk_tags),
            }
            for tag in c.risk_tags:
                md[f"tag:{tag}"] = True
            metadatas.append(md)
        self._col.upsert(
            ids=[c.chunk_id for c in chunks],
            embeddings=vectors,
            documents=[c.text for c in chunks],
            metadatas=metadatas,
        )

    def _chunk_from(self, chunk_id: str, document: str, md: dict) -> PrecedentChunk:
        tags = [t for t in (md.get("risk_tags") or "").split(",") if t]
        return PrecedentChunk(
            chunk_id=chunk_id,
            case_id=md.get("case_id", chunk_id.split("#")[0]),
            section=md.get("section", "판결요지"),
            text=document,
            risk_tags=tags,
        )

    def search(
        self, query_vector: list[float], signature: str, *, top_k: int, risk_tags: list[str] | None = None
    ) -> list[tuple[PrecedentChunk, float]]:
        if self.count() == 0:
            return []
        # 서명 검증 — 아무 항목 하나의 메타를 확인
        probe = self._col.peek(limit=1)
        indexed_sig = (probe["metadatas"] or [{}])[0].get("signature")
        if indexed_sig != signature:
            raise RuntimeError(_SIG_MISMATCH_MSG.format(indexed=indexed_sig, query=signature))

        where = None
        if risk_tags:
            conds = [{f"tag:{t}": True} for t in risk_tags]
            where = conds[0] if len(conds) == 1 else {"$or": conds}
        res = self._col.query(
            query_embeddings=[query_vector],
            n_results=min(top_k, self.count()),
            where=where,
            include=["documents", "metadatas", "distances"],
        )
        out: list[tuple[PrecedentChunk, float]] = []
        for chunk_id, doc, md, dist in zip(
            res["ids"][0], res["documents"][0], res["metadatas"][0], res["distances"][0]
        ):
            out.append((self._chunk_from(chunk_id, doc, md), 1.0 - dist))  # cosine distance → similarity
        return out

    def count(self) -> int:
        return self._col.count()


def get_store(index_dir: Path | None = None, *, kind: str | None = None) -> VectorStore:
    """저장소 선택 — 환경변수 `PRECEDENT_VECTOR_STORE` (chroma | json).

    미지정 시 chroma를 시도하고, import 실패 환경이면 json으로 자동 폴백한다.
    """
    import os

    kind = (kind or os.environ.get("PRECEDENT_VECTOR_STORE", "")).strip().lower()
    index_dir = index_dir or current_index_dir()
    if kind == "json":
        return JsonVectorStore(index_dir)
    if kind == "chroma":
        return ChromaVectorStore(index_dir)
    try:
        return ChromaVectorStore(index_dir)
    except ImportError:
        return JsonVectorStore(index_dir)
