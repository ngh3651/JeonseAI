"""같은 사진 = 같은 결과 (P1-1, 2026-10-22) — 분석 결과 캐시.

같은 기기가 같은 JPEG 묶음(순서까지) + 같은 보증금·시세로 다시 분석하면, IE·OCR을 다시 부르지 않고
(크레딧 0원) **같은 리포트**를 돌려준다. 기간은 `ANALYSIS_CACHE_HOURS`(기본 24시간).
"""

from __future__ import annotations

import logging
from datetime import timedelta

import pytest

from app.schemas.contract import Report
from app.services import analysis_cache, name_privacy, store

from tests.test_analyze_smoke import (  # noqa: F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page

PHONE_A = {"X-Device-Id": "cache-phone-aaaa-01"}
PHONE_B = {"X-Device-Id": "cache-phone-bbbb-02"}


def _photo(variant: int = 0) -> bytes:
    """같은 크기 다른 사진 — variant마다 바이트가 다르다(맨 끝에 몇 바이트를 붙여도 JPEG는 그대로 읽힌다)."""
    return blank_image(PAGE_W, PAGE_H) + b"\x00" * variant


def _analyze(client, images: list[bytes], *, headers=PHONE_A, deposit=120_000_000, price=None, alias=None):
    files = [("files", (f"page_{i + 1}.jpg", data, "image/jpeg")) for i, data in enumerate(images)]
    data = {"deposit": str(deposit)}
    if price is not None:
        data["marketPrice"] = str(price)
    if alias is not None:
        data["alias"] = alias
    return client.post("/api/analyze", files=files, data=data, headers=headers)


def _ie_calls(calls: list[str]) -> int:
    return sum(1 for u in calls if "information-extraction" in u)


class _Collect(logging.Handler):
    def __init__(self) -> None:
        super().__init__(level=logging.DEBUG)
        self.lines: list[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.lines.append(record.getMessage())


@pytest.fixture
def logs():
    logger = logging.getLogger("jeonseai")
    handler = _Collect()
    logger.addHandler(handler)
    old = logger.level
    logger.setLevel(logging.DEBUG)
    yield handler.lines
    logger.removeHandler(handler)
    logger.setLevel(old)


# ══════════════════════════════════════════════════════════════════════════════
# ① 같은 입력 → 같은 리포트, 크레딧 0원
# ══════════════════════════════════════════════════════════════════════════════


def test_같은_사진을_다시_넣으면_같은_리포트가_크레딧_없이_나온다(client, no_network, logs):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    first = _analyze(client, [_photo()])
    assert first.status_code == 200, first.text
    n_after_first = len(calls)

    second = _analyze(client, [_photo()])
    assert second.status_code == 200, second.text
    # 같은 리포트 — 다만 캐시 적중은 **서버 기록의 가린 사본**이다(2026-10-22 화면엔 실명, 저장은 가린 사본).
    # 앱은 폰에 둔 원본(실명)을 먼저 쓴다.
    stored = name_privacy.mask_report_for_storage(Report.model_validate(first.json()))
    assert second.json() == stored.model_dump(mode="json"), "같은 사진인데 리포트가 다르다"
    assert "홍길동" in first.text and "홍길동" not in second.text
    assert len(calls) == n_after_first, f"캐시 적중인데 외부 호출이 늘었다: {calls[n_after_first:]}"
    # 캐시 적중은 로그에 한 줄
    hits = [line for line in logs if line.startswith("[캐시] 적중")]
    assert len(hits) == 1 and "크레딧 0원" in hits[0]
    # 기록에는 한 건만 (같은 리포트를 두 번 넣지 않는다)
    ids = [r["id"] for r in client.get("/api/reports", headers=PHONE_A).json()]
    assert ids.count(first.json()["id"]) == 1


@pytest.mark.parametrize(
    "change",
    [
        {"images": [_photo(1)]},  # 다른 사진
        {"deposit": 130_000_000},  # 다른 보증금
        {"price": 300_000_000},  # 시세를 넣음
    ],
    ids=["다른 사진", "다른 보증금", "시세 입력"],
)
def test_사진이나_입력이_다르면_다시_분석한다(client, no_network, change):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    first = _analyze(client, [_photo()]).json()
    kwargs = {"images": [_photo()], **change}
    images = kwargs.pop("images")
    second = _analyze(client, images, **kwargs)
    assert second.status_code == 200, second.text
    assert second.json()["id"] != first["id"]
    assert _ie_calls(calls) == 2


def test_사진_순서가_다르면_다시_분석한다(client, no_network):
    """하이라이트·가림 상자의 쪽 번호가 업로드 순서라 순서가 다르면 다른 리포트다."""
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0)), raw_ocr_json(gap_gu_page(1))] * 2)
    _analyze(client, [_photo(0), _photo(1)])
    _analyze(client, [_photo(1), _photo(0)])
    assert _ie_calls(calls) == 2


