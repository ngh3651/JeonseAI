/// 펼친 내용 안의 **칸** — 소제목 + 내용, 칸 사이 가는 줄 (2026-11-01 "하나의 앱" 통일).
///
/// 리포트 근거 카드 · 사진에서 보기 자세히 보기 · 중개사 질문이 **같은 모양**을 쓴다:
/// 둥근 네모 아이콘(26, 색 14% 바탕) + 굵은 소제목(17) + 오른쪽 작은 말(✦ AI가 읽었어요 / ✦ AI가 썼어요).
/// 색은 그 카드의 톤 하나(위험 빨강 · 확인 필요 주황 · 양호/대조 초록 · 따져볼 곳 주황).
library;

import 'package:flutter/material.dart';

import '../text/app_text.dart';
import '../tokens/app_typography_next.dart';

/// AI가 등기부에서 읽은 값 칸에 붙는 말
const String kAiReadNote = '✦ AI가 읽었어요';

/// AI가 쓴 글 칸에 붙는 말 — **모델이 실제로 썼을 때만** 붙인다(과대 표기 금지)
const String kAiWroteNote = '✦ AI가 썼어요';

/// 칸 이름 — 화면마다 같은 말을 쓴다
const String kSectionSeen = '이 집에서 본 것';
const String kSectionCore = '이 집 핵심';
const String kSectionPlan = '이 집 맞춤 할 일';

class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.note,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String? note;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 17, color: color),
      ),
      const SizedBox(width: 8),
      AppText(
        label,
        style: AppTypographyNext.bodyStrong.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          color: AppColorsNext.textStrong,
        ),
      ),
      if (note != null) ...[
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: AppText(
                note!,
                maxLines: 1,
                style: AppTypographyNext.caption.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

/// 칸 하나 — 소제목 + 12 띄우고 내용
class AppSection extends StatelessWidget {
  const AppSection({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.child,
    this.note,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      AppSectionHeader(icon: icon, label: label, color: color, note: note),
      const SizedBox(height: 12),
      child,
    ],
  );
}

/// 칸들을 세로로 — 첫 칸 위는 [firstTop]만, 그 뒤 칸마다 위에 가는 줄(20 · 줄 · 20).
class AppSectionList extends StatelessWidget {
  const AppSectionList({super.key, required this.children, this.firstTop = 0});

  final List<Widget> children;
  final double firstTop;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (int i = 0; i < children.length; i++)
        if (i == 0)
          Padding(padding: EdgeInsets.only(top: firstTop), child: children[i])
        else
          AppDivided(child: children[i]),
    ],
  );
}

/// 위에 가는 줄이 있는 덩어리 (20 · 줄 · 20)
class AppDivided extends StatelessWidget {
  const AppDivided({super.key, required this.child, this.gap = 20});

  final Widget child;
  final double gap;

  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(top: gap),
    padding: EdgeInsets.only(top: gap),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: AppColorsNext.divider)),
    ),
    child: child,
  );
}

/// AI 글 한 덩어리 — 문단마다 "**머리말** 본문"이면 머리말을 굵은 한 줄로 따로 세운다 (2026-11-01).
/// 머리말이 없는 문단(옛 리포트·준비된 문구)은 그냥 문단이다.
({String? lead, String body}) splitLeadParagraph(String paragraph) {
  final m = RegExp(r'^\*\*(.+?)\*\*\s*(.*)$', dotAll: true).firstMatch(paragraph.trim());
  if (m == null) return (lead: null, body: paragraph.trim());
  final lead = m.group(1)!.trim().replaceAll(RegExp(r'[.。]$'), '');
  return (lead: lead.isEmpty ? null : lead, body: m.group(2)!.trim());
}
