/// 리포트 **PDF로 저장** (2026-10-29 규혁 결정 — 글자 요약 공유를 빼고 바꿈).
///
/// 앱바 오른쪽 버튼 → 바닥 시트('PDF로 저장') → [PDF 만들기] → 안드로이드 인쇄 창의 'PDF로 저장'.
///
/// - PDF는 **폰 안에서** 만든다(서버로 보내지 않는다). 등기부 **사진은 넣지 않는다** — 글자만.
/// - 내용: 별칭·주소·분석 날짜·등기부 날짜 → 종합 등급과 결론 한 줄 → 보증금·시세 → 근거 카드 전부
///   (제목·등급·쉬운 설명·숫자 상자) → 리포트 맨 아래 면책 문구. 화면과 같은 기준으로 '명단 대조 아직 안 됨'
///   카드는 근거에서 빼고 면책 위 한 줄로 알린다.
/// - 등급·결론은 규칙 엔진이 낸 것을 **그대로 옮길 뿐**이다 — 새 판정이 아니다.
/// - **사람 이름은 기본으로 가린다**(`personNames`, 서버와 같은 `홍○○` — `utils/name_mask.dart`). 시트의 스위치로
///   끌 수 있다(내 서류로 간직할 때). 앱의 '사진 속 이름 가리기'가 켜져 있으면 스위치를 잠그고 **무조건** 가린다.
/// - 한글 글꼴: 앱의 Pretendard. PDF 라이브러리가 OTF(CFF)를 못 읽어 같은 판(1.3.9)의 **공식 TTF**를
///   `assets/fonts/pdf/`에 따로 둔다(원본 그대로 — OFL 예약 글꼴 이름이라 변환하지 않는다).
library;

import '../legal/notices.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/risk_grade.dart';
import '../../services/pdf_save.dart';
import '../../state/privacy_settings.dart';
import '../../utils/money_format.dart';
import '../../utils/name_mask.dart';
import '../cases/case_card.dart' show stripBoldMarkers;
import 'report_screen.dart' show kBlacklistPendingLabel;

/// 리포트 맨 아래 면책 문구 — 화면(`ReportScreen._disclaimer`)과 **같은 글자**.
const String kReportDisclaimer = kReportNotice;

/// 명단 미구축 고지 — 화면과 같은 글자.
const String kBlacklistPendingNotice = kBlacklistCheckNotice;

// ── 1. PDF에 들어갈 글자 (이름 가리기는 여기 한 곳) ─────────────────────────

/// 근거 카드 한 장의 글자.
class ReportPdfEvidence {
  const ReportPdfEvidence({
    required this.grade,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.detail,
    required this.explanation,
  });

  final RiskGrade grade;
  final String title;

  /// 전문 용어 부제(예: '선순위 채권'). 없으면 빈 글자.
  final String subtitle;

  /// 서버가 등급 대신 붙인 특별 상태 — 등급 이름과 같으면 null.
  final String? status;

  /// 숫자 상자(detailText). `**굵게**` 표시는 그대로 둔다(그릴 때 굵게).
  final String? detail;

  /// 쉬운 설명. `**굵게**` 표시는 그대로 둔다.
  final String explanation;

  /// 모든 글자 (테스트가 이름이 남았는지 본다).
  Iterable<String> get texts => [
    title,
    subtitle,
    ?status,
    ?detail,
    explanation,
  ];
}

/// PDF 한 건의 글자 — [reportPdfData]가 만든다. 사람 이름은 이미 가려져 있다(가리기를 켰다면).
class ReportPdfData {
  const ReportPdfData({
    required this.alias,
    required this.address,
    required this.analyzedDate,
    required this.registryDate,
    required this.grade,
    required this.headline,
    required this.priceLine,
    required this.evidences,
    required this.blacklistPending,
    required this.namesHidden,
  });

  final String alias;
  final String address;

  /// `2026.10.22`
  final String analyzedDate;

  /// 등기부 발급(열람)일 — 못 읽었으면 null(지어내지 않는다).
  final String? registryDate;
  final RiskGrade grade;
  final String headline;

  /// `보증금 1억 2,000만원 · 시세 2억원` (화면 결론 헤더와 같은 말)
  final String priceLine;
  final List<ReportPdfEvidence> evidences;
  final bool blacklistPending;
  final bool namesHidden;

  /// 모든 글자 (테스트가 이름이 남았는지 본다).
  Iterable<String> get texts => [
    alias,
    address,
    analyzedDate,
    ?registryDate,
    headline,
    priceLine,
    for (final e in evidences) ...e.texts,
  ];
}

int _severity(RiskGrade g) => switch (g) {
  RiskGrade.danger => 2,
  RiskGrade.caution => 1,
  RiskGrade.ok => 0,
};

