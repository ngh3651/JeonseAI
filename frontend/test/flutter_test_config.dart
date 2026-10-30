// 모든 위젯 테스트의 공통 준비 (2026-10-30).
//
// 이용약관·개인정보 동의(ConsentStore)는 앱에서 처음 한 번 받는다. 옛 테스트들은 동의 시트를 모르고
// 시작·분석 버튼을 누르므로, 테스트마다 '이미 동의함'으로 시작한다. 동의 시트 자체는 consent_test.dart가
// 테스트 안에서 `debugReset()`으로 지우고 시험한다.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/state/consent_store.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => ConsentStore.instance.debugReset(agreed: true));
  await testMain();
}
