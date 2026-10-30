/// S-13 마이/설정 (탭) — IA.md §6.
///
/// 맨 위 **계정** 칸(2026-10-22 카카오 로그인 — `account_section.dart`): 로그인 상태 · 로그아웃 · 회원 탈퇴 · 개인정보 처리방침.
/// 분석 이력(재열람·삭제) — 로그인했으면 계정의 기록, 아니면 이 기기의 기록(서버가 가른다).
/// 공통: **개인정보** — '사진 속 이름 가리기' 스위치 + 사진을 어디에 남기는지 한 줄 (2026-10-22).
/// 맨 아래: **앱 버전·빌드 번호** 한 줄 — 7번 연속 누르면 부스 모드(로그아웃·회원 탈퇴·기록 지우기 숨김, 2026-10-23).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/config.dart' show kDevTools;
import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/property_reports.dart';
import '../../repositories/analysis_repository.dart';
import '../../services/api_client.dart';
import '../../services/journey_reminder_service.dart';
import '../../state/app_session.dart';
import '../../state/booth_mode.dart';
import '../../state/journey_progress_store.dart';
import '../../state/journey_schedule_store.dart';
import '../../state/privacy_settings.dart';
import '../../utils/money_format.dart';
import '../common/analyze_gate.dart';
import '../pricing/guardian_pass_widgets.dart';
import 'account_section.dart';
import 'app_version_line.dart';
import 'my_settings.dart';

// '사진 속 이름 가리기' 설명 문장은 처리방침 화면으로 옮겼다(2026-10-30) — 예전 이름으로도 쓸 수 있게 내보낸다.
export 'privacy_policy_screen.dart' show kHideNamesSwitchDescription;
import '../../design_system/text/app_text.dart';

class MyScreen extends StatefulWidget {
  const MyScreen({super.key});

  @override
  State<MyScreen> createState() => _MyScreenState();
}

