/// 컴포넌트 갤러리 — C-1 승인 포인트 ① 확인용 내부 화면.
///
/// 디자인 시스템의 모든 토큰·컴포넌트를 상태별로 나열한다.
/// 사용자 승인·팀 공유용 카탈로그이며, 제품 화면에서는 진입점이 없다 (라우트 직접 접근).
/// 표시된 수치·문구는 전부 **예시**다 — 실제 등급·수치는 E-1 규칙 엔진이 판정한다.
library;

import 'package:flutter/material.dart';

import '../../models/risk_grade.dart';
import '../components/app_bottom_nav.dart';
import '../components/app_button.dart';
import '../components/app_card.dart';
import '../components/chat_bubble.dart';
import '../components/mascot_safe.dart';
import '../components/risk_badge.dart';
import '../components/safety_gauge.dart';
import '../components/source_label.dart';
import '../components/term_tooltip_sheet.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import '../../design_system/text/app_text.dart';

class ComponentGalleryScreen extends StatelessWidget {
  const ComponentGalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const AppText('디자인 시스템 갤러리 (예시 데이터)')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          _section('색상 팔레트'),
          _colorRow('브랜드', const [
            ('primary', AppColors.primary),
            ('primaryDeep', AppColors.primaryDeep),
            ('primaryBright', AppColors.primaryBright),
            ('primarySoft', AppColors.primarySoft),
          ]),
          _colorRow('등급 (시맨틱)', const [
            ('위험', AppColors.danger),
            ('확인 필요', AppColors.caution),
            ('양호', AppColors.ok),
          ]),
          _section('타이포 (Pretendard)'),
          const AppText('결론 34 Bold', style: AppTypography.conclusion),
          const AppText('숫자 28 Bold — 3,200만원', style: AppTypography.numberLarge),
          const AppText('화면 제목 22', style: AppTypography.headline),
          const AppText('카드 제목 17', style: AppTypography.title),
          const AppText('본문 15 — 등기부등본을 쉽게 읽어드려요.', style: AppTypography.body),
          const AppText(
            '캡션 13 — 출처: HUG 전세보증 기준 (예시)',
            style: AppTypography.caption,
          ),

