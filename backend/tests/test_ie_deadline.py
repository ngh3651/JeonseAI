"""IE가 늦으면 기다리지 않는다 · 시세는 미리 조회한다 (2026-11-02 규혁 결정 — IE 상한 35초).

2026-11-02 아침 IE가 88초·150초 걸려 앱이 99%에서 멈췄다(같은 키로 곧 17.5초로 돌아옴 — Upstage 서버 지연).
상한이 지나도 IE가 안 왔고 두 번째 읽기(OCR 글자 → 구조화, IE와 같은 모양)가 끝나 있으면 그 결과로 판정한다.
판정은 그대로 규칙 엔진이 한다. 2026-11-03 규혁 결정: '양호'도 막지 않는다 — IE로 읽은 것과 같은 판정이 나온다.
"""

from __future__ import annotations

import time

from app.schemas.internal import RegistryExtract
from app.services import extraction, price_lookup, report_builder

from tests.test_analyze_smoke import blank_image, client, no_network, post_analyze, raw_ocr_json, registry_raw  # noqa: F401
from tests.test_orientation import GOOD, dotted
from tests.test_highlight import PAGE_H, PAGE_W


def _with_second(monkeypatch, second: dict) -> None:
    """두 번째 읽기(구조화)가 `second`를 돌려준 것처럼 — OCR은 진짜 경로(가짜 HTTP)를 탄다."""
    real = report_builder._ocr_then_second_opinion

    def fake(images, run_id=None, stop=None):
        bundle = real(images, run_id, stop)
        bundle.second_extract = RegistryExtract.from_raw(second)
        bundle.second_provider = "upstage"
        bundle.error = None
        return bundle

    monkeypatch.setattr(report_builder, "_ocr_then_second_opinion", fake)


def _slow_ie(monkeypatch, seconds: float, raw: dict) -> list[float]:
    started: list[float] = []

    def slow(images, run_id=None):
        started.append(time.perf_counter())
        time.sleep(seconds)
        return RegistryExtract.from_raw(raw)

    monkeypatch.setattr(extraction, "extract_registry", slow)
    return started


def test_IE가_상한을_넘으면_두_번째_읽기로_판정한다(client, no_network, monkeypatch):
    monkeypatch.setenv("IE_DEADLINE_SECONDS", "0.3")
    no_network(registry_raw(), [GOOD])
    _with_second(monkeypatch, registry_raw())
    empty = {**registry_raw(), "mortgages": []}
    _slow_ie(monkeypatch, 3.0, empty)  # 늦은 IE는 빚이 없다고 읽었다 — 쓰이면 안 된다
    t0 = time.perf_counter()
    resp = post_analyze(client, [dotted(PAGE_W, PAGE_H)])
    took = time.perf_counter() - t0
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert took < 2.5, f"늦은 IE를 기다렸어요({took:.1f}초)"
    assert body["seniorDebtAmount"] > 0, "두 번째 읽기 결과로 판정했다"
    late = [n for n in body["checkedNotes"] if "문서 읽기 서버가 늦어" in n]
    assert late and "한 가지 방법으로만" in late[0], "앱 뷰어가 보여 주는 낱말이 들어 있어야 한다"
    assert not any("분석 결과에는 영향이 없어요" in n for n in body["checkedNotes"]), "늦은 IE면 틀린 말"
    assert not any("양호" in n and "단정" in n for n in body["checkedNotes"]), "'양호'를 막는다는 말은 이제 틀린 말"


