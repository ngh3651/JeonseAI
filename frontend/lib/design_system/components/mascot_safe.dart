/// 마스코트 '세이프' — 상태별 이미지 (`assets/mascot/mascot_<state>.png`).
///
/// 흰 진돗개 + 초록 반다나(방패 로고). 각 마스코트는 표정·소품(⚠·?·✓·💡 등)이
/// 박혀 있어 **자기 상태에만** 쓴다(타 상태 재사용 시 아이콘 불일치).
/// 경로 매핑은 여기 한 곳에서만 관리하고, 화면은 [MascotState]만 넘긴다.
///
/// 보수적 편향(decisions.md 2026-07-09): 위험(danger) 마스코트는 게이지·배지·경고
/// 문구보다 시각적으로 앞서지 않게 **작게·경고 뒤에** 배치한다(단독 대형 히어로 금지).
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

/// 마스코트가 표현하는 상태. enum 이름 = 파일명 접미사(`mascot_<name>.png`).
enum MascotState {
  home, // 홈/메인 진입 (인사)
  info, // 안내/설명 (빈 상태 등)
  loading, // 분석 로딩
  error, // 오류/다시 시도
  tip, // 툴팁·도움말·용어 챗봇
  danger, // 위험 결과 (걱정 표정 + ⚠)
  caution, // 확인 필요 (물음표)
  safe, // 양호 결과 (체크)
  analyzing, // 분석/검토 중 (돋보기·안경)
  complete, // 완료/안심 (집 들고 있음)
}

class MascotSafe extends StatelessWidget {
  const MascotSafe({super.key, this.size = 64, this.state = MascotState.home});

  final double size;
  final MascotState state;

  String get _assetPath => 'assets/mascot/mascot_${state.name}.png';

  @override
  Widget build(BuildContext context) {
    // 정사각 박스에 contain — 세로가 긴 마스코트라도 발자국(footprint)은 size×size로
    // 고정돼 기존 레이아웃·정렬(예: 챗봇 아바타 자리)이 흔들리지 않는다.
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        _assetPath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        // 에셋 누락 시에도 앱이 죽지 않게 — 기존 원형 플레이스홀더로 폴백
        errorBuilder: (context, error, stack) => Container(
          decoration: const BoxDecoration(
            color: AppColors.primarySoft,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.pets, size: size * 0.5, color: AppColors.primary),
        ),
      ),
    );
  }
}
