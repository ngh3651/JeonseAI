/// 약관·처리방침 같은 **긴 안내 문서**를 앱 디자인으로 그리는 틀 (2026-10-30).
///
/// 문서는 [LegalDoc] 데이터로만 쓰고(내용 파일: terms_content.dart · privacy_content.dart · data_sources_content.dart),
/// 화면은 이 파일 하나가 그린다 — 맨 위 '한눈에 보기' 카드 → 번호 붙은 조항 카드 → 시행일·문의.
/// 글쓰기 규칙: 문장은 짧게 "~해요", 대시(—)·괄호 남발 금지, 한 문단은 두세 문장까지.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';

/// 줄바꿈 없는 공백 (U+00A0) — 이 공백에서는 줄이 바뀌지 않는다.
const String _nbsp = '\u00A0';

/// 문단 **끝의 짧은 어절 묶음**을 줄바꿈 없는 공백으로 잇는다 — 마지막 한 낱말('있어요.')만
/// 다음 줄로 떨어지거나 '쓸 / 수 있어요'처럼 말 묶음이 갈리지 않게 (2026-10-30 디자인 리뷰).
/// 끝에서부터 세 어절까지, 합쳐 10자 이하일 때만 잇는다(좁은 화면에서 잘려 나가지 않게). 줄(`\n`)마다 따로 본다.
String noOrphan(String text) => text.split('\n').map(_tieTail).join('\n');

String _tieTail(String line) {
  final words = line.split(' ');
  if (words.length < 2) return line;
  var take = 1;
  var length = words.last.runes.length;
  while (take < 3 && take < words.length) {
    final next = words[words.length - take - 1];
    if (next.isEmpty || length + 1 + next.runes.length > 10) break;
    length += 1 + next.runes.length;
    take++;
  }
  if (take < 2) return line;
  final head = words.sublist(0, words.length - take).join(' ');
  final tail = words.sublist(words.length - take).join(_nbsp);
  return head.isEmpty ? tail : '$head $tail';
}

/// 문서 하나
class LegalDoc {
  const LegalDoc({
    required this.title,
    required this.effectiveDate,
    this.intro,
    this.highlights = const [],
    required this.sections,
    this.contact,
  });

  /// 앱바 제목
  final String title;

  /// 맨 아래 "2026년 10월 30일부터 적용해요"
  final String effectiveDate;

  /// 맨 위 한두 문장(없어도 됨)
  final String? intro;

  /// '한눈에 보기' — 아이콘 + 한 줄 (3~4개)
  final List<LegalHighlight> highlights;

  final List<LegalSection> sections;

  /// 문의 메일(있으면 맨 아래 줄을 눌러 메일 앱을 연다)
  final String? contact;

  /// 테스트·검색용 — 문서의 모든 글자를 한 덩어리로
  String get plainText => [
    title,
    ?intro,
    for (final h in highlights) h.text,
    for (final s in sections) ...[s.title, ...s.plainLines],
    effectiveDate,
    ?contact,
  ].join('\n');
}

class LegalHighlight {
  const LegalHighlight(this.icon, this.text);
  final IconData icon;
  final String text;
}

/// 조항 하나 — 제목 + 블록들(문단·점 목록·항목표)
class LegalSection {
  const LegalSection(this.title, this.blocks);
  final String title;
  final List<LegalBlock> blocks;

  List<String> get plainLines => [
    for (final b in blocks)
      ...switch (b) {
        LegalParagraph(:final text) => [text],
        LegalBullets(:final items) => items,
        LegalRows(:final rows) => [for (final r in rows) '${r.$1} ${r.$2}'],
      },
  ];
}

sealed class LegalBlock {
  const LegalBlock();
}

class LegalParagraph extends LegalBlock {
  const LegalParagraph(this.text);
  final String text;
}

class LegalBullets extends LegalBlock {
  const LegalBullets(this.items);
  final List<String> items;
}

/// 이름표 + 내용 줄들 (예: "받는 것 | 등기부 사진") — 표 대신 위아래로 쌓아 좁은 폰에서도 읽기 쉽게
class LegalRows extends LegalBlock {
  const LegalRows(this.rows);
  final List<(String, String)> rows;
}

/// 문서 화면
class LegalDocScreen extends StatelessWidget {
  const LegalDocScreen({super.key, required this.doc});

  final LegalDoc doc;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: AppText(doc.title)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            AppSpacing.sm,
            AppSpacing.screenPadding,
            AppSpacing.xxxl,
          ),
          children: [
            if (doc.intro != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: AppText(
                  noOrphan(doc.intro!),
                  style: AppTypographyNext.body.copyWith(
                    color: AppColorsNext.textMuted,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (doc.highlights.isNotEmpty) ...[
              _HighlightsCard(items: doc.highlights),
              const SizedBox(height: 12),
            ],
            for (int i = 0; i < doc.sections.length; i++) ...[
              _SectionCard(number: i + 1, section: doc.sections[i]),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            Center(
              child: AppText(
                doc.effectiveDate,
                textAlign: TextAlign.center,
                style: AppTypographyNext.caption.copyWith(
                  color: AppColorsNext.textMuted,
                ),
              ),
            ),
            if (doc.contact != null) ...[
              const SizedBox(height: 4),
              Center(child: ContactMailLink(email: doc.contact!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _HighlightsCard extends StatelessWidget {
  const _HighlightsCard({required this.items});

  final List<LegalHighlight> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('legal-highlights'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            '한눈에 보기',
            style: AppTypographyNext.caption.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.primaryStrong,
            ),
          ),
          const SizedBox(height: 12),
          for (final h in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(h.icon, size: 18, color: AppColors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: AppText(
                        noOrphan(h.text),
                        style: AppTypographyNext.body.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColorsNext.textStrong,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.number, required this.section});

  final int number;
  final LegalSection section;

  @override
  Widget build(BuildContext context) {
    final body = AppTypographyNext.body.copyWith(
      fontSize: 16,
      height: 1.6,
      color: AppColorsNext.textBody,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                alignment: Alignment.center,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: AppText(
                  '$number',
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryStrong,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppText(section.title, style: AppTypographyNext.title),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (int i = 0; i < section.blocks.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            switch (section.blocks[i]) {
              LegalParagraph(:final text) => AppText(noOrphan(text), style: body),
              LegalBullets(:final items) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            margin: const EdgeInsets.only(top: 11, right: 10),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(child: AppText(noOrphan(item), style: body)),
                        ],
                      ),
                    ),
                ],
              ),
              LegalRows(:final rows) => Container(
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Column(
                  children: [
                    for (int r = 0; r < rows.length; r++) ...[
                      if (r > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          indent: 14,
                          endIndent: 14,
                          color: AppColorsNext.divider,
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AppText(
                              rows[r].$1,
                              style: AppTypographyNext.caption.copyWith(
                                fontWeight: FontWeight.w700,
                                color: AppColorsNext.textMuted,
                              ),
                            ),
                            const SizedBox(height: 2),
                            AppText(noOrphan(rows[r].$2), style: body),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            },
          ],
        ],
      ),
    );
  }
}

/// 문의 메일 한 줄 — 누르면 메일 앱(없으면 아무 일 없음)
class ContactMailLink extends StatelessWidget {
  const ContactMailLink({super.key, required this.email});

  final String email;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        try {
          await launchUrl(Uri(scheme: 'mailto', path: email));
        } catch (_) {
          // 메일 앱이 없는 폰 — 주소는 화면에 그대로 보인다
        }
      },
      style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
      child: AppText(
        '문의 $email',
        style: AppTypographyNext.caption.copyWith(
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
      ),
    );
  }
}
