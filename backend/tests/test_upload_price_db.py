"""시세 DB 올리기 도구(2026-10-24) — 압축이 원본 그대로 풀리는지 · 서버가 받을 주소 모양."""

from __future__ import annotations

import gzip
import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "upload_price_db", Path(__file__).resolve().parents[1] / "scripts" / "upload_price_db.py"
)
upload = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(upload)


def test_압축은_원본_그대로_풀린다(tmp_path):
    src = tmp_path / "official_price.sqlite"
    src.write_bytes(b"SQLite format 3\x00" + b"x" * 10_000)
    gz = upload.compress(src, tmp_path / "out")
    assert gz.name == "official_price.sqlite.gz"
    assert gzip.decompress(gz.read_bytes()) == src.read_bytes()


def test_주소는_prepare_runtime이_알아보는_파일_이름(tmp_path):
    urls = upload.download_urls("price-db-20261024", ["official_price.sqlite.gz", "tax_base.sqlite.gz"])
    assert urls == (
        "https://github.com/ngh3651/JeonseAI/releases/download/price-db-20261024/official_price.sqlite.gz,"
        "https://github.com/ngh3651/JeonseAI/releases/download/price-db-20261024/tax_base.sqlite.gz"
    )
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
    import prepare_runtime

    for u in urls.split(","):
        assert prepare_runtime._target_name(u) in prepare_runtime.PRICE_DB_FILENAMES
