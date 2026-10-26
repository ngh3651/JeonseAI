/// 계약 여정을 열 때 **고를 단계** 한 번 건네기 (2026-10-27 홈 종 시트).
///
/// 홈의 '오늘 중요한 일정' 상자를 누르면 그 집 + 그날 단계(잔금·이사 …)가 선택된 채 여정이 열려야 한다.
/// 여정 탭은 살아 있는 채로 남아 있을 수 있어 길(경로) 대신 이 값을 듣는다 — 여정 화면이 쓰고 비운다.
library;

import 'package:flutter/foundation.dart';

import '../models/content_models.dart';

abstract final class JourneyFocus {
  /// 다음에 여정 화면이 고를 날 — 쓰고 나면 null로 비운다.
  static final ValueNotifier<JourneyDateKey?> pending = ValueNotifier(null);

  static void request(JourneyDateKey key) {
    // 같은 날을 두 번 눌러도 다시 알리도록 한 번 비운다
    pending.value = null;
    pending.value = key;
  }
}
