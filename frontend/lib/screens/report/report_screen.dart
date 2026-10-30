/// S-07 AI 안전도 리포트 — 핵심 화면 (IA.md §6).
///
/// 구조: 결론 헤더(게이지 크게 + 의사결정 한 줄 + 보증금) → 질문 바로가기
/// → 근거 카드(최고 심각도 1개 기본 펼침, 용어 툴팁) → 다음 행동(등급별 추천 강조).
/// (2026-08-14 D5: '지금 해야 할 일' 박스를 빼고 그 안의 질문 버튼만 남겼다.)
/// 판례·질문 생성기·체크리스트·공유는 C-3에서 실화면 연결 (스텁 문구는 사용자 언어로).
/// 2026-07-04 C-2 리뷰 3종(design-reviewer·persona 2인) 반영.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

// [D4 · 2026-08-14] 시세 출처 칩을 렌더링에서 뺐다 → 이 두 import가 함께 놀게 됐다.
// 칩을 되살릴 때 같이 풀라고 지우지 않고 주석으로 남긴다 (_conclusionHeader 참고).
// import '../../design_system/components/amber_hint.dart';
// import '../../models/market_price_source.dart' show marketPriceSourceLabel;
import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_callout.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/components/safety_gauge.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/property_reports.dart';
import '../../models/registry_mark_kind.dart';
import '../../models/risk_grade.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';
import '../../state/case_prefetch.dart';
import '../../state/journey_schedule_store.dart';
import '../../state/privacy_settings.dart';
import '../../state/registry_photo_store.dart';
import '../../state/report_focus.dart';
import '../../utils/money_format.dart';
import '../common/share_feedback.dart';
import '../../utils/korean_date.dart';
import '../search/capture_issue_panel.dart';
import '../search/capture_loop_route.dart';
import 'retake_notice_card.dart';
import 'report_inputs_sheet.dart';
import 'registry_entry_card.dart';
import 'registry_findings.dart';
import 'loss_chapter.dart';
import 'ask_chapter.dart';
import 'case_chapter.dart';
import '../common/ask_selection.dart';
import 'report_history_sheet.dart';
import 'report_pdf.dart';
import '../../design_system/text/app_text.dart';

/// 악성임대인 명단이 **아직 우리에게 없을 때** 서버가 붙이는 상태 라벨.
/// 백엔드 `rule_engine.BLACKLIST_PENDING_LABEL`과 **글자까지 같아야 한다** —
/// 한쪽만 바꾸면 카드가 사라진 채 고지도 안 나가는 최악의 조합이 된다.
/// (계약에 따로 플래그를 두는 대신 이 라벨을 쓰는 것은 백엔드도 마찬가지다:
///  `fallback_texts.py`가 같은 방식으로 이 상태를 판별한다.)
const String kBlacklistPendingLabel = '명단 대조 아직 안 됨';

/// 이 근거가 '매물의 위험'이 아니라 **'우리 데이터가 아직 없다'**를 말하고 있는가.
///
/// 서버는 명단 파일이 비면 이 카드를 '확인 필요'로 내보내는데, 화면에서는 다른
/// 근거들과 나란히 서서 **이 집에 뭔가 걸린 것처럼** 읽혔다. 실제로는 이 집이 아니라
/// 우리 쪽 준비 상태의 문제다. 그래서 근거 카드 대열에서 빼고 하단 한계 고지로 내린다.
///
/// ⚠ 판정에는 아무 영향이 없다. 등급은 서버가 계산하고, 서버의 worst-of 계산은
///   이 상태의 blacklist를 **이미 제외하고** 있다(`rule_engine.evaluate`).
///   여기서는 그려진 것을 안 그릴 뿐이다.
/// ⚠ 명단 데이터가 채워지면 status_label이 '확인 필요'/'명단 일치 — 직접 확인 필요'
///   또는 null(양호)로 바뀌므로, 이 조건이 저절로 거짓이 되어 **카드가 되돌아온다.**
bool _isPendingBlacklist(EvidenceItem e) =>
    e.id == 'blacklist' && e.statusLabel == kBlacklistPendingLabel;

class ReportScreen extends StatefulWidget {
  const ReportScreen({
    super.key,
    required this.reportId,
    this.captureOne = defaultCaptureOne,
    this.pickMany = defaultPickMany,
  });

  final String reportId;

  /// 카메라 주입 지점 — '그 장만 다시 찍기'에서 쓴다(테스트는 카메라 없이 가짜 함수를 넣는다).
  final CaptureOne captureOne;