def test_다른_기기는_캐시를_같이_쓰지_않는다(client, no_network):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    a = _analyze(client, [_photo()], headers=PHONE_A).json()
    _analyze(client, [_photo()], headers=PHONE_B)
    assert _ie_calls(calls) == 2, "다른 기기인데 캐시가 적중했다"
    # B의 기록에 A의 리포트가 섞이지 않는다
    ids_b = [r["id"] for r in client.get("/api/reports", headers=PHONE_B).json()]
    assert a["id"] not in ids_b


def test_별칭만_바꾸면_같은_리포트에_새_별칭을_붙인다(client, no_network):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    first = _analyze(client, [_photo()], alias="첫 이름").json()
    second = _analyze(client, [_photo()], alias="새 이름").json()
    assert second["id"] == first["id"] and second["alias"] == "새 이름"
    assert _ie_calls(calls) == 1
    # 기록에도 새 별칭으로
    saved = client.get(f"/api/reports/{first['id']}", headers=PHONE_A).json()
    assert saved["alias"] == "새 이름"


# ══════════════════════════════════════════════════════════════════════════════
# ② 기간 · 끄기 · 지운 리포트 · 덜 된 결과
# ══════════════════════════════════════════════════════════════════════════════


def test_기간이_지나면_다시_분석한다(client, no_network, monkeypatch):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    _analyze(client, [_photo()])
    real_now = analysis_cache._now
    monkeypatch.setattr(analysis_cache, "_now", lambda: real_now() + timedelta(hours=25))
    _analyze(client, [_photo()])
    assert _ie_calls(calls) == 2


def test_기간은_ANALYSIS_CACHE_HOURS로_바꾼다(client, no_network, monkeypatch):
    monkeypatch.setenv("ANALYSIS_CACHE_HOURS", "48")
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    _analyze(client, [_photo()])
    real_now = analysis_cache._now
    monkeypatch.setattr(analysis_cache, "_now", lambda: real_now() + timedelta(hours=30))
    _analyze(client, [_photo()])
    assert _ie_calls(calls) == 1, "48시간으로 늘렸으니 30시간 뒤에도 적중해야 한다"


def test_0이면_캐시를_끈다(client, no_network, monkeypatch):
    monkeypatch.setenv("ANALYSIS_CACHE_HOURS", "0")
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    _analyze(client, [_photo()])
    _analyze(client, [_photo()])
    assert _ie_calls(calls) == 2


def test_리포트를_지우면_캐시도_빗나간다(client, no_network):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    rid = _analyze(client, [_photo()]).json()["id"]
    assert client.delete(f"/api/reports/{rid}", headers=PHONE_A).status_code == 204
    second = _analyze(client, [_photo()])
    assert second.status_code == 200 and second.json()["id"] != rid
    assert _ie_calls(calls) == 2


def test_읽지_못한_쪽이_있는_결과는_캐시하지_않는다(client, no_network, logs):
    """OCR이 실패한 결과를 24시간 붙잡아 두면 '다시 시도'를 눌러도 나아지지 않는다."""
    # 첫 분석: OCR 응답이 빈 페이지(글자 0개) → 그 쪽은 통째로 가려짐 = 덜 된 결과
    empty_ocr = {"apiVersion": "1.1", "pages": [{"id": 0, "width": PAGE_W, "height": PAGE_H, "words": []}]}
    calls = no_network(registry_raw(), [empty_ocr, raw_ocr_json(gap_gu_page(0))])
    first = _analyze(client, [_photo()])
    assert first.status_code == 200, first.text
    assert any("캐시하지 않습니다" in line for line in logs)
    second = _analyze(client, [_photo()])
    assert second.status_code == 200 and second.json()["id"] != first.json()["id"]
    assert _ie_calls(calls) == 2


def test_상한에_걸리면_캐시가_있어도_429(client, no_network, monkeypatch):
    """같은 사진을 끝없이 보내 서버를 붙잡지 못하게 — 횟수는 캐시보다 먼저 센다."""
    monkeypatch.setenv("RATE_LIMIT_ANALYZE_PER_HOUR", "2")
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    assert _analyze(client, [_photo()]).status_code == 200
    assert _analyze(client, [_photo()]).status_code == 200  # 캐시 적중도 1회
    assert _analyze(client, [_photo()]).status_code == 429