          _section('버튼'),
          AppPrimaryButton(
            label: '매물 분석 시작하기',
            icon: Icons.search,
            onPressed: () {},
          ),
          const SizedBox(height: AppSpacing.md),
          AppSecondaryButton(label: '등기부등본이 없어요', onPressed: () {}),
          const SizedBox(height: AppSpacing.md),
          const AppPrimaryButton(
            label: '로딩 상태',
            onPressed: null,
            loading: true,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              AppCompactButton(
                label: '재분석',
                icon: Icons.refresh,
                onPressed: () {},
              ),
              const SizedBox(width: AppSpacing.sm),
              AppCompactButton(label: '시세 입력하기', onPressed: () {}),
            ],
          ),

          _section('위험도 뱃지'),
          const Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              RiskBadge(grade: RiskGrade.danger),
              RiskBadge(grade: RiskGrade.caution),
              RiskBadge(grade: RiskGrade.ok),
              RiskBadge(grade: RiskGrade.caution, labelOverride: '페이지 누락'),
              RiskBadge(grade: RiskGrade.danger, large: true),
            ],
          ),

          _section('안전도 게이지 (진행률·등급 = 예시)'),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              SafetyGauge(grade: RiskGrade.danger, progress: 0.25, size: 100),
              SafetyGauge(grade: RiskGrade.caution, progress: 0.55, size: 100),
              SafetyGauge(
                grade: RiskGrade.ok,
                progress: 0.85,
                size: 100,
                caption: '예시',
              ),
            ],
          ),

          _section('근거 카드 (접힘 → 탭하면 펼침)'),
          const EvidenceCard(
            title: '나보다 먼저 돈 받아갈 빚이 있나요?',
            termSubtitle: '선순위 채권 · 근저당 (예시 데이터)',
            grade: RiskGrade.danger,
            easyExplanation:
                '이 집에는 은행에 갚아야 할 빚이 이미 잡혀 있어요. 집이 경매로 넘어가면 '
                '은행이 먼저 돈을 받아가고, 남는 금액에서 보증금을 돌려받게 돼요.',
            detailText: '근저당권 2건 · 채권최고액 합계 1억 8,000만원 (예시)',
            sourceText: '출처 슬롯 — E-1 확정',
            initiallyExpanded: true,
          ),
          const SizedBox(height: AppSpacing.md),
          EvidenceCard(
            title: '보증금이 집값에 비해 높지 않나요?',
            termSubtitle: '전세가율 (예시 데이터)',
            grade: RiskGrade.caution,
            statusLabel: '확인 필요',
            easyExplanation: '시세를 입력하지 않아 아직 계산할 수 없어요. 시세를 입력하면 바로 알려드릴게요.',
            action: AppCompactButton(label: '시세 입력하기', onPressed: () {}),
          ),

          _section('판정/설명 구분 라벨 (가드레일 가시화)'),
          const VerdictSourceLabel(verdictSource: 'HUG 기준 · 예시'),

          _section('용어 툴팁 (문장 속 인라인 — 탭해 보세요)'),
          AppText.rich(
            TextSpan(
              style: AppTypography.body,
              children: [
                const TextSpan(text: '이 집에는 '),
                termSpan(
                  context,
                  term: '근저당권',
                  description:
                      '집주인이 집을 담보로 돈을 빌렸다는 표시예요. 집이 경매로 넘어가면 '
                      '돈을 빌려준 쪽(주로 은행)이 세입자보다 먼저 돈을 받아갈 수 있어요.',
                  onAskChatbot: () {},
                ),
                const TextSpan(text: '이 설정되어 있어요. 밑줄 용어를 탭하면 쉬운 설명이 열려요.'),
              ],
            ),
          ),

          _section('챗 말풍선'),
          const ChatBubble(text: '신탁등기가 뭐예요?', isUser: true),
          const SizedBox(height: AppSpacing.md),
          const ChatBubble(
            text:
                '신탁등기는 집의 관리 권한을 신탁회사에 맡겼다는 표시예요. '
                '이 경우 집주인 마음대로 전세 계약을 맺지 못할 수 있어요.',
            isUser: false,
          ),
          const SizedBox(height: AppSpacing.md),
          ChatBubble(
            text:
                '저는 용어를 쉽게 설명해 드리는 챗봇이에요. '
                '매물의 위험 판단은 규칙 기반 안전도 리포트가 맡고 있어요.',
            isUser: false,
            action: AppCompactButton(label: '매물 분석하러 가기', onPressed: () {}),
          ),

          _section('마스코트 세이프 (상태별)'),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: [
              for (final s in MascotState.values)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MascotSafe(size: 72, state: s),
                    AppText(s.name, style: AppTypography.caption),
                  ],
                ),
            ],
          ),

          _section('기본 카드'),
          AppCard(
            onTap: () {},
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText('역삼동 오피스텔', style: AppTypography.title),
                      SizedBox(height: AppSpacing.xs),
                      AppText(
                        '2026.06.26 분석 · 근저당 2건 (예시)',
                        style: AppTypography.caption,
                      ),
                    ],
                  ),
                ),
                const RiskBadge(grade: RiskGrade.danger),
              ],
            ),
          ),
          const SizedBox(height: 120),
        ],
      ),
      bottomNavigationBar: AppBottomNav(
        currentIndex: 0,
        onTabSelected: (_) {},
        onAnalyzePressed: () {},
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.xxxl,
        bottom: AppSpacing.md,
      ),
      child: AppText(title, style: AppTypography.headline),
    );
  }

  Widget _colorRow(String label, List<(String, Color)> colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(label, style: AppTypography.caption),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (final (name, color) in colors)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: Column(
                      children: [
                        Container(
                          height: 44,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            border: Border.all(color: AppColors.line),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        AppText(
                          name,
                          style: AppTypography.label.copyWith(
                            color: AppColors.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
