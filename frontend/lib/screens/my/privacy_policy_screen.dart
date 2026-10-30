/// 개인정보 처리방침 (앱 안, 쉬운 말, **사실만**) — 2026-10-22, P2-1.
///
/// 코드가 실제로 하는 일과 docs/NOW.md 6절 결정에 맞춘다. 정해지지 않은 값은 지어내지 않는다:
/// - 서버 지역([kServerRegion])·문의처([kPrivacyContact])는 config.dart 상수 — **비어 있으면 그 줄을 뺀다**.
/// - 사진을 이 폰에 남기는 문장은 [RegistryPhotoStore.retentionNotice] 한 곳을 그대로 쓴다(앱 전체가 같은 문장).
/// 내용을 바꿀 때는 코드(서버 `accounts.py`·`store.py`·`payments.py`, 앱 `registry_photo_store.dart`)와 같이 본다.
library;

import 'package:flutter/material.dart';

import '../../app/config.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/registry_photo_store.dart';

/// Upstage에 보낸 내용의 보관 — Upstage 이용약관(제22조) 기준 문장. 요금제에 따라 다르면 여기만 고친다.
const String kUpstageRetentionNote =
    'Upstage 이용약관에 따르면 유료 API는 보낸 내용을 저장하거나 AI 학습에 쓰지 않아요.';

/// 처리방침의 한 묶음(제목 + 줄들). 빈 줄은 빼고 그린다.
class PolicySection {
  const PolicySection(this.title, this.lines);

  final String title;
  final List<String> lines;
}

/// '사진 속 이름 가리기'(마이 → 설정)가 **실제로 가리는 범위** — 테스트가 문장을 함께 본다.
///
/// 2026-10-22: 사진의 이름·주민번호 칸(서버 `privacyMasks`)에 더해 **리포트 글자 속 사람 이름**(`personNames`)도 가린다.
/// 기본은 꺼짐 — 내 폰의 내 등기부에서는 실명을 계약 상대와 대조하는 것이 목적이다.
/// 2026-10-30: 마이에는 스위치만 두고 이 설명은 여기로 옮겼다(규혁: 설명이 너무 길다).
const String kHideNamesSwitchDescription =
    "'사진 속 이름 가리기'를 켜면 분석한 등기부 사진과 리포트 글자 속 사람 이름을 가려요(주민번호 칸 포함). "
    '회사·은행 이름은 그대로예요. 찍는 중이거나 분석 전인 사진은 아직 가리지 못해요.';

/// 화면에 그릴 내용 — 위젯 없이 테스트할 수 있게 함수로 뺐다. [serverRegion]·[contact]가 비면 그 줄이 없다.
List<PolicySection> privacyPolicySections({
  String serverRegion = kServerRegion,
  String contact = kPrivacyContact,
}) {
  final region = serverRegion.trim();
  final who = contact.trim();
  return [
    const PolicySection('받는 것', [
      '카카오 회원번호 — 카카오로 로그인할 때만 받아요. 원래 번호는 남기지 않고, 알아볼 수 없게 바꾼 값(암호화 값)으로만 보관해요.',
      '이름·이메일·닉네임·프로필 사진은 받지 않아요.',
      '기기 id — 앱을 처음 켤 때 만드는 무작위 번호예요. 내 기록을 다른 폰의 기록과 나누는 데만 써요.',
      '분석 기록 — 주소, 가린 이름(예: 홍○○), 분석 결과예요.',
      '계약 지킴이 패스 테스트 결제 기록 — 주문번호·금액·결제 수단·결제 시각이에요. 카드 번호는 받지 않아요.',
    ]),
    const PolicySection('등기부 사진', [
      RegistryPhotoStore.retentionNotice,
      '사진은 글자를 읽으려고 국내 AI(Upstage)에만 보내요. 다른 곳에는 보내지 않아요.',
      kUpstageRetentionNote,
      kHideNamesSwitchDescription,
    ]),
    const PolicySection('보관과 삭제', [
      '기록은 직접 지우거나 탈퇴하기 전까지 보관해요.',
      '기록을 지우면 서버에서 바로 지워요.',
      '회원 탈퇴하면 그 계정의 분석 기록·로그인 정보·계약 지킴이 패스를 서버에서 바로 모두 지워요.',
      '이 폰에 남은 사진과 계약 날짜는 앱을 지우면 함께 지워져요.',
    ]),
    PolicySection('맡기는 곳', [
      'Upstage — 등기부 글자 읽기와 쉬운 설명 만들기',
      'Railway — 서버 운영',
      if (region.isNotEmpty) '서버 지역 — $region',
      '카카오 — 로그인 확인(회원번호만)',
      '토스페이먼츠 — 계약 지킴이 패스 테스트 결제(실제 청구 없음)',
    ]),
    if (who.isNotEmpty) PolicySection('문의', [who]),
  ];
}

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sections = privacyPolicySections();
    return Scaffold(
      appBar: AppBar(title: const AppText('개인정보 처리방침')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          AppText(
            '전세AI프가 무엇을 받고, 어디에 두고, 언제 지우는지 적었어요. (2026년 10월 22일 기준)',
            style: AppTypography.body,
          ),
          const SizedBox(height: AppSpacing.lg),
          for (final section in sections) ...[
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(section.title, style: AppTypography.title),
                  const SizedBox(height: AppSpacing.sm),
                  for (final line in section.lines)
                    if (line.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AppText(
                              '·  ',
                              style: AppTypography.body.copyWith(
                                color: AppColors.textMuted,
                              ),
                            ),
                            Expanded(
                              child: AppText(line, style: AppTypography.body),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      ),
    );
  }
}