/// 리포트 → PDF 글자. [hideNames]가 false여도 앱의 '사진 속 이름 가리기'가 켜져 있으면 가린다.
ReportPdfData reportPdfData(AnalysisReport report, {bool hideNames = true}) {
  final bool hide = hideNames || PrivacySettings.instance.hideNamesInPhotos;
  String m(String s) =>
      hide ? maskNamesInText(s.trim(), report.personNames) : s.trim();
  String? mOpt(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : m(t);
  }

  bool pending(EvidenceItem e) =>
      e.id == 'blacklist' && e.statusLabel == kBlacklistPendingLabel;

  // 위험 → 확인 필요 → 양호 (같은 등급은 서버 순서 그대로) — 화면 근거 목록과 같은 순서
  final visible = [
    for (final e in report.evidences)
      if (!pending(e)) e,
  ];
  final indexed = [for (int i = 0; i < visible.length; i++) (i, visible[i])]
    ..sort((a, b) {
      final s = _severity(b.$2.grade).compareTo(_severity(a.$2.grade));
      return s != 0 ? s : a.$1.compareTo(b.$1);
    });

  final String priceLine = report.marketPrice != null
      ? '보증금 ${formatWon(report.deposit)} · 시세 ${formatWon(report.marketPrice!)}'
      : '보증금 ${formatWon(report.deposit)} · 시세를 못 구했어요';

  return ReportPdfData(
    alias: m(report.alias),
    address: m(report.address),
    analyzedDate: formatDate(report.analyzedAt),
    registryDate: mOpt(report.registryViewedAt),
    grade: report.grade,
    headline: m(report.headline),
    priceLine: priceLine,
    evidences: [
      for (final (_, e) in indexed)
        ReportPdfEvidence(
          grade: e.grade,
          title: m(e.title),
          subtitle: m(e.termSubtitle),
          status: switch (mOpt(e.statusLabel)) {
            final String s when s != e.grade.label => s,
            _ => null,
          },
          detail: mOpt(e.detailText),
          explanation: m(e.easyExplanation),
        ),
    ],
    blacklistPending: report.evidences.any(pending),
    namesHidden: hide,
  );
}

/// 저장할 파일 이름 — `전세AI프_리포트_샘플빌라_20261022.pdf`. 파일 이름에 못 쓰는 글자는 뺀다.
String reportPdfFileName(ReportPdfData data) {
  final safe = data.alias
      .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
      .replaceAll(RegExp('_+'), '_');
  final trimmed = safe.length > 30 ? safe.substring(0, 30) : safe;
  final date = data.analyzedDate.replaceAll('.', '');
  return '전세AI프_리포트_${trimmed}_$date.pdf';
}

// ── 2. PDF 그리기 ────────────────────────────────────────────────────────

/// PDF용 한글 글꼴 (Pretendard 공식 TTF).
class ReportPdfFonts {
  const ReportPdfFonts({required this.regular, required this.bold});

  final pw.Font regular;
  final pw.Font bold;

  static ReportPdfFonts? _cached;

  /// 앱 묶음(assets)에서 한 번만 읽는다.
  static Future<ReportPdfFonts> load() async {
    if (_cached case final ReportPdfFonts f) return f;
    final regular = await rootBundle.load(
      'assets/fonts/pdf/Pretendard-Regular.ttf',
    );
    final bold = await rootBundle.load('assets/fonts/pdf/Pretendard-Bold.ttf');
    return _cached = ReportPdfFonts(
      regular: pw.Font.ttf(regular),
      bold: pw.Font.ttf(bold),
    );
  }
}

PdfColor _pdf(Color c) => PdfColor.fromInt(c.toARGB32());

final PdfColor _primary = _pdf(AppColors.primary);
final PdfColor _primarySoft = _pdf(AppColors.primarySoft);
final PdfColor _textStrong = _pdf(AppColors.textStrong);
final PdfColor _textBody = _pdf(AppColors.textBody);
final PdfColor _textMuted = _pdf(AppColors.textMuted);
final PdfColor _line = _pdf(AppColors.line);
final PdfColor _background = _pdf(AppColors.background);

/// `**굵게**`를 굵은 글자로 — 화면(caseRichText)과 같은 표시를 쓴다.
pw.Widget _rich(String raw, pw.TextStyle base, pw.Font bold) {
  final stripped = stripBoldMarkers(raw);
  final text = stripped.text;
  final mark = List<bool>.filled(text.length, false);
  for (final p in stripped.bold) {
    final at = text.indexOf(p);
    if (p.isEmpty || at < 0) continue;
    for (int k = at; k < at + p.length; k++) {
      mark[k] = true;
    }
  }
  final spans = <pw.TextSpan>[];
  int i = 0;
  while (i < text.length) {
    final on = mark[i];
    int j = i;
    while (j < text.length && mark[j] == on) {
      j++;
    }
    spans.add(
      pw.TextSpan(
        text: text.substring(i, j),
        style: on ? base.copyWith(font: bold, color: _textStrong) : base,
      ),
    );
    i = j;
  }
  return pw.RichText(
    text: pw.TextSpan(children: spans, style: base),
  );
}