  /// 갤러리 주입 지점 — 다시 올리기 카드의 [갤러리에서 고르기]
  final PickMany pickMany;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  /// 리포트는 **한 번만** 불러온다.
  ///
  /// 예전에는 StatelessWidget의 build() 안에서 `getReport()`를 불렀다. 그때는 재빌드가
  /// 드물어 증상이 없었지만, 진입 카드에 사진 미리보기가 들어오면서 이미지 로딩·레이아웃
  /// 변화로 재빌드가 늘어난다. build마다 새 Future가 생기면 FutureBuilder가 로딩 분기로
  /// 되돌아가 화면이 깜빡이고 매번 서버 요청이 나간다(뷰어에서 실제로 겪은 문제다).
  late Future<AnalysisReport?> _reportFuture;

  String get reportId => widget.reportId;

  /// 같은 집의 지난 리포트를 찾으려고 받는 전체 이력 — 시계 버튼(이전 리포트)과 '지난 리포트' 띠 (2026-10-26)
  List<AnalysisReport> _history = const [];

  @override
  void initState() {
    super.initState();
    // 판례까지 받은 뒤에 리포트를 그린다 — 판례가 리포트 3장이라 뒤늦게 뜨면 화면이 밀린다(2026-10-30).
    // 분석 직후엔 로딩 화면이 이미 받아 두어 바로 열린다.
    ContentRepository? content;
    try {
      content = context.read<ContentRepository>();
    } catch (_) {
      content = null; // 판례 저장소가 없는 화면(테스트 등) — 판례 장이 그때 받는다
    }
    _reportFuture = context.read<AnalysisRepository>().getReport(reportId).then(
      (r) async {
        if (r != null && content != null) {
          await CasePrefetch.ready(content, reportId);
        }
        return r;
      },
    );
    context.read<AnalysisRepository>().getHistory().then((h) {
      if (mounted) setState(() => _history = h);
    }, onError: (_) {});
    // 챗봇이 이 리포트를 알고 답하게 — 리포트를 읽다 모르는 걸 챗봇에 물어볼 때 (2026-10-26)
    _reportFuture.then((r) {
      if (r != null) ReportFocus.current.value = ReportRef(r.id, r.alias);
    }, onError: (_) {});
  }

  /// 입력값을 고쳤으면 그 자리에서 새 리포트로 바꿔 그린다(같은 id — 화면을 다시 열지 않는다).
  Future<void> _editInputs(
    BuildContext context,
    AnalysisReport report, {
    bool focusPrice = false,
  }) async {
    final updated = await editReportInputs(
      context,
      report,
      focusPrice: focusPrice,
    );
    if (updated == null || !mounted) return;
    setState(() {
      _reportFuture = Future.value(updated);
    });
    ReportFocus.current.value = ReportRef(updated.id, updated.alias);
  }

