/// 마스코트 '세이프' — **플레이스홀더**.
///
/// 팀에서 마스코트 이미지(목업 초안의 흰 강아지)가 도착하면 이 위젯 내부만
/// Image.asset으로 교체한다. 사용처(홈 인사·로딩·챗봇 아바타)는 바뀌지 않는다.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

class MascotSafe extends StatelessWidget {
  const MascotSafe({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    // TODO(팀): 마스코트 이미지 자산 도착 시 Image.asset으로 교체
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.primarySoft,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.pets, size: size * 0.5, color: AppColors.primary),
    );
  }
}