pw.Widget _gradeChip(RiskGrade g, pw.Font bold, {double size = 9}) =>
    pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: pw.BoxDecoration(
        color: _pdf(AppColors.gradeSoftColor(g)),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Text(
        g.label,
        style: pw.TextStyle(
          font: bold,
          fontSize: size,
          color: _pdf(AppColors.gradeColor(g)),
        ),
      ),
    );

pw.Widget _evidenceCard(ReportPdfEvidence e, ReportPdfFonts f) {
  final body = pw.TextStyle(
    font: f.regular,
    fontSize: 9.5,
    color: _textBody,
    lineSpacing: 2,
  );
  // 카드 한 장은 쪽 사이에서 쪼개지 않는다 — 넘치면 통째로 다음 쪽(Column은 원래 쪼개진다)
  return pw.Inseparable(
    child: pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          left: pw.BorderSide(
            color: _pdf(AppColors.gradeColor(e.grade)),
            width: 3,
          ),
          top: pw.BorderSide(color: _line, width: 0.6),
          right: pw.BorderSide(color: _line, width: 0.6),
          bottom: pw.BorderSide(color: _line, width: 0.6),
        ),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _gradeChip(e.grade, f.bold),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.Text(
                  e.title,
                  style: pw.TextStyle(
                    font: f.bold,
                    fontSize: 11,
                    color: _textStrong,
                  ),
                ),
              ),
            ],
          ),
          if (e.subtitle.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              e.subtitle,
              style: pw.TextStyle(
                font: f.regular,
                fontSize: 8.5,
                color: _textMuted,
              ),
            ),
          ],
          if (e.status case final String s) ...[
            pw.SizedBox(height: 5),
            pw.Text(
              s,
              style: pw.TextStyle(
                font: f.bold,
                fontSize: 9,
                color: _pdf(AppColors.gradeColor(e.grade)),
              ),
            ),
          ],
          if (e.detail case final String d) ...[
            pw.SizedBox(height: 6),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: _background,
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: _rich(
                d,
                pw.TextStyle(
                  font: f.bold,
                  fontSize: 9.5,
                  color: _textStrong,
                  lineSpacing: 2,
                ),
                f.bold,
              ),
            ),
          ],
          if (e.explanation.isNotEmpty) ...[
            pw.SizedBox(height: 6),
            _rich(e.explanation, body, f.bold),
          ],
        ],
      ),
    ),
  );
}