class _MyScreenState extends State<MyScreen> {
  late Future<List<AnalysisReport>> _historyFuture;
  late final AnalysisRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = context.read<AnalysisRepository>()
      ..addListener(_onRepositoryChanged);
    _reload();
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepositoryChanged);
    super.dispose();
  }

  void _reload() {
    _historyFuture = _repo.getHistory();
  }

  /// 마지막으로 받은 전체 이력 (같은 집 지난 리포트 포함) — 삭제할 때 같은 집을 모두 찾는다
  List<AnalysisReport> _allHistory = const [];

  /// 분석·삭제, 그리고 '사진 속 이름 가리기'를 바꿨을 때(저장소가 알린다) 목록을 다시 읽는다 —
  /// 이 화면이 그 스위치가 있는 곳이라, 켜는 순간 아래 목록의 이름도 바로 가려져야 한다.
  void _onRepositoryChanged() {
    if (mounted) setState(_reload);
  }

  Future<void> _delete(AnalysisReport report) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const AppText('이 집의 리포트를 삭제할까요?'),
        content: const AppText('지난 리포트까지 모두 지워져요. 삭제하면 되돌릴 수 없어요'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const AppText('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const AppText('삭제'),
          ),
        ],
      ),
    );
    if (!(ok ?? false) || !mounted) return;
    try {
      // 같은 집의 지난 리포트까지 함께 지운다 — 최신만 지우면 그 아래 지난 리포트가 다시 '최신'으로 올라온다
      final repo = context.read<AnalysisRepository>();
      final versions = versionsOf(report, _allHistory);
      for (final v in versions) {
        await repo.deleteReport(v.id);
      }
      await _forgetJourney(report);
    } on ApiException catch (e) {
      // 서버 연결 실패 등 — 서버가 준 한국어 메시지 그대로 표시
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: AppText(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: AppText('삭제하지 못했어요. 다시 시도해 주세요')),
          );
      }
    }
    if (mounted) setState(_reload);
  }

  /// 집을 지우면 그 집의 **계약 일정·여정 기록·알림**도 지운다 (2026-10-27).
  ///
  /// 지우지 않으면 같은 집을 다시 분석했을 때 예전 일정(잔금 10/25 …)과 대조 기록이 저절로 채워져 보여
  /// "미리 넣어 둔 값"처럼 읽혔다(실기기 시험). 일정·기록은 이 폰에만 있으므로 여기서 지운다.
  Future<void> _forgetJourney(AnalysisReport report) async {
    final all = _allHistory.any((r) => r.id == report.id)
        ? _allHistory
        : [report, ..._allHistory];
    String? key;
    for (final p in groupByProperty(all)) {
      if (p.reports.any((r) => r.id == report.id)) key = p.key;
    }
    if (key == null) return;
    try {
      await JourneyScheduleStore.instance.save(key, const JourneySchedule());
      await JourneyReminderService.instance.sync(
        propertyKey: key,
        alias: report.alias,
        schedule: const JourneySchedule(),
      );
      await JourneyProgressStore.instance.forget(key);
    } catch (e) {
      debugPrint('[여정] 지운 집의 일정·기록을 정리하지 못했어요 (${e.runtimeType})');
    }
  }

  /// 마지막으로 그린 로그인 상태 — 로그인·로그아웃·탈퇴로 바뀌면 이력을 다시 읽는다
  /// (로그인하면 이 기기의 기록이 계정으로 옮겨지고, 로그아웃하면 기기 쪽 기록만 보인다).
  bool? _shownLoggedIn;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    if (_shownLoggedIn != null && _shownLoggedIn != session.isLoggedIn) {
      _reload();
    }
    _shownLoggedIn = session.isLoggedIn;

    return Scaffold(
      appBar: AppBar(
        title: const AppText('마이'),
        automaticallyImplyLeading: false,
      ),
      // 2026-10-30 다시 그림: 프로필 → 패스 띠 → 분석 이력 → 설정 묶음(화면 모드 · 이름 가리기 · 계정) → 버전.
      // 설명 문장은 모두 뺐다(규혁: 글씨 많은 걸 싫어해) — 이름 가리기·사진 보관 설명은 개인정보 처리방침에 있다.
      body: ListenableBuilder(
        listenable: BoothMode.instance,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            AppSpacing.sm,
            AppSpacing.screenPadding,
            AppSpacing.xxxl,
          ),
          children: [
            const AccountSection(),
            const SizedBox(height: 12),
            // 요금제 · 계약 지킴이 패스 (2026-10-22, P2-1) — 가격은 예시, 결제는 테스트 결제
            const GuardianPassEntry(),
            const SizedBox(height: 28),
            _sectionTitle('분석 이력'),
            _historyList(),
            const SizedBox(height: 28),
            _sectionTitle('설정'),
            const SettingsGroup(
              children: [
                SettingsRow(
                  icon: Icons.contrast_rounded,
                  title: '화면 모드',
                  trailing: ThemeModeSelector(),
                ),
                PrivacySettingsCard(),
              ],
            ),
            const SizedBox(height: 12),
            // 이용약관 · 개인정보 처리방침(굵게) · 데이터 출처 · 오픈소스 라이선스 (2026-10-30)
            const PolicySettingsRows(),
            // 로그아웃 · 회원 탈퇴 — 로그인했을 때만(부스 모드면 숨김)
            const AccountSettingsRows(),
            const SizedBox(height: AppSpacing.lg),
            // 앱 버전 — 부스에서 최신 APK인지 확인. 7번 연속 누르면 부스 모드(state/booth_mode.dart)
            const AppVersionLine(),
            // 개발 도구(`--dart-define=DEV_TOOLS=true`일 때만) — 서버 없이 로딩 화면만 띄워 핫 리로드로 다듬는다
            if (kDevTools)
              TextButton(
                onPressed: () => context.push('/dev/loading'),
                child: const AppText('개발: 로딩 화면 미리보기'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
    child: AppText(text, style: AppTypographyNext.title),
  );

  Widget _historyList() {
    return FutureBuilder<List<AnalysisReport>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          // 서버 연결 실패 — 빈 상태로 위장하지 않음 (D-3: 더미 폴백 금지)
          return AppCard(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              children: [
                AppText(
                  '분석 이력을 불러오지 못했어요',
                  style: AppTypography.bodyStrong,
                ),
                const SizedBox(height: AppSpacing.xs),
                AppText(
                  apiErrorHint(snapshot.error, fallback: '서버 연결을 확인해 주세요'),
                  textAlign: TextAlign.center,
                  style: AppTypography.caption,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppCompactButton(
                  label: '다시 시도',
                  icon: Icons.refresh,
                  onPressed: () => setState(_reload),
                ),
              ],
            ),
          );
        }
        // 같은 집은 최신 리포트 1개만 — 지난 리포트는 리포트 화면의 시계 버튼에서 본다 (2026-10-26)
        _allHistory = snapshot.data ?? const [];
        final history = latestPerProperty(_allHistory);
        if (history.isEmpty) {
          return AppCard(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              children: [
                AppText('아직 분석한 매물이 없어요', style: AppTypography.bodyStrong),
                const SizedBox(height: AppSpacing.md),
                AppCompactButton(
                  label: '매물 분석 시작하기',
                  onPressed: () => startAnalysis(context),
                ),
              ],
            ),
          );
        }
        return Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (int i = 0; i < history.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 18,
                    endIndent: 18,
                    color: AppColorsNext.divider,
                  ),
                _historyRow(history[i]),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 이력 한 줄 — 별칭 · 날짜·보증금 · 등급 (+ 지우기)
  Widget _historyRow(AnalysisReport report) {
    return InkWell(
      onTap: () => context.push('/report/${report.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 6, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    report.alias,
                    style: AppTypographyNext.bodyStrong.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColorsNext.textStrong,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  AppText(
                    // 한 줄에 들어가게 짧게 — 분석한 날(월.일) · 보증금
                    '${report.analyzedAt.month}.${report.analyzedAt.day} · ${formatWon(report.deposit)}',
                    style: AppTypographyNext.caption.copyWith(
                      color: AppColorsNext.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            RiskBadge(grade: report.grade),
            // 부스 모드에서는 기록 지우기를 숨긴다 — 관람객이 시연 기록을 지우지 않게(state/booth_mode.dart)
            if (BoothMode.instance.on)
              const SizedBox(width: 12)
            else
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: AppSize.iconSm,
                  color: AppColorsNext.textMuted,
                ),
                tooltip: '삭제',
                onPressed: () => _delete(report),
              ),
          ],
        ),
      ),
    );
  }
}

/// 설정 묶음의 '사진 속 이름 가리기' 줄 — 위젯 테스트에서 단독으로 띄울 수 있게 뺐다.
///
/// 켜면 '내가 올린 사진에서 보기'와 리포트 미리보기에서 **분석한 사진 속 이름·주민번호 칸 전부**를 상자로 덮고,
/// 리포트 글자 속 사람 이름을 `홍○○`로 바꾼다(api-contract §9.8). 이름 자리를 모르는 쪽은 통째로 덮는다.
/// 꺼 두는 것이 기본인 이유: 내 폰의 내 등기부에서는 그 이름을 계약 상대 신분증과 **대조하는 것**이 목적이다.
class PrivacySettingsCard extends StatelessWidget {
  const PrivacySettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = PrivacySettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => SettingsRow(
        icon: Icons.visibility_off_outlined,
        title: '사진 속 이름 가리기',
        onTap: () => settings.setHideNamesInPhotos(!settings.hideNamesInPhotos),
        trailing: Switch(
          key: const ValueKey('hide-names-switch'),
          value: settings.hideNamesInPhotos,
          onChanged: settings.setHideNamesInPhotos,
        ),
      ),
    );
  }
}