def test_두_번째_읽기가_없으면_IE를_끝까지_기다린다(client, no_network, monkeypatch):
    monkeypatch.setenv("IE_DEADLINE_SECONDS", "0.2")
    no_network(registry_raw(), [GOOD])  # 두 번째 경로 꺼짐(LLM_STRUCTURE_PROVIDER=off)
    _slow_ie(monkeypatch, 0.8, registry_raw())
    resp = post_analyze(client, [dotted(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    assert not any("문서 읽기 서버가 늦어" in n for n in resp.json()["checkedNotes"])


def test_IE가_제때_오면_예전과_같다(client, no_network, monkeypatch):
    monkeypatch.setenv("IE_DEADLINE_SECONDS", "5")
    no_network(registry_raw(), [GOOD])
    _with_second(monkeypatch, registry_raw())
    resp = post_analyze(client, [dotted(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    assert not any("문서 읽기 서버가 늦어" in n for n in resp.json()["checkedNotes"])


def test_시세는_IE를_기다리는_동안_미리_조회하고_같은_주소면_다시_조회하지_않는다(client, no_network, monkeypatch):
    monkeypatch.setenv("IE_DEADLINE_SECONDS", "5")
    no_network(registry_raw(), [GOOD])
    _with_second(monkeypatch, registry_raw())
    _slow_ie(monkeypatch, 0.6, registry_raw())  # 두 번째 읽기가 먼저 끝나게
    calls: list[str | None] = []
    real = price_lookup.collect

    def counting(**kw):
        calls.append(kw.get("address"))
        return real(**{**kw, "auto": False})

    monkeypatch.setattr(price_lookup, "collect", counting)
    resp = post_analyze(client, [dotted(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    assert len(calls) == 1, f"같은 주소인데 두 번 조회했어요: {calls}"


def test_미리_조회한_주소가_IE와_다르면_IE_주소로_다시_조회한다(client, no_network, monkeypatch):
    monkeypatch.setenv("IE_DEADLINE_SECONDS", "5")
    no_network(registry_raw(), [GOOD])
    _with_second(monkeypatch, {**registry_raw(), "address": "서울특별시 종로구 다른동 1 제1층 제101호"})
    _slow_ie(monkeypatch, 0.6, registry_raw())
    calls: list[str | None] = []
    real = price_lookup.collect

    def counting(**kw):
        calls.append(kw.get("address"))
        return real(**{**kw, "auto": False})

    monkeypatch.setattr(price_lookup, "collect", counting)
    resp = post_analyze(client, [dotted(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    assert len(calls) == 2 and "다른동" in (calls[0] or "") and "다른동" not in (calls[1] or "")


def test_늦은_IE여도_두_번째_읽기_재료면_IE와_같은_판정이_나온다():
    """2026-11-03 규혁 결정 — IE가 늦어 두 번째 읽기로 판정해도 '양호'를 막지 않는다(시연 중 전부 '확인 필요'가 되던 문제)."""
    from app.services import rule_engine

    extract = RegistryExtract.from_raw({**registry_raw(), "mortgages": []})
    assert not extract.doc_incomplete
    v = rule_engine.evaluate(extract, deposit=100_000_000, market_price=400_000_000, blacklist_entries=[])
    assert not any("서버가 늦어" in f for f in v.doc_flags)


def _failing_ie(monkeypatch, status: int) -> None:
    def fail(images, run_id=None):
        raise extraction.ExtractionError(status, "일부러 낸 실패")

    monkeypatch.setattr(extraction, "extract_registry", fail)


def test_IE가_잠깐_실패해도_두_번째_읽기가_있으면_판정한다(client, no_network, monkeypatch):
    """2026-11-03 버그 검토 — 늦으면 대신하면서 실패하면 분석 전체를 잃던 비대칭."""
    monkeypatch.setenv("IE_DEADLINE_SECONDS", "35")
    no_network(registry_raw(), [GOOD])
    _with_second(monkeypatch, registry_raw())
    _failing_ie(monkeypatch, 503)
    resp = post_analyze(client, [dotted(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    assert any("한 가지 방법으로만" in n for n in resp.json()["checkedNotes"])


def test_사진_문제로_IE가_거절하면_두_번째_읽기로_대신하지_않는다(client, no_network, monkeypatch):
    monkeypatch.setenv("IE_DEADLINE_SECONDS", "35")
    no_network(registry_raw(), [GOOD])
    _with_second(monkeypatch, registry_raw())
    _failing_ie(monkeypatch, 400)
    resp = post_analyze(client, [dotted(PAGE_W, PAGE_H)])
    assert resp.status_code == 400


def test_IE_없이_판정한_리포트는_같은_사진_캐시에_남기지_않는다(client, no_network, monkeypatch):
    monkeypatch.setenv("IE_DEADLINE_SECONDS", "35")
    no_network(registry_raw(), [GOOD, GOOD])
    _with_second(monkeypatch, registry_raw())
    _failing_ie(monkeypatch, 503)
    photo = dotted(PAGE_W, PAGE_H)
    first = post_analyze(client, [photo]).json()["id"]
    second = post_analyze(client, [photo]).json()["id"]
    assert first != second, "같은 사진을 다시 보내면 IE로 다시 읽어야 한다(캐시 안 씀)"