/// PDF 바이트를 만든다 (A4, 보통 1~2장). [compress]는 테스트가 글꼴 이름을 찾을 때만 끈다.
Future<Uint8List> buildReportPdf(
  ReportPdfData data,
  ReportPdfFonts fonts, {
  DateTime? createdAt,
  bool compress = true,
}) async {
  final f = fonts;
  final made = createdAt ?? DateTime.now();
  final doc = pw.Document(
    compress: compress,
    title: '전세AI프 안전도 리포트 — ${data.alias}',
    author: '전세AI프',
    creator: '전세AI프',
    theme: pw.ThemeData.withFont(base: f.regular, bold: f.bold),
  );
  final gradeColor = _pdf(AppColors.gradeColor(data.grade));
  final gradeSoft = _pdf(AppColors.gradeSoftColor(data.grade));
  final muted = pw.TextStyle(font: f.regular, fontSize: 9, color: _textMuted);

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
      header: (ctx) => pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 12),
        padding: const pw.EdgeInsets.only(bottom: 6),
        decoration: pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _primary, width: 1.2)),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              '전세AI프 안전도 리포트',
              style: pw.TextStyle(font: f.bold, fontSize: 10, color: _primary),
            ),
            pw.Text('${formatDate(made)} 저장', style: muted),
          ],
        ),
      ),
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            data.namesHidden ? '규칙 기반 판정 · 사람 이름은 가렸어요' : '규칙 기반 판정',
            style: muted.copyWith(fontSize: 8),
          ),
          pw.Text(
            '${ctx.pageNumber} / ${ctx.pagesCount}',
            style: muted.copyWith(fontSize: 8),
          ),
        ],
      ),
      build: (ctx) => [
        // ── 어떤 집 · 언제 ──
        pw.Text(
          data.alias,
          style: pw.TextStyle(font: f.bold, fontSize: 18, color: _textStrong),
        ),
        if (data.address.isNotEmpty && data.address != data.alias) ...[
          pw.SizedBox(height: 3),
          pw.Text(
            data.address,
            style: pw.TextStyle(
              font: f.regular,
              fontSize: 10,
              color: _textBody,
            ),
          ),
        ],
        pw.SizedBox(height: 3),
        pw.Text(
          '${data.analyzedDate} 분석 · '
          '${data.registryDate == null ? '등기부 발급일 확인 필요' : '${data.registryDate} 기준 등기부등본'}',
          style: muted,
        ),
        pw.SizedBox(height: 14),

        // ── 결론 ──
        pw.Inseparable(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(14),
            decoration: pw.BoxDecoration(
              color: gradeSoft,
              borderRadius: pw.BorderRadius.circular(10),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  children: [
                    pw.Text(
                      '종합 등급',
                      style: pw.TextStyle(
                        font: f.regular,
                        fontSize: 10,
                        color: _textBody,
                      ),
                    ),
                    pw.SizedBox(width: 8),
                    pw.Text(
                      data.grade.label,
                      style: pw.TextStyle(
                        font: f.bold,
                        fontSize: 20,
                        color: gradeColor,
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  data.headline,
                  style: pw.TextStyle(
                    font: f.bold,
                    fontSize: 13,
                    color: _textStrong,
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  data.grade.decisionLabel,
                  style: pw.TextStyle(
                    font: f.bold,
                    fontSize: 10,
                    color: gradeColor,
                  ),
                ),
                pw.SizedBox(height: 8),
                pw.Text(
                  data.priceLine,
                  style: pw.TextStyle(
                    font: f.bold,
                    fontSize: 10,
                    color: _textBody,
                  ),
                ),
              ],
            ),
          ),
        ),
        pw.SizedBox(height: 16),

        // ── 근거 ──
        pw.Text(
          '등기부에서 찾은 것',
          style: pw.TextStyle(font: f.bold, fontSize: 13, color: _textStrong),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          [
            for (final g in RiskGrade.values)
              if (data.evidences.where((e) => e.grade == g).length
                  case final int n when n > 0)
                '${g.label} $n',
          ].join(' · '),
          style: muted,
        ),
        pw.SizedBox(height: 8),
        if (data.evidences.isEmpty)
          pw.Text('근거 카드가 없어요', style: muted)
        else
          for (final e in data.evidences) _evidenceCard(e, f),
        pw.SizedBox(height: 10),

        // ── 면책 (리포트 맨 아래와 같은 글자) ──
        pw.Inseparable(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: _primarySoft,
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (data.blacklistPending) ...[
                  pw.Text(
                    kBlacklistPendingNotice,
                    style: pw.TextStyle(
                      font: f.regular,
                      fontSize: 8.5,
                      color: _textBody,
                      lineSpacing: 1.5,
                    ),
                  ),
                  pw.SizedBox(height: 5),
                ],
                pw.Text(
                  kReportDisclaimer,
                  style: pw.TextStyle(
                    font: f.regular,
                    fontSize: 8.5,
                    color: _textMuted,
                    lineSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
  return doc.save();
}

// ── 3. 저장 ───────────────────────────────────────────────────────────────

/// [PDF로 저장] — 누르면 바로 만들어 인쇄 창의 'PDF로 저장'으로 넘긴다(2026-10-30: 설명·스위치 시트를 없앴다).
///
/// 사람 이름은 **항상** 가린다(홍○○) — PDF는 남에게 건네는 파일이라서. 사진은 넣지 않는다.
/// 만드는 동안만 작은 '만드는 중' 창을 띄운다. 저장했는지는 알 수 없으니 성공 안내는 하지 않는다.
Future<void> showReportPdfSheet(BuildContext context, AnalysisReport report) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _PdfMakingDialog(),
  ).then((_) => open = false);
  String? problem;
  try {
    final data = reportPdfData(report, hideNames: true);
    final bytes = await buildReportPdf(data, await ReportPdfFonts.load());
    if (open) navigator.pop();
    final outcome = await PdfSave.save(bytes, name: reportPdfFileName(data));
    if (outcome == PdfSaveOutcome.failed) {
      problem = 'PDF 저장 화면을 열지 못했어요. 잠시 후 다시 눌러 주세요';
    }
  } catch (e) {
    debugPrint('[PDF] 만들지 못했어요 (${e.runtimeType})');
    problem = 'PDF를 만들지 못했어요. 잠시 후 다시 눌러 주세요';
    if (open) navigator.pop();
  }
  if (problem != null) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: AppText(problem)));
  }
}

class _PdfMakingDialog extends StatelessWidget {
  const _PdfMakingDialog();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        key: const ValueKey('report-pdf-making'),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.lg,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: AppSpacing.md),
              AppText('PDF 만드는 중', style: AppTypography.bodyStrong),
            ],
          ),
        ),
      ),
    );
  }
}
