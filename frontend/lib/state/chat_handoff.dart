/// 다른 화면에서 고른 글자를 챗봇으로 넘기는 자리 (2026-10-26 '꾹 눌러 챗봇에 묻기').
///
/// 여정·판례·리포트에서 글자를 꾹 눌러 [챗봇에 묻기]를 누르면 여기에 그 글을 놓고 챗봇 탭으로 간다.
/// 챗봇 화면이 받아서 **인용 띠**(입력칸 위)로 보여 주고 입력칸에 커서를 둔다 — 사용자가 이어서 묻는다.
library;

import 'package:flutter/foundation.dart';

abstract final class ChatHandoff {
  /// 챗봇이 아직 받지 않은 글. 챗봇이 받으면 null로 비운다.
  static final ValueNotifier<String?> pending = ValueNotifier<String?>(null);

  /// 인용으로 넘길 글의 최대 길이 — 길게 고르면 앞부분만 (질문 500자 제한 안에서 인용 띠가 화면을 덮지 않게)
  static const int maxLength = 200;

  /// 홈 '궁금한 건 바로 물어보세요'의 질문 칩 — 챗봇이 받자마자 **바로 보낸다** (2026-10-30 홈 리뉴얼).
  static final ValueNotifier<String?> question = ValueNotifier<String?>(null);

  /// 홈 입력칸을 눌렀다 — 챗봇이 받으면 입력칸에 커서를 두고 키보드를 연 뒤 false로 비운다.
  static final ValueNotifier<bool> focusInput = ValueNotifier<bool>(false);

  static void ask(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    question.value = t;
  }

  static void focus() {
    focusInput.value = false;
    focusInput.value = true;
  }

  static void send(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    pending.value = t.length > maxLength ? '${t.substring(0, maxLength)}…' : t;
  }
}
