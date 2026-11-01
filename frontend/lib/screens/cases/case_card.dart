/// 판례 매칭 화면 부품 (2026-10-24 디자인 확정안 — 규칙 문서 §2~§7, 시안 ①~④).
///
/// - [CaseRiskBox]  위쪽 "이 매물에서 눈에 띈 위험" 2칸 표
/// - [CaseCard]     판례 카드 (접기·펴기 · 결과 형광펜 · 출처 ↗ · 말풍선 2개)
/// - [CaseEmptyBox] 판례 0건
/// - [showCaseTermSheet] "어려운 말 풀이" 시트
///
/// 글자·색은 **새 체계(시범)** `AppTypographyNext`·`AppColorsNext`만 쓴다 — 이 화면에서 먼저 써 보고
/// 괜찮으면 앱 전체로 옮긴다.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/content_models.dart';

/// 위험 태그(백엔드 `RISK_TAGS` 어휘) → 화면 라벨.
///
/// **위쪽 위험 표와 판례 카드 태그가 같은 표를 쓴다.** 둘이 다른 말로 나오면 "이 판례가 위 위험 중
/// 무엇에 대한 것인지"를 사용자가 머릿속에서 번역해야 한다.
/// 표에 없는 태그(압류·가압류, 경매, 임차권등기, 대항력)는 **법률 용어 그대로** 둔다 — 검수받지 않은
/// 쉬운 말을 여기서 지어내지 않는다.
const Map<String, String> kRiskTagLabel = {
  '선순위 채권': '먼저 갚을 빚',
  '신탁등기': '소유권을 맡긴 집',
  '전세가율': '보증금 비율',
  '보증보험': '보증보험',
};

String riskTagLabel(String tag) => kRiskTagLabel[tag] ?? tag;

/// 카드 한 장에 붙일 태그 최대 개수 — 태그 줄이 길어지면 "한눈에"가 깨진다.
const int kMaxCardTags = 3;

// ── 크기 (디자인 규칙 문서 값) ─────────────────────────────────────────────
const double _kBoxRadius = 24;
const double _kBoxPadding = 20;
const double _kMinTouch = 48; // 안드로이드 최소 터치 48dp (디자인 리뷰 2026-10-24)
const double _kCommonMaxWidth = 250;
const double _kAdviceMaxWidth = 270;

// ════════════════════════════════════════════════════════════════════════
// 위쪽 — 이 매물에서 눈에 띈 위험
// ════════════════════════════════════════════════════════════════════════

/// 흰 상자 안 제목 + 빨간 개수, 그 아래 **2칸 구분선 표**(칸 높이 48 이상, 연한 선으로 나눔).
/// 개수가 홀수면 마지막 칸은 비운다. 이름이 길면 칸 안에서 두 줄로 넘긴다.
class CaseRiskBox extends StatelessWidget {
  const CaseRiskBox({super.key, required this.labels});

  /// 화면 라벨(이미 [riskTagLabel]을 거친 쉬운 말)
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (int i = 0; i < labels.length; i += 2) {
      if (i > 0) {
        rows.add(Divider(height: 1, thickness: 1, color: AppColorsNext.divider));
      }
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _RiskCell(label: labels[i], left: true)),
              VerticalDivider(width: 1, thickness: 1, color: AppColorsNext.divider),
              Expanded(
                child: i + 1 < labels.length
                    ? _RiskCell(label: labels[i + 1], left: false)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }

    return _WhiteBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.rich(
            TextSpan(
              style: AppTypographyNext.title,
              children: [
                const TextSpan(text: '이 매물에서 눈에 띈 위험'),
                if (labels.isNotEmpty)
                  TextSpan(
                    text: '  ${labels.length}',
                    style: AppTypographyNext.title.copyWith(color: AppColorsNext.dangerText),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (labels.isEmpty)
            // '위험 없음'으로 읽히지 않게 — 판례와 맞춰 볼 패턴이 없다는 뜻만 (보수적 편향, 디자인 리뷰 2026-10-24)
            AppText('판례와 맞춰 볼 위험 패턴이 없어요 · 리포트 결과를 함께 확인하세요', style: AppTypographyNext.caption)
          else
            ...rows,
        ],
      ),
    );
  }
}

class _RiskCell extends StatelessWidget {
  const _RiskCell({required this.label, required this.left});

