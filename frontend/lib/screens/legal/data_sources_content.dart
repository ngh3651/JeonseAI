/// 데이터 출처 (2026-10-30) — 리포트가 무엇을 바탕으로 만들어지는지. 마이 → 데이터 출처.
///
/// 공공데이터는 출처를 밝혀 쓰는 조건(공공누리)으로 받는다. 값은 서버 `backend/data/price_sources.json`·
/// `auction_sale_rates.json`·`app/services/thresholds.py`의 출처 주석과 같아야 한다 — 지어내지 않는다.
library;

import 'package:flutter/material.dart';

import 'legal_doc.dart';
import 'privacy_content.dart' show kPrivacyEffectiveDate;

LegalDoc dataSourcesDoc() => const LegalDoc(
  title: '데이터 출처',
  effectiveDate: kPrivacyEffectiveDate,
  intro: '전세AI프 리포트는 공식 서류와 공공기관이 공개한 데이터를 바탕으로 만들어요.',
  highlights: [
    LegalHighlight(Icons.description_outlined, '등기부등본은 사용자가 올린 사진에서 읽어요'),
    LegalHighlight(Icons.account_balance_outlined, '시세·판례·경매 통계는 공공기관 자료예요'),
    LegalHighlight(Icons.rule_rounded, '위험 등급은 공개된 보증 기준으로 계산해요'),
  ],
  sections: [
    LegalSection('시세', [
      LegalRows([
        ('매매 실거래가', '국토교통부 실거래가 공개시스템\n공공데이터포털(data.go.kr) 아파트·연립다세대·오피스텔 매매 실거래가 자료'),
        ('공동주택 공시가격', '국토교통부 주택 공시가격 정보\n공공데이터포털(data.go.kr), 2026년 1월 1일 기준'),
        ('오피스텔 기준시가', '국세청 오피스텔 및 상업용 건물 기준시가'),
      ]),
    ]),
    LegalSection('판례와 경매 통계', [
      LegalRows([
        ('판례', '법제처 국가법령정보센터 판례 정보(Open API)'),
        ('경매 매각통계', '대법원 법원경매정보 용도별 매각통계\n2025년 11월부터 2026년 10월까지'),
      ]),
    ]),
    LegalSection('이용 조건', [
      LegalParagraph('공공 데이터는 각 기관이 정한 이용 조건(공공누리 등)에 따라 출처를 밝혀 써요.'),
    ]),
    LegalSection('위험 등급 기준', [
      LegalParagraph(
        '빚과 보증금이 집값에서 차지하는 비율은 주택도시보증공사(HUG) 전세보증금반환보증 가입 요건과 '
        '한국부동산원 공표 기준으로 봐요.',
      ),
      LegalParagraph('기준과 그 출처는 모두 기록해 두고, 출처가 없는 숫자는 쓰지 않아요.'),
    ]),
    LegalSection('AI', [
      LegalParagraph(
        '국내 AI 업스테이지(Upstage)의 Document OCR·Information Extract로 등기부 글자를 읽고, '
        'Solar Pro 2로 쉬운 설명과 챗봇 답을 써요.',
      ),
      LegalParagraph('위험 등급은 AI가 아니라 정해진 규칙이 계산해요. AI는 설명만 써요.'),
    ]),
    LegalSection('글꼴', [
      LegalRows([
        ('Pretendard', '길형진, SIL Open Font License 1.1'),
        ('주아체', '배달의민족(The Jua Project Authors), SIL Open Font License 1.1'),
      ]),
      LegalParagraph('라이선스 전문은 마이 → 오픈소스 라이선스에서 볼 수 있어요.'),
    ]),
  ],
);
