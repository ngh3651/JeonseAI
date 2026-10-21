"""클라우드 배포 준비 — 헬스 준비 상태 · 데이터 위치 설정 · 환경변수 지연 읽기 · 시작 준비 스크립트.

(2026-10-21, Railway 기준. 실제 외부 호출은 하지 않는다 — 내려받기는 가짜 opener로 흉내 낸다.)
"""

from __future__ import annotations

import gzip
import importlib.util
import io
import json
import sqlite3
from pathlib import Path

import pytest

from tests.test_analyze_smoke import client  # noqa: F401 — pytest 픽스처 재사용

_BACKEND = Path(__file__).resolve().parents[1]
_REPO = _BACKEND.parent


def _load_prepare_runtime():
    spec = importlib.util.spec_from_file_location(
        "prepare_runtime", _BACKEND / "scripts" / "prepare_runtime.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _sqlite_bytes(tmp_path: Path) -> bytes:
    path = tmp_path / "src.sqlite"
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE t (x INTEGER)")
    conn.commit()
    conn.close()
    return path.read_bytes()


# ══════════════════════════════════════════════════════════════════════════════
# ① 헬스체크 — 준비 상태는 참/거짓만, 비밀은 0
# ══════════════════════════════════════════════════════════════════════════════


def test_헬스체크는_예전_필드를_유지하고_준비_상태를_붙인다(client, tmp_path, monkeypatch):
    monkeypatch.setenv("PRICE_DB_DIR", str(tmp_path / "price"))
    monkeypatch.setenv("PRECEDENT_INDEX_DIR", str(tmp_path / "index"))
    monkeypatch.setenv("UPSTAGE_API_KEY", "")
    monkeypatch.setenv("MOLIT_API_KEY", "")
    monkeypatch.delenv("RAILWAY_GIT_COMMIT_SHA", raising=False)

    body = client.get("/").json()
    assert body["status"] == "ok"  # 앱·플랫폼 헬스체크가 보는 필드
    assert body["priceDb"] is False and body["precedentIndex"] is False
    assert body["upstageKey"] is False and body["molitKey"] is False
    assert "version" not in body


def test_헬스체크는_키_값을_절대_내보내지_않는다(client, tmp_path, monkeypatch):
    secret_upstage = "up_SECRET_value_should_never_leak_123"
    secret_molit = "molit%2BSECRET%3D%3D"
    monkeypatch.setenv("UPSTAGE_API_KEY", secret_upstage)
    monkeypatch.setenv("MOLIT_API_KEY", secret_molit)
    monkeypatch.setenv("APP_KEY", "booth-key-2026")
    monkeypatch.setenv("RAILWAY_GIT_COMMIT_SHA", "0123456789abcdef0123456789abcdef01234567")

    resp = client.get("/")  # 앱 키 없이도 열려 있다
    assert resp.status_code == 200
    body = resp.json()
    assert body["upstageKey"] is True and body["molitKey"] is True
    assert body["version"] == "0123456"
    for secret in (secret_upstage, secret_molit, "booth-key-2026", str(tmp_path)):
        assert secret not in resp.text
    # 값의 종류도 못 박는다 — 참/거짓과 짧은 버전 문자열뿐
    assert {k for k, v in body.items() if not isinstance(v, bool)} == {"status", "version"}


def test_헬스체크는_외부를_부르지_않는다(client, monkeypatch):
    """플랫폼이 몇 초마다 부른다 — 키 유효성 확인(크레딧·지연)은 check_keys.py의 일이다."""
    import requests

    def boom(*a, **k):
        raise AssertionError("헬스체크가 외부 API를 불렀다")

    monkeypatch.setattr(requests, "get", boom)
    monkeypatch.setattr(requests, "post", boom)
    monkeypatch.setenv("UPSTAGE_API_KEY", "up_x")
    assert client.get("/").status_code == 200


def test_시세_DB와_판례_인덱스가_있으면_참이다(client, tmp_path, monkeypatch):
    price = tmp_path / "price"
    index = tmp_path / "index"
    price.mkdir()
    index.mkdir()
    (price / "official_price.sqlite").write_bytes(b"x")
    monkeypatch.setenv("PRICE_DB_DIR", str(price))
    monkeypatch.setenv("PRECEDENT_INDEX_DIR", str(index))
    assert client.get("/").json()["priceDb"] is False, "둘 중 하나만 있으면 준비 안 됨"

    (price / "tax_base.sqlite").write_bytes(b"x")
    (index / "docs.jsonl").write_text("", encoding="utf-8")
    body = client.get("/").json()
    assert body["priceDb"] is True and body["precedentIndex"] is True


# ══════════════════════════════════════════════════════════════════════════════
# ② 데이터 위치 — 환경변수로 볼륨 아래를 가리킨다 (부를 때 읽는다)
# ══════════════════════════════════════════════════════════════════════════════


def test_시세_DB_위치는_PRICE_DB_DIR을_따른다(tmp_path, monkeypatch):
    from app.services import official_price as OP

    monkeypatch.setenv("PRICE_DB_DIR", str(tmp_path / "vol" / "price"))
    assert OP.db_path("official_price") == tmp_path / "vol" / "price" / "official_price.sqlite"
    assert OP.db_path("tax_base") == tmp_path / "vol" / "price" / "tax_base.sqlite"
    monkeypatch.delenv("PRICE_DB_DIR")
    assert OP.db_path("official_price") == _BACKEND / "data" / "price" / "official_price.sqlite"


def test_판례_인덱스_위치는_PRECEDENT_INDEX_DIR을_따른다(tmp_path, monkeypatch):
    from app.services.precedent import store as pstore
    from app.services.precedent.retrieval import HybridRetriever

    monkeypatch.setenv("PRECEDENT_INDEX_DIR", str(tmp_path / "pidx"))
    assert pstore.current_index_dir() == tmp_path / "pidx"
    monkeypatch.setenv("PRECEDENT_VECTOR_STORE", "json")
    retriever = HybridRetriever()
    assert retriever._index_dir == tmp_path / "pidx"
    # 원본·시드는 인덱스 위치와 상관없이 저장소 안에 있다
    assert (pstore.PRECEDENT_DATA_DIR / "seed_cases.json").is_file()


def test_판례_인덱스를_볼륨_위치에_만들_수_있다(tmp_path, monkeypatch):
    """Chroma 대신 json 저장소 + 해시 임베딩으로(크레딧 0) 실제 적재를 돌려 본다."""
    from app.services.precedent.embedding import get_backend
    from app.services.precedent.ingest import ingest

    monkeypatch.setenv("PRECEDENT_INDEX_DIR", str(tmp_path / "pidx"))
    monkeypatch.setenv("PRECEDENT_VECTOR_STORE", "json")
    meta = ingest(backend=get_backend("hash"), verbose=False)
    assert meta["doc_count"] > 0
    assert (tmp_path / "pidx" / "docs.jsonl").is_file()


def test_임베딩_모델_설정은_import_뒤에_바꿔도_먹는다(monkeypatch):
    """예전에는 import 순간 굳어서 `.env`·플랫폼 값이 늦게 들어오면 무시됐다."""
    from app.services.precedent import embedding

    monkeypatch.setenv("UPSTAGE_EMBEDDING_PASSAGE_MODEL", "embedding-passage-v9")
    monkeypatch.setenv("UPSTAGE_EMBEDDING_URL", "https://example.invalid/v1/embeddings")
    assert embedding.upstage_passage_model() == "embedding-passage-v9"
    assert embedding.upstage_embedding_url() == "https://example.invalid/v1/embeddings"
    assert embedding.UpstageEmbeddingBackend(api_key="k").signature == "upstage:embedding-passage-v9"
    monkeypatch.delenv("UPSTAGE_EMBEDDING_PASSAGE_MODEL")
    assert embedding.upstage_passage_model() == "embedding-passage"


def test_import_시점에_환경변수를_읽어_굳히는_모듈_상수가_없다():
    """`X = os.environ.get(...)` 꼴의 모듈 상수가 다시 생기면 같은 버그가 돌아온다."""
    import re

    pattern = re.compile(r"^[A-Z_][A-Z0-9_]*\s*(:[^=]+)?=\s*os\.(environ\.get|getenv)\(", re.M)
    offenders = [
        str(p.relative_to(_BACKEND))
        for p in (_BACKEND / "app").rglob("*.py")
        if pattern.search(p.read_text(encoding="utf-8"))
    ]
    assert offenders == []


# ══════════════════════════════════════════════════════════════════════════════
# ③ 시작 준비 스크립트 (prepare_runtime.py) — 몇 번 돌려도 같고, 절대 죽지 않는다
# ══════════════════════════════════════════════════════════════════════════════


@pytest.fixture
def runtime_env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("PRICE_DB_DIR", str(tmp_path / "data" / "price"))
    monkeypatch.setenv("PRECEDENT_INDEX_DIR", str(tmp_path / "data" / "precedents-index"))
    monkeypatch.delenv("PRICE_DB_URLS", raising=False)
    monkeypatch.delenv("BUILD_PRECEDENT_INDEX", raising=False)
    return tmp_path / "data"


class _FakeResp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def test_준비_스크립트는_폴더를_만들고_아무것도_없어도_0으로_끝난다(runtime_env, capsys):
    prep = _load_prepare_runtime()
    assert prep.main() == 0
    for sub in ("", "price", "precedents-index"):
        assert (runtime_env / sub).is_dir()
    assert prep.main() == 0  # 두 번 돌려도 같다
    out = capsys.readouterr().out
    assert "PRICE_DB_URLS" in out  # 왜 시세 DB가 없는지 로그로 말한다


def test_시세_DB를_내려받아_원자적으로_저장한다(runtime_env, tmp_path, monkeypatch):
    prep = _load_prepare_runtime()
    raw = _sqlite_bytes(tmp_path)
    monkeypatch.setenv(
        "PRICE_DB_URLS",
        "https://example.invalid/r/official_price.sqlite.gz?token=SECRET,"
        "https://example.invalid/r/tax_base.sqlite",
    )
    payloads = {
        "official_price.sqlite.gz": gzip.compress(raw),
        "tax_base.sqlite": raw,
    }
    opened: list[str] = []

    def opener(url, timeout):
        opened.append(url)
        name = url.split("?")[0].rsplit("/", 1)[-1]
        return _FakeResp(payloads[name])

    prep.prepare_price_db(opener=opener)
    price = runtime_env / "price"
    assert (price / "official_price.sqlite").read_bytes() == raw  # .gz는 풀어서 저장
    assert (price / "tax_base.sqlite").read_bytes() == raw
    assert not list(price.glob("*.part")), "임시 파일이 남았다"
    assert len(opened) == 2

    prep.prepare_price_db(opener=opener)  # 이미 있으면 다시 받지 않는다
    assert len(opened) == 2


def test_내려받기_실패는_3번_다시_시도하고_서버를_막지_않는다(runtime_env, monkeypatch, capsys):
    prep = _load_prepare_runtime()
    monkeypatch.setattr(prep.time, "sleep", lambda s: None)
    monkeypatch.setenv("PRICE_DB_URLS", "https://example.invalid/official_price.sqlite?sig=SECRET")
    calls = []

    def opener(url, timeout):
        calls.append(url)
        raise OSError("연결 끊김")

    prep.prepare_price_db(opener=opener)
    assert len(calls) == 3
    assert not (runtime_env / "price" / "official_price.sqlite").exists()
    assert not list((runtime_env / "price").glob("*.part"))
    out = capsys.readouterr().out
    assert "SECRET" not in out, "주소의 토큰이 로그에 찍혔다"


def test_SQLite가_아닌_파일은_DB로_받아들이지_않는다(runtime_env, monkeypatch):
    """HTML 오류 페이지를 DB 이름으로 저장하면 서버가 '시세 DB 있음'으로 착각한다."""
    prep = _load_prepare_runtime()
    monkeypatch.setattr(prep.time, "sleep", lambda s: None)
    monkeypatch.setenv("PRICE_DB_URLS", "https://example.invalid/official_price.sqlite")
    prep.prepare_price_db(opener=lambda url, timeout: _FakeResp(b"<html>404</html>"))
    assert not (runtime_env / "price" / "official_price.sqlite").exists()


def test_판례_인덱스는_스위치와_키가_있을_때만_만든다(runtime_env, monkeypatch):
    prep = _load_prepare_runtime()
    built = []

    def fake_ingest():
        built.append(1)
        (runtime_env / "precedents-index").mkdir(parents=True, exist_ok=True)
        (runtime_env / "precedents-index" / "docs.jsonl").write_text("", encoding="utf-8")
        return {"doc_count": 3}

    monkeypatch.setenv("UPSTAGE_API_KEY", "up_x")
    prep.prepare_precedent_index(ingest_fn=fake_ingest)
    assert built == [], "스위치 없이 크레딧을 썼다"

    monkeypatch.setenv("BUILD_PRECEDENT_INDEX", "1")
    monkeypatch.setenv("UPSTAGE_API_KEY", "")
    prep.prepare_precedent_index(ingest_fn=fake_ingest)
    assert built == [], "키 없이 만들려 했다"

    monkeypatch.setenv("UPSTAGE_API_KEY", "up_x")
    prep.prepare_precedent_index(ingest_fn=fake_ingest)
    assert built == [1]
    prep.prepare_precedent_index(ingest_fn=fake_ingest)  # 이미 있으면 건너뛴다(크레딧 1회)
    assert built == [1]


def test_판례_인덱스_실패도_서버를_막지_않는다(runtime_env, monkeypatch):
    prep = _load_prepare_runtime()
    monkeypatch.setenv("BUILD_PRECEDENT_INDEX", "1")
    monkeypatch.setenv("UPSTAGE_API_KEY", "up_x")

    def boom():
        raise RuntimeError("402 크레딧 소진")

    prep.prepare_precedent_index(ingest_fn=boom)  # 예외가 새지 않는다


# ══════════════════════════════════════════════════════════════════════════════
# ④ 배포 파일 — 이미지가 서버에 필요한 것만, 비밀 없이
# ══════════════════════════════════════════════════════════════════════════════


def test_도커파일과_railway_설정이_약속대로다():
    dockerfile = (_REPO / "Dockerfile").read_text(encoding="utf-8")
    assert "FROM python:3.12-slim" in dockerfile
    assert "PYTHONUNBUFFERED=1" in dockerfile
    assert "USER app" in dockerfile  # root가 아닌 사용자
    assert "prepare_runtime.py" in dockerfile and "--reload" not in dockerfile
    assert "--host 0.0.0.0" in dockerfile and "${PORT:-8000}" in dockerfile

    ignore = (_REPO / ".dockerignore").read_text(encoding="utf-8").split()
    for needed in (
        "frontend/", "docs/", ".git", ".github", "backend/.venv/", "backend/out/",
        "backend/logs/", "backend/test_samples/", "backend/data/price/raw/",
        "backend/data/runtime/", "design_handoff_*", "**/.env",
    ):
        assert needed in ignore, needed

    railway = json.loads((_REPO / "railway.json").read_text(encoding="utf-8"))
    assert railway["build"]["builder"] == "DOCKERFILE"
    assert railway["deploy"]["healthcheckPath"] == "/"
    assert railway["deploy"]["restartPolicyType"] in {"ON_FAILURE", "ALWAYS"}
