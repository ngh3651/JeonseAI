/// 이용약관 (2026-10-30 · 같은 날 법 조사 반영) — 시작 시트 · 시작 화면 · 마이에서 연다.
///
/// 쓰는 원칙: 쉬운 존댓말, 짧은 문장, 서비스의 강점은 그대로 · 한계는 '어떻게 쓰면 좋은지'로.
/// - 책임 조항은 약관규제법 제7조를 넘지 않는다 — 운영자의 고의·중대한 과실 책임은 빼지 않는다.
/// - 생성형 AI를 쓴다는 사실을 약관에 미리 알린다(인공지능 기본법 제31조, 2026-01-22 시행).
/// - 리포트는 법률 자문·중개·감정평가가 아니다(변호사법 제109조 · 공인중개사법 제2조) — 마지막 항목으로, 강점 뒤에.
/// - 약관을 바꿀 때는 7일 전, 불리하면 30일 전에 알린다(업계 약관 관행).
library;

import 'package:flutter/material.dart';

import '../../app/config.dart';
import 'legal_doc.dart';
import 'privacy_content.dart' show kPrivacyEffectiveDate;

LegalDoc termsDoc({String contact = kPrivacyContact}) => LegalDoc(
  title: '이용약관',
  effectiveDate: kPrivacyEffectiveDate,
  contact: contact.trim().isEmpty ? null : contact.trim(),
  intro: '전세AI프를 쓰는 데 필요한 약속을 쉬운 말로 적었어요.',
  highlights: const [
    LegalHighlight(Icons.insights_outlined, '등기부를 분석해 위험 신호와 근거를 보여 드려요'),
    LegalHighlight(Icons.rule_rounded, '위험 등급은 공개된 기준을 옮긴 규칙이 정해요'),
    LegalHighlight(Icons.savings_outlined, '지금은 모든 기능이 무료예요'),
  ],
  sections: const [
    LegalSection('이 약관은', [
      LegalParagraph(
        '전세AI프(이하 서비스)를 쓰는 조건과 절차, 이용자와 운영자인 팀 동크크(이하 운영자)의 권리와 책임을 정해요.',
      ),
      LegalParagraph('시작 화면에서 이 약관에 동의하면 이용 계약이 맺어져요. 만 14세 이상만 쓸 수 있어요.'),
    ]),
    LegalSection('서비스가 하는 일', [
      LegalBullets([
        '등기부등본 사진을 읽어 깡통전세와 전세사기 위험 신호를 찾고, 등급과 근거를 보여 드려요.',
        '경매로 넘어가면 보증금을 얼마나 돌려받을 수 있는지 계산해요.',
        '이 집과 비슷한 판례, 중개사에게 물어볼 질문을 골라 드려요.',
        '계약 일정 알림과 다시 뗀 등기부 대조로 입주 다음 날까지 함께해요.',
        '어려운 부동산 용어는 챗봇이 풀어 드려요.',
      ]),
    ]),
    LegalSection('AI를 쓰는 방식', [
      LegalParagraph('이 서비스는 생성형 AI를 써요. 등기부 글자 읽기, 쉬운 설명, 챗봇 답은 국내 AI 업스테이지(Upstage)가 만들어요.'),
      LegalParagraph('리포트에서 AI가 맡은 부분에는 ✦ AI 표시를 붙여요. 위험 등급은 AI가 아니라 공개된 기준을 옮긴 규칙이 정해요.'),
    ]),
    LegalSection('리포트를 볼 때', [
      LegalBullets([
        '리포트는 등기부와 공공 데이터를 근거로, 계약 전에 꼭 확인할 점을 짚어 드려요.',
        "정보가 부족하면 '양호' 대신 '확인 필요'로 알려 드려요. 위험을 놓치지 않는 쪽을 택했어요.",
        '리포트는 올린 등기부를 뗀 날이 기준이에요. 잔금을 보내기 전에는 새로 뗀 등기부로 다시 대조해 주세요. 계약 여정에서 바로 할 수 있어요.',
        '세금 체납이나 먼저 들어온 세입자처럼 등기부에 없는 정보는, 중개사에게 물어볼 질문으로 챙겨 드려요.',
      ]),
      LegalParagraph(
        '리포트는 계약 판단을 돕는 참고 자료로, 법률 자문이나 부동산 중개, 감정평가를 대신하지 않아요. '
        '계약은 이용자가 정해요. 구체적인 분쟁은 변호사나 대한법률구조공단(132)과 상담해 주세요.',
      ),
    ]),
    LegalSection('이용자가 지켜 주실 것', [
      LegalBullets([
        '계약을 확인하려는 집의 등기부만 올려 주세요.',
        '리포트 속 다른 사람의 정보는 계약을 확인하는 데만 쓰고, 퍼뜨리지 말아 주세요.',
        '자동 프로그램으로 대량 요청을 보내거나, 앱을 임의로 고쳐 쓰지 말아 주세요.',
        '다른 사람의 휴대폰이나 계정으로 이용하지 말아 주세요.',
      ]),
      LegalParagraph('지키지 않으면 이용을 제한할 수 있어요.'),
    ]),
    LegalSection('계정과 기록', [
      LegalParagraph('로그인하지 않아도 모든 기능을 쓸 수 있어요. 이때 기록은 이 휴대폰에 묶여요.'),
      LegalParagraph('카카오로 로그인하면 기록이 계정에 남아 휴대폰을 바꿔도 이어서 볼 수 있어요.'),
      LegalParagraph('기록은 마이에서 언제든 지울 수 있고, 회원 탈퇴하면 모두 지워져요.'),
    ]),
    LegalSection('요금', [
      LegalParagraph('지금은 모든 기능을 무료로 쓸 수 있어요.'),
      LegalParagraph('계약 지킴이 패스 결제는 시험용 결제라 실제로 돈이 나가지 않아요.'),
      LegalParagraph('유료로 바꿀 때는 가격과 환불 조건을 미리 알리고, 동의한 분께만 받아요.'),
    ]),
    LegalSection('서비스 변경과 중단', [
      LegalParagraph('더 나은 서비스를 위해 기능을 바꿀 수 있어요. 중요한 변경은 앱에서 미리 알려요.'),
      LegalParagraph('점검이나 장애가 있으면 잠시 멈출 수 있어요.'),
    ]),
    LegalSection('책임', [
      LegalParagraph('운영자는 공개된 기준을 따르고 근거를 함께 보여 드려, 리포트가 정확하도록 힘써요.'),
      LegalParagraph('운영자의 고의나 중대한 과실로 손해가 생기면 법에 따라 책임져요.'),
      LegalParagraph(
        '운영자에게 고의나 과실이 없다면, 흐리거나 빠진 사진, 잘못 입력한 금액, 등기부를 뗀 뒤 바뀐 권리관계, '
        '공공기관 자료의 오류나 지연처럼 운영자가 알 수 없거나 막을 수 없는 원인으로 생긴 손해는 책임지지 않아요.',
      ),
    ]),
    LegalSection('권리', [
      LegalParagraph('이용자가 올린 사진과 입력한 내용은 이용자의 것이에요. 운영자는 서비스를 제공하는 데만 써요.'),
      LegalParagraph('앱의 디자인과 마스코트 세이프, 앱에 쓴 글과 그림의 권리는 팀 동크크에 있어요.'),
      LegalParagraph('공공 데이터와 판례는 각 기관의 이용 조건을 따라요. 마이 → 데이터 출처에서 볼 수 있어요.'),
    ]),
    LegalSection('개인정보', [
      LegalParagraph('개인정보는 개인정보 처리방침에 따라 다뤄요.'),
    ]),
    LegalSection('약관이 바뀔 때', [
      LegalParagraph('약관을 바꾸면 적용하기 7일 전에 앱에서 알려 드려요. 이용자에게 불리하게 바뀌면 30일 전에 알려 드려요.'),
      LegalParagraph('바뀐 약관에 동의하지 않으면 언제든 탈퇴할 수 있어요.'),
    ]),
    LegalSection('분쟁', [
      LegalParagraph(
        '문제가 생기면 먼저 아래 메일로 알려 주세요. 그래도 풀리지 않으면 대한민국 법에 따라 관할 법원에서 해결해요.',
      ),
    ]),
  ],
);