  final String label;
  final bool left;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: EdgeInsets.only(left: left ? 0 : 16, right: left ? 12 : 0, top: 10, bottom: 10),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: AppColorsNext.dangerText),
            const SizedBox(width: 8),
            Expanded(
              child: AppText(
                label,
                maxLines: 2,
                style: AppTypographyNext.bodyStrong.copyWith(
                  fontSize: 16,
                  height: 22 / 16,
                  color: AppColorsNext.textStrong,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 판례 0건
// ════════════════════════════════════════════════════════════════════════

/// 카드 대신 흰 상자: 돋보기 + "이 매물의 위험과 딱 맞는 / 판례가 아직 없어요".
/// ("위험이 없다는 뜻은 아니다"는 위쪽 위험 표가 이미 말한다 — 안내 문장은 넣지 않는다.)
class CaseEmptyBox extends StatelessWidget {
  const CaseEmptyBox({super.key});

  @override
  Widget build(BuildContext context) {
    return _WhiteBox(
      padding: const EdgeInsets.symmetric(horizontal: _kBoxPadding, vertical: 28),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: AppColors.background, shape: BoxShape.circle),
            child: Icon(Icons.search, size: 28, color: AppColors.caution),
          ),
          const SizedBox(height: 16),
          AppText(
            '이 매물의 위험과 딱 맞는\n판례가 아직 없어요',
            textAlign: TextAlign.center,
            style: AppTypographyNext.title,
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 판례 카드
// ════════════════════════════════════════════════════════════════════════

/// 판례 카드 한 장.
///
/// - 접힘: 태그 → 결과 문장 → [🏛 사건번호 ↗ | 펼치기 ⌄]
/// - 펼침: 태그 → 결과 문장 → 요약 → [🏛 사건번호 ↗ | 접기 ⌃] → 연한 선 → 말풍선 2개
/// - 말풍선: '우리 매물과 공통점'(처음 닫힘·왼쪽·노랑) · '이런 피해를 피하려면'(처음 열림·오른쪽·초록, 없으면 숨김)
class CaseCard extends StatefulWidget {
  const CaseCard({super.key, required this.match, this.initiallyExpanded = false});

  final CaseMatch match;
  final bool initiallyExpanded;

  @override
  State<CaseCard> createState() => _CaseCardState();
}

/// 펼침 상태를 스크롤해도 기억한다 — 목록 밖으로 나갔다 오면 카드가 새로 만들어져 닫혀 버렸다(2026-10-24 실기기).
class _CaseCardState extends State<CaseCard> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late bool _expanded = widget.initiallyExpanded;
  bool _commonOpen = false;
  // 2026-10-24 규혁: 판례 화면은 전부 닫힌 채로 시작 — 카드도, 말풍선 둘도
  bool _adviceOpen = false;

  CaseMatch get c => widget.match;

  Future<void> _openSource() async {
    final url = c.sourceUrl;
    if (url == null || url.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    bool ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: AppText('판결문을 열지 못했어요. 잠시 후 다시 눌러 주세요')));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep-alive 등록
    final tags = c.displayTags.take(kMaxCardTags).toList();
    final hasAdvice = c.advice != null && c.advice!.trim().isNotEmpty;

    return _WhiteBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final t in tags) _CaseTag(label: riskTagLabel(t))],
          ),
          const SizedBox(height: 14),
          // 결과 문장 — 고정 문구(AI가 쓰지 않음). 강조 부분은 빨간 형광펜
          AppText.rich(
            _highlightedResult(c.result, c.emphasis['result'] ?? const []),
          ),
          if (_expanded) ...[
            const SizedBox(height: 12),
            AppText.rich(
              caseRichText(
                context,
                text: c.summary,
                base: AppTypographyNext.body,
                glossary: c.termGlossary,
                emphasis: c.emphasis['summary'] ?? const [],
              ),
            ),
          ],
          const SizedBox(height: 4),
          _sourceRow(),
          if (_expanded) ...[
            Divider(height: 17, thickness: 1, color: AppColorsNext.divider),
            _BubbleHeader(
              label: '우리 매물과 공통점',
              icon: Icons.home_outlined,
              color: AppColors.caution,
              open: _commonOpen,
              alignEnd: false,
              onTap: () => setState(() => _commonOpen = !_commonOpen),
            ),
            if (_commonOpen)
              _Bubble(
                alignEnd: false,
                maxWidth: _kCommonMaxWidth,
                background: AppColorsNext.sameSoft,
                child: AppText.rich(
                  caseRichText(
                    context,
                    text: c.commonPoint,
                    base: AppTypographyNext.body,
                    emphasis: c.emphasis['commonPoint'] ?? const [],
                  ),
                ),
              ),
            if (hasAdvice) ...[
              const SizedBox(height: 8),
              _BubbleHeader(
                label: '이런 피해를 피하려면',
                icon: Icons.verified_user_outlined,
                color: AppColors.primary,
                open: _adviceOpen,
                alignEnd: true,
                onTap: () => setState(() => _adviceOpen = !_adviceOpen),
              ),
              if (_adviceOpen)
                _Bubble(
                  alignEnd: true,
                  maxWidth: _kAdviceMaxWidth,
                  background: AppColors.primarySoft,
                  child: AppText.rich(
                    caseRichText(
                      context,
                      text: c.advice!,
                      base: AppTypographyNext.body,
                      emphasis: c.emphasis['advice'] ?? const [],
                    ),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }

  /// [🏛 대법원 83다카116 ↗ | 펼치기 ⌄ / 접기 ⌃] — 사건번호를 누르면 판결문 원문(외부 브라우저)
  Widget _sourceRow() {
    final hasUrl = c.sourceUrl != null && c.sourceUrl!.isNotEmpty;
    final source = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.account_balance_outlined, size: 18, color: AppColorsNext.textMuted),
        const SizedBox(width: 6),
        Flexible(
          child: AppText(
            c.caseNo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypographyNext.caption,
          ),
        ),
        if (hasUrl) ...[
          const SizedBox(width: 6),
          Icon(Icons.north_east, size: 18, color: AppColors.primary),
        ],
      ],
    );

    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: hasUrl
                ? Semantics(
                    link: true,
                    label: '${c.caseNo} 판결문 원문 열기',
                    child: InkWell(
                      onTap: _openSource,
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: _kMinTouch),
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Align(alignment: Alignment.centerLeft, widthFactor: 1, child: source),
                        ),
                      ),
                    ),
                  )
                : ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: _kMinTouch),
                    child: Align(alignment: Alignment.centerLeft, widthFactor: 1, child: source),
                  ),
          ),
        ),
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _kMinTouch),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppText(
                    _expanded ? '접기' : '펼치기',
                    style: AppTypographyNext.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: _expanded ? AppColorsNext.textBody : AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 22,
                    color: _expanded ? AppColorsNext.textBody : AppColors.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 카드 태그 — 연분홍 알약 (바탕 #FBEAE8 · 글씨 #C62828 · 15 굵기 600 · 높이 30)
class _CaseTag extends StatelessWidget {
  const _CaseTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AppText(
        label,
        style: AppTypographyNext.caption.copyWith(
          fontWeight: FontWeight.w600,
          color: AppColorsNext.dangerText,
        ),
      ),
    );
  }
}

