/// 챗봇이 알아야 할 **지금 보고 있는 리포트** (2026-10-26 — "챗봇이 내 리포트를 알아야 맞춤으로 답한다").
///
/// 리포트 화면이 열리면 그 리포트로 바뀐다. 챗봇은 질문을 보낼 때 이 리포트의 id를 함께 보내고,
/// 서버가 그 리포트(이 사용자 것만 · 사람 이름을 가린 사본)를 읽고 답한다. 판정은 바꾸지 않는다.
/// 리포트를 한 번도 안 열었으면 챗봇이 **가장 최근 리포트**로 채운다([GlossaryChatbotScreen]).
library;

import 'package:flutter/foundation.dart';

@immutable
class ReportRef {
  const ReportRef(this.id, this.alias);

  final String id;

  /// 화면에 보여 줄 이름(매물 별칭)
  final String alias;
}

abstract final class ReportFocus {
  /// 지금 챗봇이 아는 리포트 — 없으면 null(리포트 없이 일반 답)
  static final ValueNotifier<ReportRef?> current = ValueNotifier<ReportRef?>(null);
}
