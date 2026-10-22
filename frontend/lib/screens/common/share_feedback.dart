/// 공유 창을 열고, 못 열었으면 그 사실을 한 줄로 알린다 (2026-10-23).
///
/// 공유 창이 열렸으면 아무 말도 하지 않는다 — 실제로 보냈는지는 앱이 알 수 없어서
/// "보냈어요"라고 말하면 거짓말이 된다. 못 열어 클립보드에 복사했으면 붙여 넣으라고 말한다.
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../services/text_share.dart';

Future<TextShareOutcome> shareWithFeedback(
  BuildContext context,
  String text, {
  String? subject,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await TextShare.share(text, subject: subject);
  final String? message = switch (outcome) {
    TextShareOutcome.opened => null,
    TextShareOutcome.copied => '공유 창을 열지 못해 복사해 뒀어요. 문자나 카톡 창에 붙여 넣어 주세요',
    TextShareOutcome.failed => '보내지 못했어요. 잠시 후 다시 눌러 주세요',
  };
  if (message != null) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: AppText(message)));
  }
  return outcome;
}