/// 말풍선 이름 줄 — 아이콘 원 + 이름(15 굵게) + 화살표. 눌러서 열고 닫는다(닫히면 이름 줄만).
class _BubbleHeader extends StatelessWidget {
  const _BubbleHeader({
    required this.label,
    required this.icon,
    required this.color,
    required this.open,
    required this.alignEnd,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool open;
  final bool alignEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final circle = Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(icon, size: 16, color: AppColors.onPrimary),
    );
    final text = AppText(
      label,
      style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w700, color: color),
    );
    final chevron = Icon(
      open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
      size: 22,
      color: color,
    );
    // 글자를 크게 키운 폰에서 이름이 폭을 넘으면 줄을 바꾼다(넘쳐서 잘리지 않게) — Flexible
    final name = Flexible(child: text);
    final children = alignEnd
        ? [chevron, const SizedBox(width: 4), name, const SizedBox(width: 8), circle]
        : [circle, const SizedBox(width: 8), name, const SizedBox(width: 4), chevron];

    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: Semantics(
        button: true,
        expanded: open,
        label: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _kMinTouch),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

/// 말풍선 몸통 — 왼쪽(공통점)은 왼쪽 위 모서리만 6, 오른쪽(피하려면)은 오른쪽 위만 6, 나머지 20.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.alignEnd,
    required this.maxWidth,
    required this.background,
    required this.child,
  });

  final bool alignEnd;
  final double maxWidth;
  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const big = Radius.circular(20);
    const small = Radius.circular(6);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.only(
                topLeft: alignEnd ? big : small,
                topRight: alignEnd ? small : big,
                bottomLeft: big,
                bottomRight: big,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 흰 상자 (모서리 24 · 안쪽 20)
class _WhiteBox extends StatelessWidget {
  const _WhiteBox({required this.child, this.padding = const EdgeInsets.all(_kBoxPadding)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(_kBoxRadius),
      ),
      child: child,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 글자 조립 — 결과 형광펜 · 굵게(**…**·emphasis) · 용어 연결
// ════════════════════════════════════════════════════════════════════════

/// 결과 문장 — 강조 구절만 **빨간 형광펜**(글씨 #C62828 · 굵게 · 글자 아래 40%에 연빨강 띠).
///
/// 구절은 어절마다 따로 칠한다 — 한 덩어리로 묶으면 긴 구절이 줄 끝에서 넘치기 때문이다.
InlineSpan _highlightedResult(String text, List<String> phrases) {
  final base = AppTypographyNext.title;
  final mark = _markRanges(text, phrases);
  final children = <InlineSpan>[];
  int i = 0;
  while (i < text.length) {
    final on = mark[i];
    int j = i;
    while (j < text.length && mark[j] == on) {
      j++;
    }
    final part = text.substring(i, j);
    if (!on) {
      children.add(TextSpan(text: part));
    } else {
      // 앞쪽 띄어쓰기는 띠 없이
      final lead = RegExp(r'^\s+').firstMatch(part)?.group(0) ?? '';
      if (lead.isNotEmpty) children.add(TextSpan(text: lead));
      // 어절(뒤 띄어쓰기 포함)마다 하나씩 — 띠가 띄어쓰기까지 이어져 보이고, 줄 끝에서 넘치지 않는다
      for (final m in RegExp(r'\S+\s*').allMatches(part)) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _Highlighter(text: m.group(0)!, base: base),
          ),
        );
      }
    }
    i = j;
  }
  return TextSpan(style: base, children: children);
}