def test_캐시가_깨져도_분석은_처음부터_된다(client, no_network, monkeypatch):
    def broken(*_a, **_k):
        raise RuntimeError("DB 고장")

    monkeypatch.setattr(analysis_cache, "_execute", broken)
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    assert _analyze(client, [_photo()]).status_code == 200
    assert _analyze(client, [_photo()]).status_code == 200
    assert _ie_calls(calls) == 2


def test_서버를_다시_켜도_캐시가_남는다(client, no_network):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    first = _analyze(client, [_photo()]).json()
    store.reset()  # 재시작 흉내 — 파일은 그대로
    second = _analyze(client, [_photo()]).json()
    assert second["id"] == first["id"] and _ie_calls(calls) == 1


# ══════════════════════════════════════════════════════════════════════════════
# ③ 키 · 개인정보
# ══════════════════════════════════════════════════════════════════════════════


def test_키는_사진_바이트와_순서와_입력으로만_정해진다(monkeypatch):
    monkeypatch.delenv("RAILWAY_GIT_COMMIT_SHA", raising=False)
    a, b = _photo(0), _photo(1)
    k = analysis_cache.make_key([("x.jpg", a), ("y.jpg", b)], deposit=1, market_price=None)
    assert k == analysis_cache.make_key([("다른이름.jpg", a), ("z.jpg", b)], deposit=1, market_price=None)
    assert k != analysis_cache.make_key([("x.jpg", b), ("y.jpg", a)], deposit=1, market_price=None)
    assert k != analysis_cache.make_key([("x.jpg", a), ("y.jpg", b)], deposit=2, market_price=None)
    assert k != analysis_cache.make_key([("x.jpg", a), ("y.jpg", b)], deposit=1, market_price=0)
    assert len(k) == 64


def test_키에는_서버_코드_버전이_들어간다(monkeypatch):
    """Railway가 배포마다 넣는 커밋 해시(`RAILWAY_GIT_COMMIT_SHA`) — 없으면 고정 문자열."""
    images = [("x.jpg", _photo(0))]
    monkeypatch.delenv("RAILWAY_GIT_COMMIT_SHA", raising=False)
    assert analysis_cache.code_version() == analysis_cache.LOCAL_CODE_VERSION
    local = analysis_cache.make_key(images, deposit=1, market_price=None)
    assert local == analysis_cache.make_key(images, deposit=1, market_price=None)

    monkeypatch.setenv("RAILWAY_GIT_COMMIT_SHA", "aaaa1111aaaa1111")
    assert analysis_cache.code_version() == "aaaa1111aaaa1111"
    deploy_a = analysis_cache.make_key(images, deposit=1, market_price=None)
    assert deploy_a == analysis_cache.make_key(images, deposit=1, market_price=None)  # 같은 배포 = 같은 키
    monkeypatch.setenv("RAILWAY_GIT_COMMIT_SHA", "bbbb2222bbbb2222")
    deploy_b = analysis_cache.make_key(images, deposit=1, market_price=None)
    assert len({local, deploy_a, deploy_b}) == 3


def test_새로_배포하면_같은_사진도_처음부터_분석한다(client, no_network, monkeypatch):
    """규칙을 고쳐 배포했는데 24시간 동안 옛 판정을 돌려주면 안 된다."""
    monkeypatch.setenv("RAILWAY_GIT_COMMIT_SHA", "aaaa1111aaaa1111")
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    first = _analyze(client, [_photo()]).json()
    assert _analyze(client, [_photo()]).json()["id"] == first["id"]  # 같은 배포 안에서는 적중
    assert _ie_calls(calls) == 1

    monkeypatch.setenv("RAILWAY_GIT_COMMIT_SHA", "bbbb2222bbbb2222")  # 새 배포
    second = _analyze(client, [_photo()])
    assert second.status_code == 200, second.text
    assert second.json()["id"] != first["id"]
    assert _ie_calls(calls) == 2


def test_캐시_표에는_사진도_이름도_없다(client, no_network):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    _analyze(client, [_photo()])
    rows = analysis_cache._execute("SELECT * FROM analysis_cache")
    assert len(rows) == 1
    device, key, report_id, created = rows[0]
    assert device == PHONE_A["X-Device-Id"] and len(key) == 64 and report_id.startswith("analysis-")
    assert "홍길동" not in repr(rows)
