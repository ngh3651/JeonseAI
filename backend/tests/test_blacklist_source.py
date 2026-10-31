"""악성임대인 공개 명단 (2026-10-31) — 받아 와서 이름을 가린 채로 두고, 집주인 이름과 맞춰 본다."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from app.schemas.internal import Grade, Owner
from app.services import blacklist_source as B
from app.services import rule_engine
from tests.test_compare import _extract

SALT = b"test-salt-1234567"


@pytest.fixture()
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(B, "store_path", lambda: tmp_path / B.STORE_FILE)
    monkeypatch.setattr(B, "status_path", lambda: tmp_path / B.STATUS_FILE)
    monkeypatch.setattr(B, "_salt", lambda: SALT)
    monkeypatch.setattr(B, "_cache", None)
    return tmp_path


def test_실명은_열쇠로만_남고_가린_이름과_출생연도():
    rows = [{"성명": "홍길동", "나이": "45", "채무액": "1,234,000,000"}, {"성명": "홍 길동", "나이": "45"}]
    out = B.to_entries(rows, salt=SALT, year=2026)
    assert len(out) == 1  # 공백만 다른 같은 사람·같은 나이는 하나로
    e = out[0]
    assert e["m"] == "홍○○" and e["by"] == 1981 and e["debt"] == 1_234_000_000
    assert "홍길동" not in json.dumps(out, ensure_ascii=False)


def test_감싼_모양이_달라도_줄을_찾는다():
    data = {"response": {"body": {"items": {"item": [{"lsrNm": "김철수", "age": 50}]}}}}
    assert B.find_rows(data) == [{"lsrNm": "김철수", "age": 50}]


def test_받아서_가린_채로_저장하고_매주_다시(data_dir, monkeypatch):
    monkeypatch.setenv("BLACKLIST_SOURCE_URL", "https://example.invalid/api")
    monkeypatch.setenv("BLACKLIST_API_KEY", "k")
    pages = {1: [{"성명": f"사람{i}", "나이": 40} for i in range(B.PAGE_SIZE)], 2: [{"성명": "홍길동", "나이": 45}]}
    calls = []

    def get(url, params=None, timeout=None):
        calls.append(params)
        return SimpleNamespace(text=json.dumps({"data": pages.get(params["pageNo"], [])}, ensure_ascii=False),
                               headers={"content-type": "application/json"}, raise_for_status=lambda: None)

    st = B.refresh(get=get, salt=SALT)
    assert st["ok"] and st["count"] == B.PAGE_SIZE + 1
    assert [c["pageNo"] for c in calls] == [1, 2] and calls[0]["serviceKey"] == "k"
    raw = (data_dir / B.STORE_FILE).read_text(encoding="utf-8")
    assert "홍길동" not in raw and "사람1" not in raw
    assert not B.due()  # 방금 받았다
    assert len(B.load()) == B.PAGE_SIZE + 1


def test_받기가_실패하면_전에_받은_명단_그대로(data_dir, monkeypatch):
    monkeypatch.setenv("BLACKLIST_SOURCE_URL", "https://example.invalid/api")
    (data_dir / B.STORE_FILE).write_text(
        json.dumps({"saltId": B.salt_id(SALT), "entries": [{"h": "x", "m": "김○○"}]}), encoding="utf-8")

    def boom(*a, **k):
        raise RuntimeError("down")

    st = B.refresh(get=boom, salt=SALT)
    assert not st["ok"] and len(B.load()) == 1


def test_못_받았으면_일주일을_기다리지_않고_다시_받는다(data_dir, monkeypatch):
    """2026-10-31 실사고 — 키 승인 전에 실패한 기록(오늘 날짜) 때문에 키를 넣고 다시 배포해도 일주일 동안 안 받았다."""
    monkeypatch.setenv("BLACKLIST_SOURCE_URL", "https://example.invalid/api")

    def boom(*a, **k):
        raise RuntimeError("down")

    assert B.refresh(get=boom, salt=SALT)["ok"] is False
    assert B.due()  # 다음 차례(서버 시작 3분 뒤·6시간마다)에 다시


def test_설정이_없으면_아무것도_안_한다(data_dir, monkeypatch):
    monkeypatch.delenv("BLACKLIST_SOURCE_URL", raising=False)
    assert not B.configured() and not B.due()
    assert B.refresh()["ok"] is False


def test_규칙엔진이_가린_명단으로_맞춰_본다(data_dir):
    entries = B.to_entries([{"성명": "김철수", "나이": 50}], salt=SALT, year=2026)
    ex = _extract(address="서울특별시 서초구 서초동 1 제3층 제301호")
    ex.current_owners = [Owner(name="김철수")]
    v = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=entries)
    bl = next(e for e in v.evidences if e.id == "blacklist")
    assert bl.grade is Grade.CAUTION and bl.facts["matched"] == ["김○○"]
    assert "—" not in bl.detail_text and "김철수" not in bl.detail_text
    # 다른 이름이면 '명단 N건과 맞춰봤어요'
    ex.current_owners = [Owner(name="이영희")]
    v = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=entries)
    bl = next(e for e in v.evidences if e.id == "blacklist")
    assert bl.grade is Grade.GOOD and bl.facts["list_size"] == 1


def test_서버가_받은_명단이_있으면_그것을_쓴다(data_dir):
    entries = B.to_entries([{"성명": "김철수"}], salt=SALT)
    (data_dir / B.STORE_FILE).write_text(json.dumps({"saltId": B.salt_id(SALT), "entries": entries}), encoding="utf-8")
    assert rule_engine.load_blacklist() == entries


def test_소금이_바뀌면_옛_명단은_대조_안_됨으로_보고_다시_받는다(data_dir, monkeypatch):
    """기록 DB를 새로 만들어 소금이 바뀌면 옛 열쇠는 다 빗나간다 — '같은 이름 없음(양호)'로 새지 않게 (규칙 감사 경고 6)."""
    monkeypatch.setenv("BLACKLIST_SOURCE_URL", "https://example.invalid/api")
    entries = B.to_entries([{"성명": "김철수"}], salt=b"old-salt-0000000")
    (data_dir / B.STORE_FILE).write_text(
        json.dumps({"saltId": B.salt_id(b"old-salt-0000000"), "entries": entries}), encoding="utf-8")
    (data_dir / B.STATUS_FILE).write_text(json.dumps({"checkedAt": "2099-01-01"}), encoding="utf-8")
    assert B.load() == [] and rule_engine.load_blacklist() == []
    assert B.due()  # 주간 갱신을 기다리지 않는다
    ex = _extract(address="서울특별시 서초구 서초동 1 제3층 제301호")
    ex.current_owners = [Owner(name="김철수")]
    v = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000)
    bl = next(e for e in v.evidences if e.id == "blacklist")
    assert bl.status_label == rule_engine.BLACKLIST_PENDING_LABEL


def _owner_report(card):
    from app.schemas.contract import Evidence, Highlight, HighlightBox
    from tests.test_ask_cards import _report

    mark = Highlight(id="owner-0", page=0, kind="owner", badge=1, box=HighlightBox(x=0.1, y=0.1, w=0.2, h=0.02),
                     title="지금 소유자", body="b", facts=["지금 소유자 1명"], plan=["보증금은 **이 이름의 계좌**로만 보내세요"])
    ev = [Evidence(id="blacklist", title="t", termSubtitle="s", easyExplanation="e", **card)] if card else []
    return _report(evidences=ev, highlights=[mark])


def test_사진에서_보기_소유자_표시에_명단_결과가_붙는다():
    from app.services import report_builder as RB

    r = _owner_report({"grade": "확인 필요", "statusLabel": "명단 일치 · 직접 확인 필요"})
    RB._add_blacklist_to_owner_mark(r)
    RB._add_blacklist_to_owner_mark(r)  # 다시 판정처럼 두 번 불려도 한 번만
    h = r.highlights[0]
    assert h.facts == ["지금 소유자 1명", "공개 명단에 같은 이름"]
    assert h.plan[0].startswith("**안심전세포털 악성임대인 명단**") and len(h.plan) == 2
    assert "○" not in " ".join(h.plan)  # 가린 이름도 넣지 않는다(사진에 이미 있다)

    r = _owner_report({"grade": "양호", "statusLabel": None})
    RB._add_blacklist_to_owner_mark(r)
    assert r.highlights[0].facts[-1] == "공개 명단에 같은 이름 없음" and len(r.highlights[0].plan) == 1

    # 명단을 아직 못 받았으면(카드 숨김) 아무것도 붙이지 않는다
    r = _owner_report({"grade": "확인 필요", "statusLabel": rule_engine.BLACKLIST_PENDING_LABEL})
    RB._add_blacklist_to_owner_mark(r)
    assert r.highlights[0].facts == ["지금 소유자 1명"]


def test_HUG_주소면_키_칸은_API_KEY_대문자_칸도_읽고_같은_쪽이면_멈춘다(data_dir, monkeypatch):
    """2026-10-31 실제 확인: https://www.khug.or.kr/defaultOnDebitList.do?API_KEY=… · 쪽 나눔 없음 · 대문자 칸."""
    monkeypatch.setenv("BLACKLIST_SOURCE_URL", B.HUG_ENDPOINT)
    monkeypatch.setenv("BLACKLIST_API_KEY", "k")
    monkeypatch.delenv("BLACKLIST_KEY_PARAM", raising=False)
    same = [{"LSR_NM": f"사람{i}", "AGE": "50"} for i in range(B.PAGE_SIZE)]
    calls = []

    def get(url, params=None, timeout=None):
        calls.append(params)
        return SimpleNamespace(text=json.dumps(same, ensure_ascii=False),
                               headers={"content-type": "application/json"}, raise_for_status=lambda: None)

    st = B.refresh(get=get, salt=SALT)
    assert st["ok"] and st["count"] == B.PAGE_SIZE
    assert calls[0]["API_KEY"] == "k" and "serviceKey" not in calls[0]
    assert len(calls) == 2  # 2쪽이 1쪽과 같아서 멈췄다(40번 부르지 않는다)
    raw = (data_dir / B.STORE_FILE).read_text(encoding="utf-8")
    assert "사람1" not in raw