class _Highlighter extends StatelessWidget {
  const _Highlighter({required this.text, required this.base});

  final String text;
  final TextStyle base;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 띠: 글자 상자 아래쪽 40%
        Positioned.fill(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: 0.4,
              widthFactor: 1,
              child: ColoredBox(color: AppColors.dangerSoft),
            ),
          ),
        ),
        AppText(
          text,
          style: base.copyWith(
            color: AppColorsNext.dangerText,
            fontWeight: FontWeight.w800,
            height: 1.25,
          ),
        ),
      ],
    );
  }
}

/// 굵게 칠할 글자 자리 — 서버 emphasis 구절 + 글 속 `**…**` 표시(AI가 쓴 굵게).
List<bool> _markRanges(String text, List<String> phrases) {
  final mark = List<bool>.filled(text.length, false);
  for (final p in phrases) {
    if (p.isEmpty) continue;
    final at = text.indexOf(p);
    if (at < 0) continue;
    for (int k = at; k < at + p.length; k++) {
      mark[k] = true;
    }
  }
  return mark;
}

/// `**굵게**` 표시를 떼어 낸 글과, 굵게였던 구절 목록.
({String text, List<String> bold}) stripBoldMarkers(String raw) {
  final bold = <String>[];
  final text = raw.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) {
    bold.add(m.group(1)!);
    return m.group(1)!;
  });
  return (text: text, bold: bold);
}

/// 판례 카드 본문 한 칸 — 굵게(서버 emphasis + `**…**`)와 용어 연결을 **한 번에** 조립한다.
///
/// [glossary]가 비어 있으면 용어를 연결하지 않는다 — 말풍선(공통점·피하려면)은 연결 없이 일반 글자다(규칙 §2).
/// 용어는 굵게 칠하지 않는다.
InlineSpan caseRichText(
  BuildContext context, {
  required String text,
  required TextStyle base,
  Map<String, String> glossary = const {},
  List<String> emphasis = const [],
  Set<String>? seenTerms,
}) {
  // 용어 밑줄은 **한 글 안에서 처음 한 번만** (2026-11-01 규혁 — "모든 글자에 형광펜 친 느낌").
  // 여러 문단·줄이 한 글이면 부르는 쪽이 같은 [seenTerms]를 넘긴다. 이미 그은 용어는 평범한 글자로 지나간다.
  final seen = seenTerms ?? <String>{};
  final stripped = stripBoldMarkers(text);
  final body = stripped.text;
  final bold = _markRanges(body, [...emphasis, ...stripped.bold]);
  final boldStyle = base.copyWith(fontWeight: FontWeight.w700, color: AppColorsNext.textStrong);
  final children = <InlineSpan>[];

  void addPlain(int start, int end) {
    int i = start;
    while (i < end) {
      final on = bold[i];
      int j = i;
      while (j < end && bold[j] == on) {
        j++;
      }
      children.add(TextSpan(text: body.substring(i, j), style: on ? boldStyle : base));
      i = j;
    }
  }

  int cursor = 0;
  while (cursor < body.length) {
    int bestAt = -1;
    String? bestTerm;
    for (final term in glossary.keys) {
      if (term.isEmpty) continue;
      final at = body.indexOf(term, cursor);
      if (at < 0) continue;
      if (bestAt == -1 || at < bestAt || (at == bestAt && term.length > bestTerm!.length)) {
        bestAt = at;
        bestTerm = term;
      }
    }
    if (bestTerm == null) {
      addPlain(cursor, body.length);
      break;
    }
    if (seen.contains(bestTerm)) {
      if (bestAt > cursor) addPlain(cursor, bestAt);
      addPlain(bestAt, bestAt + bestTerm.length);
      cursor = bestAt + bestTerm.length;
      continue;
    }
    seen.add(bestTerm);
    // 용어 밑줄은 글자 엔진에선 '그림 한 칸'이라 그 앞뒤에서 줄이 바뀔 수 있다 → '근저당' / '이에요'처럼 토씨가 줄
    // 첫머리로 떨어졌다. 바로 앞 여는 괄호와 바로 뒤 토씨·닫는 괄호(띄어쓰기 전까지, 짧을 때만)를 **같은 칸에** 싣는다(2026-11-01).
    final (head, tail) = termNeighbors(body, bestAt, bestAt + bestTerm.length, cursor: cursor, bold: bold);
    final headStart = bestAt - head.length;
    if (headStart > cursor) addPlain(cursor, headStart);
    children.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: _CaseTerm(term: bestTerm, description: glossary[bestTerm]!, base: base, head: head, tail: tail),
      ),
    );
    cursor = bestAt + bestTerm.length + tail.length;
  }
  return TextSpan(style: base, children: children);
}

