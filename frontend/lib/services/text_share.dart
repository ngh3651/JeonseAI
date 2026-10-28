/// 글자를 안드로이드 **공유 창**으로 보낸다 (2026-10-23 결선 부스 다듬기).
///
/// 중개사에게 보낼 문자·가족에게 보낼 일정이 모두 여기 한 곳을 지난다. (리포트는 2026-10-29부터 'PDF로 저장' — pdf_save.dart)
/// `share_plus`를 부르는 곳은 이 파일뿐이다 — 위젯 테스트는 [TextShare.debugOverride]로 가짜를 넣어
/// 공유 창 없이 "무슨 글자가 나갔나"만 본다.
///
/// ⚠ 공유 창이 열려도 실제로 보냈는지는 알 수 없다(안드로이드가 알려 주지 않는다). 그래서 부른 화면은
///   "보냈어요"라고 말하지 않는다. 열지 못하면(오래된 폰 등) 클립보드에 복사하고 그렇게 말한다.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// 글자 하나를 공유 창으로. 열지 못하면 예외를 던진다.
typedef ShareTextFn = Future<void> Function(String text, {String? subject});

/// 실제 공유 창 (share_plus).
Future<void> shareTextWithSystem(String text, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

/// 공유 결과 — 화면이 안내 문구를 고른다.
enum TextShareOutcome {
  /// 공유 창을 열었다
  opened,

  /// 공유 창을 못 열어 클립보드에 복사했다
  copied,

  /// 둘 다 못 했다
  failed,
}

abstract final class TextShare {
  static ShareTextFn _impl = shareTextWithSystem;

  /// 공유 창을 연다. 못 열면 클립보드에 복사한다(그래도 안 되면 [TextShareOutcome.failed]).
  static Future<TextShareOutcome> share(String text, {String? subject}) async {
    try {
      await _impl(text, subject: subject);
      return TextShareOutcome.opened;
    } catch (e) {
      debugPrint('[공유] 공유 창을 열지 못해 복사로 대신합니다 (${e.runtimeType})');
    }
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return TextShareOutcome.copied;
    } catch (e) {
      debugPrint('[공유] 복사도 하지 못했어요 (${e.runtimeType})');
      return TextShareOutcome.failed;
    }
  }

  /// 테스트 전용 — 가짜 공유 함수를 넣는다(null이면 원래대로).
  @visibleForTesting
  static void debugOverride(ShareTextFn? fn) => _impl = fn ?? shareTextWithSystem;
}
