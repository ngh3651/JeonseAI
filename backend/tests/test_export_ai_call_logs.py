"""AI API 호출 로그 뽑기(`scripts/export_ai_call_logs.py`) — 키·네트워크 없이 기록·가리기·압축을 확인한다 (2026-10-23).

대회 「국내 AI API 호출 로그 제출 가이드」: 요청+응답을 한 건으로, 시각은 KST, 민감정보(키·헤더·개인정보)는 빼거나 가린다.
"""

from __future__ import annotations

import importlib.util
import json
import zipfile
from pathlib import Path

import pytest
import requests

from tests.test_analyze_smoke import (  # noqa: F401 — 픽스처(client, no_network)를 이 모듈에서도 쓴다
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page

_PATH = Path(__file__).resolve().parent.parent / "scripts" / "export_ai_call_logs.py"
_SPEC = importlib.util.spec_from_file_location("export_ai_call_logs", _PATH)
ail = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(ail)


class _Resp:
    status_code = 200
    text = ""

    def __init__(self, payload):
        self._payload = payload

    def json(self):
        return self._payload


def test_사진_데이터는_내용만_빼고_자리와_구조는_남긴다():
    payload = {
        "model": "information-extract",
        "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + "A" * 5000}}]}],
    }
    content, model = ail.describe_request({"json": payload})
    assert model == "information-extract"
    url = content["messages"][0]["content"][0]["image_url"]["url"]
    assert url.startswith("<등기부 사진 데이터 생략") and "A" * 100 not in url
    assert payload["messages"][0]["content"][0]["image_url"]["url"].startswith("data:")  # 원본은 그대로(실제 호출용)

    content, model = ail.describe_request({"files": {"document": ("page_1.jpg", b"\xff\xd8" * 300, "image/jpeg")}, "data": {"model": "ocr"}})
    assert model == "ocr"
    assert content["files"][0]["파일 이름"] == "page_1.jpg" and "600바이트" in content["files"][0]["내용"]


def test_헤더와_API_키는_기록에_없다():
    rec = ail.CallRecorder(lambda url, *a, **k: _Resp({"id": "r1", "model": "solar-pro2", "usage": {"total_tokens": 3}}))
    rec.start("용어 챗봇")
    rec.post(
        "https://api.upstage.ai/v1/solar/chat/completions",
        headers={"Authorization": "Bearer up_SECRET_KEY"},
        json={"model": "solar-pro2", "messages": [{"role": "user", "content": "근저당이 뭐예요?"}]},
    )
    rec.post("https://apis.data.go.kr/real-estate", headers={}, params={})  # 일반 API는 기록하지 않는다
    dumped = json.dumps(rec.records, ensure_ascii=False)
    assert "SECRET" not in dumped and "Authorization" not in dumped
    [record] = rec.records["용어 챗봇"]
    assert record["요청"]["엔드포인트"].startswith("https://api.upstage.ai/")
    assert record["요청"]["요청 모델"] == "solar-pro2"
    assert record["요청"]["요청 시각"].endswith("+09:00") and record["응답"]["응답 시각"].endswith("+09:00")
    assert record["응답"]["응답 본문"]["usage"]["total_tokens"] == 3


def test_이름_주민번호_주소를_가리고_기관은_그대로():
    patterns = ail.build_name_patterns({"홍길동", "주식회사하나은행"})
    text = "소유자 홍길동 750101-1234567 서울특별시 강남구 테헤란로 123\n근저당권자 주식회사하나은행 · 홍 길 동"
    masked = ail.mask_text(text, patterns)
    assert "홍길동" not in masked and "홍 길 동" not in masked and "홍○○" in masked
    assert "750101" not in masked and "******-*******" in masked
    assert "테헤란로" not in masked and "[주소 가림]" in masked
    assert "주식회사하나은행" in masked  # 기관 이름은 개인정보가 아니다
    assert ail.mask_text("강남구", patterns, word=True) == "○○○"  # OCR 낱말 하나
    assert ail.mask_text("(대치동)", patterns, word=True) == "○○○○"
    assert ail.mask_text("채권최고액", patterns, word=True) == "채권최고액"


def test_주민번호_앞의_이름도_찾아서_가린다():
    found: set[str] = set()
    ail.collect_names_near_rrn({"text": "전 소유자 김철수 800202-1******"}, found)
    assert "김철수" in found


def test_시각과_엔드포인트는_가리지_않는다():
    record = {
        "순번": 1,
        "기능명": "등기부등본 분석",
        "요청": {"요청 시각": "2026-10-23T01:02:03.004+09:00", "엔드포인트": "https://api.upstage.ai/v1/x", "요청 모델": "m", "요청 내용": "서울특별시 종로구 1-2"},
        "응답": {"응답 시각": "2026-10-23T01:02:04.005+09:00", "응답 본문": {"text": "홍길동"}},
    }
    out = ail.mask_record(record, ail.build_name_patterns({"홍길동"}))
    assert out["요청"]["요청 시각"] == "2026-10-23T01:02:03.004+09:00"
    assert out["응답"]["응답 시각"] == "2026-10-23T01:02:04.005+09:00"
    assert out["요청"]["요청 내용"] == "[주소 가림]" and out["응답"]["응답 본문"]["text"] == "홍○○"


def test_기능_네_개를_돌려_기능명_파일과_압축_하나를_만든다(client, no_network, monkeypatch, tmp_path):  # noqa: F811
    monkeypatch.setenv("ANALYSIS_CACHE_HOURS", "0")
    monkeypatch.setenv("CAPTURE_CHECK", "warn")
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 3)
    recorder = ail.CallRecorder(requests.post)  # 목(fake_post)을 감싼다
    monkeypatch.setattr(requests, "post", recorder.post)

    photo = tmp_path / "page_1.jpg"
    photo.write_bytes(blank_image(PAGE_W, PAGE_H))
    names = ["등기부등본 분석", "판례 근거 찾기", "다시 떼서 대조", "용어 챗봇"]
    result = ail.run_all(client, {"X-Device-Id": "ailog-test-0001"}, recorder, names, [photo], 120_000_000)
    assert {"홍길동", "김영희"} <= result["people"]

    out_dir, zip_path = tmp_path / "out" / "ai_call_logs", tmp_path / "out" / "logs.zip"
    summary = ail.write_outputs(recorder, names, result["people"], out_dir, zip_path)
    assert [s[0] for s in summary] == names
    counts = dict((s[0], s[1]) for s in summary)
    assert counts["등기부등본 분석"] >= 2 and counts["다시 떼서 대조"] >= 2  # IE + OCR (+ 설명)

    with zipfile.ZipFile(zip_path) as zf:
        assert sorted(zf.namelist()) == sorted(f"{n}.json" for n in names)
    for n in names:
        text = (out_dir / f"{n}.json").read_text(encoding="utf-8")
        assert "홍길동" not in text and "김영희" not in text, f"{n}에 실명이 남았다"
        assert "test-key" not in text
        for rec in json.loads(text):
            assert set(rec["요청"]) >= {"요청 시각", "엔드포인트", "요청 모델", "요청 내용"}
            assert set(rec["응답"]) >= {"응답 시각", "응답 본문"}


def test_응답_속_JSON_문자열은_풀어서_가리고_구조는_그대로():
    content = json.dumps(
        {"address": "서울특별시 서초구 서초동 1557-8", "current_owners": [{"name": "홍길동", "share": "1분의 1"}]},
        ensure_ascii=False,
    )
    masked = ail.mask_value({"choices": [{"message": {"content": content}}]}, ail.build_name_patterns({"홍길동"}))
    inner = json.loads(masked["choices"][0]["message"]["content"])
    assert inner["address"] == "[주소 가림]"
    assert inner["current_owners"] == [{"name": "홍○○", "share": "1분의 1"}]  # 키·순서·다른 값은 그대로