/// 용어 칸에 함께 실을 (앞 여는 괄호, 뒤 토씨) — 띄어쓰기 사이의 짧은 글자만. 굵게 칠할 글자는 싣지 않는다(굵기가 사라진다).
(String, String) termNeighbors(String body, int start, int end, {int cursor = 0, List<bool>? bold}) {
  const maxTail = 8;
  var head = '';
  if (start - 1 >= cursor && '(（「『“‘'.contains(body[start - 1]) && !(bold?[start - 1] ?? false)) {
    head = body[start - 1];
  }
  var j = end;
  while (j < body.length && !RegExp(r'\s').hasMatch(body[j])) {
    j++;
  }
  final tail = body.substring(end, j);
  final boldInTail = bold != null && [for (int k = end; k < j; k++) bold[k]].any((x) => x);
  if (tail.isEmpty || tail.length > maxTail || boldInTail) return (head, '');
  return (head, tail);
}

/// 요약 속 용어 — 초록 #14724B · 굵기 600 · 실선 밑줄(두께 2, 35% 투명, 글자와 간격 4). 누르면 풀이 시트.
class _CaseTerm extends StatelessWidget {
  const _CaseTerm({
    required this.term,
    required this.description,
    required this.base,
    this.head = '',
    this.tail = '',
  });

  final String term;
  final String description;
  final TextStyle base;

  /// 용어 바로 앞 여는 괄호 · 바로 뒤 토씨(밑줄 없이 평범한 글자) — 줄이 그 사이에서 바뀌지 않게 같은 칸에 싣는다
  final String head;
  final String tail;

  @override
  Widget build(BuildContext context) {
    final underlined = _termBody(context);
    if (head.isEmpty && tail.isEmpty) return underlined;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (head.isNotEmpty) AppText(head, style: base),
        underlined,
        if (tail.isNotEmpty) AppText(tail, style: base),
      ],
    );
  }

  Widget _termBody(BuildContext context) {
    return Semantics(
      button: true,
      label: '$term 뜻 보기',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showCaseTermSheet(context, term: term, description: description),
        child: Container(
          padding: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: AppColors.primary.withValues(alpha: 0.35), width: 2),
            ),
          ),
          child: AppText(
            term,
            style: base.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// "어려운 말 풀이" 시트 — 작은 초록 이름표 + 용어 24 굵게 + 설명 17 + [알겠어요](초록, 높이 56).
/// 바깥 어두운 곳을 눌러도 닫힌다.
Future<void> showCaseTermSheet(
  BuildContext context, {
  required String term,
  required String description,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(_kBoxRadius)),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        bottom: MediaQuery.paddingOf(sheetContext).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.article_outlined, size: 18, color: AppColors.primary),
              const SizedBox(width: 6),
              AppText(
                '어려운 말 풀이',
                style: AppTypographyNext.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AppText(term, style: AppTypographyNext.headline),
          const SizedBox(height: 10),
          AppText(description, style: AppTypographyNext.body),
          const SizedBox(height: 24),
          SizedBox(
            height: 56,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: AppText(
                '알겠어요',
                style: AppTypographyNext.button.copyWith(color: AppColors.onPrimary),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