def test_받는_곳이_오류를_주면_그_글을_남기고_전_명단_그대로(data_dir, monkeypatch):
    """HUG는 키가 만료되면 HTTP 200에 [{"ERROR_CODE", "ERROR_MSG": "EXPIRED API_KEY."}]를 준다(2026-10-31 실제 응답)."""
    monkeypatch.setenv("BLACKLIST_SOURCE_URL", B.HUG_ENDPOINT)
    monkeypatch.setenv("BLACKLIST_API_KEY", "OPEN")
    old = B.to_entries([{"성명": "김철수"}], salt=SALT)
    (data_dir / B.STORE_FILE).write_text(json.dumps({"saltId": B.salt_id(SALT), "entries": old}), encoding="utf-8")

    def get(url, params=None, timeout=None):
        return SimpleNamespace(text=json.dumps([{"ERROR_CODE": "E99", "ERROR_MSG": "EXPIRED API_KEY."}]),
                               headers={"content-type": "application/json"}, raise_for_status=lambda: None)

    st = B.refresh(get=get, salt=SALT)
    assert st["ok"] is False and st["note"] == "받는 곳 오류: EXPIRED API_KEY."
    assert B.load() == old


def test_공공데이터포털_방식이면_serviceKey():
    import os

    os.environ.pop("BLACKLIST_KEY_PARAM", None)
    assert B._key_param("https://apis.data.go.kr/x/y") == "serviceKey"
    assert B._key_param(B.HUG_ENDPOINT) == "API_KEY"