  /// '사진 속 이름 가리기'가 바뀌면 글자 속 이름도 **바로** 다시 가린다. 가리기는 모델을 만들 때 한 곳에서 하고
  /// (`AnalysisReport.fromJson`), 여기서는 지금 스위치 값의 모델로 바꿔 끼우기만 한다([AnalysisReport.withCurrentPrivacy]).
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PrivacySettings.instance,
    builder: (context, _) => _buildReport(context),
  );

  Widget _buildReport(BuildContext context) {
    return FutureBuilder<AnalysisReport?>(
      future: _reportFuture,
      builder: (context, snapshot) {
        final AnalysisReport? report = snapshot.data?.withCurrentPrivacy();

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (report == null) {
          // 이력 손상/없음 (user-scenario.md §5) — 막다른 길 방지 CTA 포함
          return Scaffold(
            appBar: AppBar(title: const AppText('안전도 리포트')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppText('이 리포트를 불러올 수 없어요', style: AppTypography.body),
                  const SizedBox(height: AppSpacing.lg),
                  AppCompactButton(
                    label: '홈으로',
                    onPressed: () => context.go('/home'),
                  ),
                ],
              ),
            ),
          );
        }

        final versions = versionsOf(report, _history);
        final bool isPast =
            versions.isNotEmpty && versions.first.id != report.id;
        return Scaffold(
          appBar: AppBar(
            title: AppText(report.alias),
            actions: [
              // 이전 리포트 — 같은 집은 최신 1개만 보이고, 지난 것은 여기서 (2026-10-26)
              IconButton(
                key: const ValueKey('report-history-button'),
                icon: const Icon(Icons.history),
                tooltip: '이전 리포트',
                onPressed: () => showReportHistorySheet(
                  context,
                  current: report,
                  versions: versions,
                ),
              ),
              // 입력값 고치기 — 별칭·보증금·시세. 같은 리포트를 고친다(report_inputs_sheet.dart, 2026-10-29)
              IconButton(
                key: const ValueKey('report-edit-button'),
                icon: const Icon(Icons.edit_outlined),
                tooltip: '정보 수정',
                onPressed: () => _editInputs(context, report),
              ),
              // 이 리포트를 PDF로 저장 — 폰 안에서 만들고 이름은 기본으로 가린다(report_pdf.dart)
              IconButton(
                key: const ValueKey('report-pdf-button'),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                tooltip: 'PDF로 저장',
                onPressed: () => showReportPdfSheet(context, report),
              ),
            ],
          ),
          // 글자를 꾹 눌러 [챗봇에 묻기] (2026-10-26)
          body: AskSelectionArea(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              children: [
                if (isPast)
                  PastReportBand(
                    report: report,
                    onLatest: () =>
                        context.pushReplacement('/report/${versions.first.id}'),
                  ),
                _conclusionHeader(report),
                const SizedBox(height: AppSpacing.xl),
                // 촬영 검사에서 '확인 필요'가 나온 장 (P1-1, 2026-10-22) — 판정은 그대로, 사진만 권한다.
                ..._captureNotice(context, report),
                // [D15 · 2026-08-14] 결론 헤더와 진입 카드 사이에 있던 아웃라인 버튼
                // '중개사 질문 모아 보기'를 뺐다. 자세한 사유는 아래 주석 참고.
                // 1장 '등기부에서 찾은 것' (2026-10-28 리포트 2안) — 사진 + 근거를 한 카드로
                _registryChapter(context, report),
                // 2장 '손실 시뮬레이터' (2026-10-29) — 다음 행동 칸에서 올라왔다
                LossChapter(reportId: report.id),
                const SizedBox(height: AppSpacing.xl),
                // 3장 '판례 매칭' (2026-10-29) — 다음 행동 칸에서 올라왔다
                CaseChapter(reportId: report.id),
                const SizedBox(height: AppSpacing.xl),
                // 4장 '중개사에게 물어볼 질문' (2026-10-29) — 다음 행동 칸에서 올라왔다
                AskChapter(reportId: report.id),
                // 판정이 아닌 **정보**라서 근거 카드 대열 밖, 바로 아래에 붙인다.
                ?_priceGapCard(report),
                const SizedBox(height: AppSpacing.xl),
                AppText('다음 행동', style: AppTypography.title),
                const SizedBox(height: AppSpacing.md),
                ..._actionArea(context, report),
                const SizedBox(height: AppSpacing.xxl),
                _disclaimer(report),
                const SizedBox(height: AppSpacing.xxxl),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 다시 올리기 안내 (2026-10-27 다시찍기_안내_시안) — 잘 안 읽힌 장 + 빠진 쪽.
  ///
  /// 분석은 끝났다. 잘 안 읽힌 장·빠진 쪽이 있으면 서버가 '양호'를 막았다(확인 필요 이상).
  /// 사진이 이 폰에 남아 있으면(최근 5건) 문제인 쪽만 바꾸거나 더해 **같은 보증금·별칭으로** 새로 분석한다
  /// → 같은 집의 새 리포트가 되고, 지난 것은 '이전 리포트'에 남는다.
  List<Widget> _captureNotice(BuildContext context, AnalysisReport report) {
    final paths = RegistryPhotoStore.instance.pathsFor(report.id);
    final pills = retakePillsFor(
      report,
      // 서버가 그 장의 쪽 번호를 못 읽었으면 정렬 순서(§9.12) → 올린 순서
      fallbackPageNumber: (index) {
        final count = paths.isNotEmpty ? paths.length : report.pageOrder.length;
        final at = report.pageDisplayOrder(count).indexOf(index);
        return at >= 0 ? at + 1 : index + 1;
      },
    );
    if (pills.isEmpty) return const [];
    return [
      RetakeNoticeCard(
        pills: pills,
        onShoot: () => _retake(context, report, paths, pills, gallery: false),
        onGallery: () => _retake(context, report, paths, pills, gallery: true),
      ),
      const SizedBox(height: AppSpacing.xl),
    ];
  }

  /// [다시 찍기]·[갤러리에서 고르기] → 문제인 쪽을 알약 순서대로 바꾸거나 더한 뒤 새로 분석한다.
  ///
  /// 사진이 폰에 없으면(오래된 리포트·보관 끔) 등기부 전체를 다시 찍거나 골라 새로 분석한다.
  Future<void> _retake(
    BuildContext context,
    AnalysisReport report,
    List<String> paths,
    List<RetakePill> pills, {
    required bool gallery,
  }) async {
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    List<String>? updated;
    if (paths.isEmpty) {
      // 바꿀 원본이 없다 — 전체를 새로
      if (gallery) {
        final picked = await widget.pickMany();
        if (picked.isNotEmpty) updated = picked;
      } else {
        final result = await navigator.push(
          MaterialPageRoute<CaptureLoopResult>(
            fullscreenDialog: true,
            builder: (_) => CaptureLoopRoute(
              alreadyTaken: 0,
              maxPhotos: kRetakeMaxPhotos,
              captureOne: widget.captureOne,
              hint: '등기부 1쪽부터 차례로 찍어 주세요 — 종이 네 모서리와 맨 아래 쪽 번호가 나오게',
            ),
          ),
        );
        if (result != null && result.newPaths.isNotEmpty)
          updated = result.newPaths;
      }
    } else if (gallery) {
      // 고른 사진을 알약 순서대로 끼운다 — 잘 안 읽힌 장은 바꾸고, 빠진 쪽은 더한다
      final picked = await widget.pickMany();
      if (picked.isNotEmpty) {
        updated = List<String>.of(paths);
        for (int i = 0; i < pills.length && i < picked.length; i++) {
          final at = pills[i].uploadIndex;
          if (at == null) {
            updated.add(picked[i]);
          } else if (at < updated.length) {
            updated[at] = picked[i];
          }
        }
      }
    } else {
      // 알약 순서대로 이어서 찍는다. 도중에 닫으면 아무것도 보내지 않는다.
      final next = List<String>.of(paths);
      for (final pill in pills) {
        final at = pill.uploadIndex;
        if (at != null && at >= next.length) continue;
        final result = await navigator.push(
          MaterialPageRoute<CaptureLoopResult>(
            fullscreenDialog: true,
            builder: (_) => at == null
                ? CaptureLoopRoute(
                    alreadyTaken: next.length,
                    maxPhotos: next.length + 1,
                    captureOne: widget.captureOne,
                    hint: pill.tip,
                  )
                : CaptureLoopRoute(
                    alreadyTaken: next.length,
                    maxPhotos: next.length,
                    captureOne: widget.captureOne,
                    replacePage: at,
                    replaceTip: pill.tip,
                  ),
          ),
        );
        if (!mounted || result == null || result.newPaths.isEmpty) return;
        if (at == null) {
          next.add(result.newPaths.last);
        } else {
          next[at] = result.newPaths.last;
        }
      }
      updated = next;
    }
    if (!mounted || updated == null) return;
    final Object? returned = await router.push<Object?>(
      '/loading',
      extra: AnalysisRequest(
        imagePaths: updated,
        deposit: report.deposit,
        // 시세는 사용자가 **직접 넣은** 값만 다시 보낸다(자동 조회 값은 서버가 다시 찾는다)
        marketPrice: report.marketPriceSource == MarketPriceSource.manual
            ? report.marketPrice
            : null,
        alias: report.alias,
        // 같은 서류를 마저 낸 것 — 새 리포트가 이 리포트를 대신한다(기록이 두 줄로 남지 않게, 2026-10-27)
        replacesReportId: report.id,
      ),
    );
    // 새로 찍은 장도 서버가 거절했다(여전히 흐림 등) — 조용히 돌아오지 않고 이유를 말한다.
    if (!mounted || returned is! CaptureRejection) return;
    messenger?.showSnackBar(
      SnackBar(
        content: AppText(
          '${returned.message}\n아직 분석하지 않았어요. 그 장을 다시 찍어 주세요.',
          style: AppTypography.body.copyWith(color: Colors.white),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// '내가 올린 사진에서 보기' 진입점.
  ///
  /// 사진이 없으면(보관을 끈 빌드·파일 소실·이력에서 다시 연 리포트) **카드를 조용히
  /// 없애지 않는다.** "어제는 있었는데 사라졌다 = 앱이 고장 났다"로 읽히기 때문이다
  /// (2026-07-27 서연 리뷰). 카드는 남기고 왜 못 여는지 한 줄로 바꾼다.
  ///
  /// 미리보기 스트립도 같은 원칙이다 — 표시가 없거나 사진을 못 읽으면 스트립만
  /// 사라지고 하단 행은 그대로 남는다.
  /// 리포트 1장 — 「1 / 5 · ✦ AI 분석」 + "등기부에서 찾은 것" + [사진 띠 · 내가 올린 사진에서 보기 · 근거 목록] 한 카드.
  ///
  /// 예전엔 사진 진입 카드와 '근거 살펴보기' 카드 묶음이 따로였다 — 같은 등기부 이야기라 한 장으로 합쳤다.
  /// 근거 한 줄을 누르면 예전 근거 카드와 **똑같이** 펼쳐진다(숫자 상자 → 쉬운 설명 → 출처 → 행동 버튼).
  Widget _registryChapter(BuildContext context, AnalysisReport report) {
    final findings = sortBySeverity([
      for (final e in report.evidences)
        if (!_isPendingBlacklist(e)) e,
    ]);
    return Padding(
      key: const ValueKey('report-chapter-registry'),
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppText(
                '1 / 5',
                style: AppTypographyNext.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColorsNext.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 14,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 4),
                    AppText(
                      'AI 분석',
                      style: AppTypographyNext.caption.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          AppText(
            '등기부에서 찾은 것',
            style: AppTypographyNext.headline.copyWith(
              color: AppColorsNext.textStrong,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _originPhotoEntry(context, report),
          const SizedBox(height: 18),
          FindingsSummary(items: findings),
          const SizedBox(height: 10),
          FindingsCard(
            items: findings,
            actionFor: (e) => _evidenceAction(context, report, e),
            // 처음엔 모두 접어 둔다 — 요약 한 줄 + 제목 목록이 먼저 보이게 (2026-10-30 규혁)
            expandedIndex: null,
          ),
        ],
      ),
    );
  }

  Widget _originPhotoEntry(BuildContext context, AnalysisReport report) {
    final paths = RegistryPhotoStore.instance.pathsFor(report.id);
    final hasPhotos = paths.isNotEmpty;

    // 그릴 수 있는 표시만 — 사진 장수를 넘는 page 인덱스는 버린다(뷰어와 같은 규칙).
    final marks = [
      for (final h in report.highlights)
        if (h.page >= 0 && h.page < paths.length) h,
    ];
    final preview = previewMarkOf(marks);

    return RegistryEntryCard(
      // 등기부 날짜는 리포트 맨 위로 옮겼다(리포트 전체가 그 날짜 기준) · 이름 가림 안내는 마이에서 (2026-10-28)
      subtitle: hasPhotos
          ? null
          : '이 폰에 사진이 없어요',
      onTap: hasPhotos ? () => context.push('/registry/${report.id}') : null,
      preview: preview == null
          ? null
          : RegistryPreviewSource(
              path: paths[preview.page],
              mark: preview,
              // 뱃지는 **따져볼 곳만** 센다. 집주인 이름·주소는 위험이 아니라
              // 대조할 곳이라, 전체 개수를 적으면 사실과 다른 말이 된다.
              examineCount: MarkLegend.examineCount(
                marks.map((m) => m.markKind),
              ),
              totalCount: marks.length,
              // '사진 속 이름 가리기'가 켜지면 스트립에 함께 비치는 이름 칸도 덮는다.
              pageMarks: [
                for (final m in marks)
                  if (m.page == preview.page) m,
              ],
              // 서버가 찾은 나머지 실명·주민번호 자리(채무자 줄 등 — §9.8)까지 덮는다.
              privacyBoxes: report.privacyBoxesOn(preview.page),
              namesUnlocated: report.namesUnlocatedOn(preview.page),
              // 가로·거꾸로 찍은 장은 서버가 바로 세운 각도만큼 돌려 그린다 (§9.12)
              quarterTurns: report.quarterTurnsOf(preview.page),
            ),
    );
  }

  /// 등기부를 뗀 지 며칠 됐나 — 리포트는 **분석한 날이 아니라 등기부를 뗀 날** 기준이다(2026-10-30 규혁).
  ///
  /// 예전엔 '분석한 지 하루 지났다'는 노란 배너를 맨 위에 끼웠다 — 분석일은 중요하지 않고 구조만 흐트렸다.
  /// 계약 직전 근저당 설정은 실제 전세사기 수법이라 **오래된 등기부**인 것만 결론 아래 한 줄로 말한다.
  /// 새로 떼서 대조하는 길은 계약 여정에 있다.
  int? _registryAgeDays(AnalysisReport report) {
    final viewed = parseRegistryViewedAt(report.registryViewedAt);
    return viewed == null ? null : daysSince(viewed);
  }

  /// 무엇이 표시됐는지 **종류별 개수로** — `집주인 이름 1곳과 빚 3건을 사진 위에 표시했어요`.
  ///
  /// 지금은 진입 카드가 열람일을 쓰느라 화면에 나가지 않지만, 조립 로직은 남겨 둔다
  /// (종류가 늘면 그대로 따라오는 문구라 다시 쓸 자리가 있다 — 2026-07-27 사용자 지시).
  String originPhotoSummary(AnalysisReport report) {
    final phrase = MarkLegend.countPhrase(
      report.highlights.map((h) => h.markKind),
    );
    if (phrase.isEmpty) return '올린 사진을 다시 볼 수 있어요';
    return '$phrase${MarkLegend.eul(phrase)} 사진 위에 표시했어요';
  }

  /// 등급 → 마스코트 상태 (양호=safe, 확인필요=caution, 위험=danger)
  MascotState _mascotForGrade(RiskGrade grade) => switch (grade) {
    RiskGrade.danger => MascotState.danger,
    RiskGrade.caution => MascotState.caution,
    RiskGrade.ok => MascotState.safe,
  };

  /// 결론 헤더 — 등급 크게 + 의사결정 한 줄 + 보증금 (IA §0 + 서연 리뷰 반영)
  Widget _conclusionHeader(AnalysisReport report) {
    // 2026-08-03: 시세가 자동 조회에서도 올 수 있게 되면서 "(입력값)"이 거짓이 될 수
    // 있다. 출처를 하드코딩하지 않고 서버가 알려 준 대로 말한다.
    final String priceText = report.marketPrice != null
        ? '보증금 ${formatWon(report.deposit)} · 시세 ${formatWon(report.marketPrice!)}'
        : '보증금 ${formatWon(report.deposit)} · 시세를 못 구했어요';

    return Column(
      children: [
        SafetyGauge(
          grade: report.grade,
          progress: report.gaugeProgress,
          // 리포트 전체가 이 등기부 기준이다 — 분석한 날보다 등기부를 뗀 날이 중요하다(2026-10-30)
          caption: report.registryViewedAt != null
              ? '${report.registryViewedAt} 등기부 기준'
              : '${formatDate(report.analyzedAt)} 분석',
          size: 190,
        ),
        const SizedBox(height: AppSpacing.md),
        AppText(
          report.headline,
          style: AppTypography.headline,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        // 진행/보류/회피 의사결정 대응 — 문구는 E-1에서 등급 체계와 함께 확정
        RiskBadge(
          grade: report.grade,
          labelOverride: report.grade.decisionLabel,
          large: true,
        ),
        const SizedBox(height: AppSpacing.md),
        // 등급별 마스코트 — 게이지(190)·헤드라인·배지 '뒤'에 작게 둔다.
        // 보수적 편향(decisions.md 2026-07-09): 위험할수록 마스코트를 더 작게 해
        // 경고(게이지·배지·문구)가 항상 주인공이게 한다 (페르소나 2인 리뷰 반영 —
        // 서연: 위험일수록 작게 / 지수: 걱정 표정이 경고를 보강하므로 유지).
        // danger를 가장 작게(경고 우선). 양호(safe)는 반짝이 축하 연출이 강해
        // '안전 단언' 인상을 줄 수 있어 크게 키우지 않는다(design-reviewer 지적 반영).
        MascotSafe(
          size: report.grade == RiskGrade.danger ? 40 : 48,
          state: _mascotForGrade(report.grade),
        ),
        const SizedBox(height: AppSpacing.md),
        AppText(
          report.address,
          style: AppTypography.caption,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xs),
        AppText(
          priceText,
          style: AppTypography.caption.copyWith(
            color: AppColors.textBody,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        // 오래된 등기부만 한 줄로 — 날짜는 게이지 아래에 있다 (2026-10-30)
        if (_registryAgeDays(report) case final int days when days >= 1) ...[
          const SizedBox(height: AppSpacing.xs),
          AppText(
            '$days일 전에 뗀 등기부예요',
            key: const ValueKey('report-registry-date'),
            style: AppTypography.caption.copyWith(
              color: AppColors.caution,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        // ── [D4 · 2026-08-14] 시세 출처 칩을 화면에서 뺐다 ──────────────────────
        // 실기기에서 결론 바로 아래 "자동 조회 · 공시가격 기준 (2025.1.1)"이 붙으니,
        // 등급을 읽어야 할 자리에서 시선이 출처 문자열로 새 나갔다.
        //
        // ⚠ **출처 표기 자체를 버린 것이 아니다.** 서버 응답의 marketPriceSource ·
        //   marketPriceAsOf · marketPriceSampleCount는 그대로 살아 있고
        //   (analysis_report.dart), 모델·계약도 손대지 않았다. 여기 렌더링만 뺐다.
        //   되돌리려면 아래 주석을 그대로 살리고 파일 상단의
        //   `marketPriceSourceLabel` import 주석만 함께 풀면 된다.
        //
        // const SizedBox(height: AppSpacing.xs),
        // Center(
        //   child: AmberHint(
        //     tone: report.marketPrice == null
        //         ? AmberHintTone.amber
        //         : (report.marketPriceSource.isAuto
        //               ? AmberHintTone.positive
        //               : AmberHintTone.neutral),
        //     icon: report.marketPrice == null
        //         ? Icons.help_outline
        //         : (report.marketPriceSource.isAuto
        //               ? Icons.verified_outlined
        //               : Icons.edit_outlined),
        //     text: marketPriceSourceLabel(
        //       source: report.marketPriceSource,
        //       asOf: report.marketPriceAsOf,
        //       sampleCount: report.marketPriceSampleCount,
        //       hasPrice: report.marketPrice != null,
        //     ),
        //   ),
        // ),
      ],
    );
  }

  /// 시세 괴리 정보 카드 — 실거래가와 정부 공시 기준이 **둘 다** 있을 때만 나온다.
  ///
  /// 왜 이걸 보여 주나: 실거래가는 조작할 수 있지만 공시가격은 정부가 매긴다.
  /// 신축 빌라를 실제 가치보다 비싸게 매매한 것처럼 신고(자전거래)해 부풀린 실거래가를
  /// 근거로 보증금을 높게 받는 것이 빌라 전세사기의 전형이다.
  ///
  /// ⚠ **판정이 아니라 정보다.** 임계값의 권위 있는 출처가 없어 등급을 바꾸지 않는다.
  ///   그래서 근거 카드(`_evidenceCard`) 대열에 끼우지 않고 **아래에 따로** 붙이고,
  ///   등급 색(danger/caution)이 아니라 정보 톤(info)을 쓴다 — 새 컴포넌트를 만들지 않고
  ///   기존 `AppCallout`을 재사용해 과하지 않게 앉힌다.
  Widget? _priceGapCard(AnalysisReport report) {
    final int? gap = report.marketPriceGapPct;
    if (gap == null) return null;

    // 잠정 임계값 — 서버(price_resolver)와 같은 값이다. 실측 후 함께 조정한다.
    const int inflated = 50;
    const int depressed = -30;

    final String title;
    final String text;
    final CalloutTone tone;
    if (gap >= inflated) {
      tone = CalloutTone.caution;
      title = '실제 거래값이 공시 기준보다 $gap% 높아요';
      text = '값을 부풀린 뒤 보증금을 높게 받는 수법이 있어요. 가격이 어떻게 정해졌는지 물어보세요.';
    } else if (gap <= depressed) {
      tone = CalloutTone.caution;
      title = '실거래가가 공시 기준보다 ${gap.abs()}% 낮아요';
      text = '시세가 내려가고 있을 수 있어요. 계약 때 시세를 한 번 더 확인하세요.';
    } else {
      tone = CalloutTone.info;
      title = '실제 거래값과 공시 기준이 비슷해요';
      text = '차이는 $gap%예요.';
    }

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: AppCallout(
        tone: tone,
        icon: Icons.balance,
        title: title,
        // 이 카드는 '정보'라는 것을 문장으로도 못 박는다 — 등급이 바뀐 줄 알면 안 된다.
        text: '$text\n※ 참고 정보예요 — 등급 계산에는 넣지 않아요.',
      ),
    );
  }

  // ── [D15 · 2026-08-14] 상단 '중개사 질문 모아 보기' 버튼을 지웠다 ───────────
  //
  // D5에서 '지금 해야 할 일' 박스를 걷어내고 그 안의 버튼만 결론 헤더 밑에 남겼었다.
  // 그때의 이유는 "질문으로 가는 길이 스크롤 없이 닿는 곳에 하나는 있어야 한다"였다.
  //
  // 그 이유가 D12(다음 행동 2×2 그리드)로 사라졌다. 지금은 [중개사에게 물어볼 질문]이
  // 네 칸 중 첫 칸으로 **항상 같은 자리에** 있어, 같은 기능의 입구가 한 화면에 둘이다.
  // 실기기에서 보니 결론(게이지·등급·주소·보증금)과 '내가 올린 사진에서 보기' 카드
  // 사이를 초록 아웃라인 버튼이 가로질러, 결론에서 근거로 내려가는 시선이 한 번 끊겼다.
  //
  // ⚠ 기능을 없앤 것이 아니다. `/questions/:id` 로 가는 길은 그대로 셋이다 —
  //   하단 2×2의 첫 칸(근거 카드의 '질문 보기' 액션은 2026-10-28에 뺐다),
  //   그리고 판례 화면. 여기서는 **중복된 입구 하나**만 지웠다.

  /// 근거 카드의 행동 버튼. **실제로 도는 것만** 그린다 — "곧 제공" 같은 가짜 버튼을 두지 않는다
  /// (2026-10-23 서연 리뷰 #4: 심사위원이 누르면 끝). 모르는 라벨이거나 지금 할 수 없으면 null(버튼 없음).
  Widget? _evidenceAction(
    BuildContext context,
    AnalysisReport report,
    EvidenceItem evidence,
  ) {
    final String? label = evidence.actionLabel;
    if (label == null) return null;
    final VoidCallback? onPressed = switch (label) {
      // '중개사에게 물어볼 질문 보기'는 리포트에서 뺐다 — 질문은 따로 항목이 있다 (2026-10-28)
      // 시세를 넣고 같은 사진·같은 보증금으로 새로 분석 — 사진이 이 폰에 없으면 버튼을 그리지 않는다
      // 시세를 넣어 같은 등기부로 다시 판정 — 고치기 시트의 시세 칸으로 연다(2026-10-29, 기록이 두 줄로 남지 않는다).
      // 숫자를 고칠 수 없는 옛 리포트(서버 재료도 폰 사진도 없음)면 버튼을 그리지 않는다
      '시세 입력하기' =>
        canEditReportNumbers(report)
            ? () => _editInputs(context, report, focusPrice: true)
            : null,
      // 단독·다가구: 앞순위 보증금은 등기부에 없다 — 집주인·중개사에게 서류를 달라고 할 문자를 공유 창으로
      '앞순위 보증금 확인하기' => () => shareWithFeedback(
        context,
        _priorDepositRequest(report),
      ),
      _ => null,
    };
    if (onPressed == null) return null;
    // F3: 근거 카드는 흰 표면이므로 라인 대신 톤(연초록) 버튼
    return AppCompactButton(label: label, tonal: true, onPressed: onPressed);
  }

  /// 앞순위 보증금을 확인할 서류를 달라는 문자 — 서버 근거 상세의 말(전입세대 열람내역·확정일자 부여현황)만 쓴다.
  String _priorDepositRequest(AnalysisReport report) {
    final address = report.address.trim();
    return [
      '안녕하세요. 계약 전에 저보다 먼저 들어온 세입자들의 보증금(앞순위 보증금)을 확인하고 싶어요.',
      if (address.isNotEmpty) '집: $address',
      "'전입세대 열람내역'과 '확정일자 부여현황'을 보여 주실 수 있을까요?",
    ].join('\n');
  }

  /// 다음 행동 — 예전 2×2 그리드(2026-08-14 D12)의 칸이 리포트 장으로 하나씩 올라가
  /// (손실 → 2장, 판례 → 3장, 질문 → 4장 · 2026-10-29) **계약 여정 한 줄**만 남았다.
  List<Widget> _actionArea(BuildContext context, AnalysisReport report) {
    // '중개사에게 물어볼 질문'은 리포트 4장으로 올라갔다 (2026-10-29) — 남은 건 계약 여정 하나라
    // 반쪽 칸 대신 한 줄 넓은 카드로 그린다.
    void openJourney() {
      // 이 리포트의 집 여정을 연다 — 마지막으로 골라 둔 다른 집이 열리지 않게 (2026-10-29)
      JourneyScheduleStore.instance.select(propertyKeyOfReport(report, _history));
      context.push('/checklist');
    }

    return [
      AppCard(
        key: const ValueKey('report-action-journey'),
        onTap: openJourney,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(
              Icons.fact_check_outlined,
              color: AppColors.primary,
              size: AppSize.iconLg,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AppText('계약 여정', style: AppTypography.bodyStrong),
            ),
            Icon(Icons.chevron_right, color: AppColors.primary),
          ],
        ),
      ),
    ];
  }

  /// D4: 전역 면책 안내 — 리포트 최하단 상시 노출(캡처 공유 시 자연 포함).
  /// AA 통과 색(textMuted)·가독 가능한 크기 유지 — 면책의 보호 목적을 지키기 위해
  /// 일부러 최소 크기로 줄이지 않는다.
  ///
  /// [D6 · 2026-08-14] 명단 미구축이면 그 사실을 여기 한 줄로 얹는다. 근거 카드에서
  /// 뺐다고 **침묵하면 안 된다** — 안 본 것을 안 봤다고 말하는 것이 이 앱의 원칙이고,
  /// 침묵은 "명단까지 확인했다"는 오해를 남긴다. 대신 색은 면책보다 진하게 둔다
  /// (textBody) — 회색으로 묻히면 고지의 목적을 잃는다.
  Widget _disclaimer(AnalysisReport report) {
    final bool blacklistPending = report.evidences.any(_isPendingBlacklist);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (blacklistPending) ...[
            AppText(
              '※ 악성임대인 명단은 이번에 대조하지 못했어요 — HUG 안심전세포털에서 집주인 이름을 직접 확인하세요.',
              style: AppTypography.caption.copyWith(color: AppColors.textBody),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          AppText(
            '참고용 분석이에요. 계약의 안전을 보증하지 않아요 — 최종 판단은 공식 서류와 전문가 상담으로 하세요.',
            style: AppTypography.caption.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
