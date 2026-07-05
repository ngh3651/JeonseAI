// D-3 "서버 끄면 못 불러온다" 증명 — **서버를 끈 상태에서** 명시적으로 실행한다:
//   flutter test test_live/api_down_test.dart
//
// Api 리포지토리가 더미로 폴백하지 않고 ApiException을 던지는지 확인한다.
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/repositories/api_analysis_repository.dart';
import 'package:jeonse_ai/repositories/api_content_repository.dart';
import 'package:jeonse_ai/services/api_client.dart';

void main() {
  test('서버가 꺼져 있으면 이력·여정 로드가 ApiException으로 실패한다 (폴백 없음)', () async {
    await expectLater(
      ApiAnalysisRepository().getHistory(),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      ApiContentRepository().journeyStages(),
      throwsA(isA<ApiException>()),
    );
  });
}
