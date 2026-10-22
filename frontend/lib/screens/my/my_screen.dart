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

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../repositories/analysis_repository.dart';
import '../../services/api_client.dart';
import '../../state/app_session.dart';
import '../../state/booth_mode.dart';
import '../../state/privacy_settings.dart';
import '../../state/registry_photo_store.dart';
import '../../utils/money_format.dart';
import '../common/analyze_gate.dart';
import '../pricing/guardian_pass_widgets.dart';
import 'account_section.dart';
import 'app_version_line.dart';
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
    _repo = context.read<AnalysisRepository>()..addListener(_onRepositoryChanged);
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

  /// 분석·삭제, 그리고 '사진 속 이름 가리기'를 바꿨을 때(저장소가 알린다) 목록을 다시 읽는다 —
  /// 이 화면이 그 스위치가 있는 곳이라, 켜는 순간 아래 목록의 이름도 바로 가려져야 한다.
  void _onRepositoryChanged() {
    if (mounted) setState(_reload);
  }

  Future<void> _delete(AnalysisReport report) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const AppText('이 리포트를 삭제할까요?'),
        content: const AppText('삭제하면 되돌릴 수 없어요'),
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
      await context.read<AnalysisRepository>().deleteReport(report.id);
    } on ApiException catch (e) {
      // 예시 리포트 403, 서버 연결 실패 등 — 서버가 준 한국어 메시지 그대로 표시
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
      appBar: AppBar(title: const AppText('마이'), automaticallyImplyLeading: false),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          const AccountSection(),
          const SizedBox(height: AppSpacing.xxl),
          AppText('분석 이력', style: AppTypography.title),
          const SizedBox(height: AppSpacing.md),
          _historyList(),
          const SizedBox(height: AppSpacing.xxl),
          // 요금제 · 계약 지킴이 패스 (2026-10-22, P2-1) — 가격은 예시, 결제는 테스트 결제
          AppText('계약 지킴이 패스', style: AppTypography.title),
          const SizedBox(height: AppSpacing.md),
          const GuardianPassEntry(),
          const SizedBox(height: AppSpacing.xxl),
          AppText('개인정보', style: AppTypography.title),
          const SizedBox(height: AppSpacing.md),
          const PrivacySettingsCard(),
          const SizedBox(height: AppSpacing.xxl),
          // 앱 버전 — 부스에서 최신 APK인지 확인. 7번 연속 누르면 부스 모드(state/booth_mode.dart)
          const AppVersionLine(),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }

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
                const AppText('분석 이력을 불러오지 못했어요', style: AppTypography.bodyStrong),
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
        final history = snapshot.data ?? const [];
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
        return Column(
          children: [
            for (final report in history) ...[
              _historyCard(report),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }

  Widget _historyCard(AnalysisReport report) {
    return AppCard(
      onTap: () => context.push('/report/${report.id}'),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  report.alias,
                  style: AppTypography.bodyStrong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                AppText(
                  '${formatDate(report.analyzedAt)} · 보증금 ${formatWon(report.deposit)}',
                  style: AppTypography.caption,
                ),
                const SizedBox(height: 2),
                AppText(
                  report.topRiskSummary,
                  style: AppTypography.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          RiskBadge(grade: report.grade),
          // 부스 모드에서는 기록 지우기를 숨긴다 — 관람객이 시연 기록을 지우지 않게(state/booth_mode.dart)
          ListenableBuilder(
            listenable: BoothMode.instance,
            builder: (context, _) => BoothMode.instance.on
                ? const SizedBox(width: AppSpacing.sm)
                : IconButton(
                    icon: const Icon(Icons.delete_outline, size: AppSize.iconSm),
                    tooltip: '삭제',
                    onPressed: () => _delete(report),
                  ),
          ),
        ],
      ),
    );
  }
}

/// '사진 속 이름 가리기' 스위치 설명 — **실제로 가리는 범위 그대로** (테스트가 문장을 함께 본다).
///
/// 2026-10-22: 사진의 이름·주민번호 칸(서버 `privacyMasks`)에 더해 **리포트 글자 속 사람 이름**(`personNames`)도 가린다.
/// 기본은 꺼짐 — 내 폰의 내 등기부에서는 실명을 계약 상대와 대조하는 것이 목적이다. 남의 진짜 이름이
/// 큰 화면·포스터·영상에 나올 때(부스 시연·화면 캡처)만 켠다.
const String kHideNamesSwitchDescription =
    '부스 시연·화면 캡처처럼 남이 볼 때만 켜 두세요. '
    '켜면 분석한 등기부 사진과 리포트 글자 속 사람 이름을 가려요(주민번호 칸 포함). '
    '회사·은행 이름은 그대로예요. 찍는 중이거나 분석 전인 사진은 아직 가리지 못해요.';

/// 마이 화면의 '개인정보' 카드 — 위젯 테스트에서 단독으로 띄울 수 있게 뺐다.
///
/// - **사진 속 이름 가리기** (기본 꺼짐): 켜면 '내가 올린 사진에서 보기'와 리포트 미리보기에서
///   **분석한 사진 속 이름·주민번호 칸 전부**(집주인 + 서버가 찾은 채무자·이전 소유자·권리자 등 — api-contract §9.8)를
///   상자로 덮는다. 이름 자리를 모르는 쪽(옛 기록·글자를 못 읽은 쪽)은 통째로 덮는다. 부스 시연·화면 공유 전에 켠다.
///   ⚠ 분석 **전** 사진(촬영 확인 화면·사진 트레이)은 아직 위치를 몰라 가리지 못한다 — 문구에 그대로 적는다.
///   꺼 두는 것이 기본인 이유: 내 폰의 내 등기부에서는 그 이름을 계약 상대 신분증과 **대조하는 것**이 목적이다.
/// - 아래 한 줄은 사진을 어디에 남기는지([RegistryPhotoStore.retentionNotice]) — 앱 전체가 같은 문장을 쓴다.
class PrivacySettingsCard extends StatelessWidget {
  const PrivacySettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = PrivacySettings.instance;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListenableBuilder(
            listenable: settings,
            builder: (context, _) => SwitchListTile(
              value: settings.hideNamesInPhotos,
              onChanged: settings.setHideNamesInPhotos,
              title: const AppText('사진 속 이름 가리기', style: AppTypography.bodyStrong),
              // 약속을 넘지 않는다 — 덮는 것은 **분석을 마친 사진**의 이름·주민번호 칸이다(서버가 위치를 보낸다).
              // 분석 전 촬영 화면·사진 트레이는 위치를 몰라 못 덮으므로 그 사실을 함께 적는다.
              subtitle: const AppText(kHideNamesSwitchDescription, style: AppTypography.caption),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          const AppText(RegistryPhotoStore.retentionNotice, style: AppTypography.caption),
        ],
      ),
    );
  }
}
