/// PDF 바이트를 사용자가 **받을 수 있게** 넘긴다 (2026-10-29 리포트 'PDF로 저장').
///
/// `printing`을 부르는 곳은 이 파일뿐이다 — 위젯 테스트는 [PdfSave.debugOverride]로 가짜를 넣어
/// 인쇄 창 없이 "무슨 PDF가 나갔나"만 본다.
///
/// 고른 방식: **인쇄 창(`Printing.layoutPdf`)** — 안드로이드 기본 인쇄 창은 PDF 미리보기를 보여 주고,
/// 맨 위 프린터 칸의 'PDF로 저장'을 고르면 폴더를 골라(다운로드 등) **진짜 파일로** 남는다.
/// 공유 창(`Printing.sharePdf`)은 안드로이드에 '파일에 저장' 칸이 없는 폰이 많아 "보내기"로 읽히고 저장이 헷갈린다.
/// 인쇄 창을 열지 못한 폰(인쇄 서비스가 꺼진 폰 등)만 공유 창으로 대신 연다(드라이브·내 파일 등에 저장).
///
/// ⚠ 창이 열려도 실제로 저장했는지는 알 수 없다 — 부른 화면은 "저장했어요"라고 말하지 않는다.
library;

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

/// PDF 하나를 시스템 창으로 넘긴다. 열지 못하면 예외를 던진다.
typedef SavePdfFn = Future<void> Function(Uint8List bytes, {required String name});

/// 인쇄 창 — 'PDF로 저장'.
Future<void> savePdfWithPrintDialog(Uint8List bytes, {required String name}) async {
  await Printing.layoutPdf(onLayout: (_) async => bytes, name: name, format: PdfPageFormat.a4);
}

/// 공유 창 — 인쇄 창을 못 열 때만.
Future<void> savePdfWithShareSheet(Uint8List bytes, {required String name}) async {
  await Printing.sharePdf(bytes: bytes, filename: name);
}

/// 결과 — 화면이 안내 문구를 고른다.
enum PdfSaveOutcome {
  /// 인쇄 창('PDF로 저장')을 열었다
  printDialog,

  /// 인쇄 창을 못 열어 공유 창을 열었다
  shareSheet,

  /// 둘 다 못 했다
  failed,
}

abstract final class PdfSave {
  static SavePdfFn _print = savePdfWithPrintDialog;
  static SavePdfFn _share = savePdfWithShareSheet;

  static Future<PdfSaveOutcome> save(Uint8List bytes, {required String name}) async {
    try {
      await _print(bytes, name: name);
      return PdfSaveOutcome.printDialog;
    } catch (e) {
      debugPrint('[PDF] 인쇄 창을 열지 못해 공유 창으로 대신합니다 (${e.runtimeType})');
    }
    try {
      await _share(bytes, name: name);
      return PdfSaveOutcome.shareSheet;
    } catch (e) {
      debugPrint('[PDF] 공유 창도 열지 못했어요 (${e.runtimeType})');
      return PdfSaveOutcome.failed;
    }
  }

  /// 테스트 전용 — 가짜 함수를 넣는다(null이면 원래대로).
  @visibleForTesting
  static void debugOverride({SavePdfFn? print, SavePdfFn? share}) {
    _print = print ?? savePdfWithPrintDialog;
    _share = share ?? savePdfWithShareSheet;
  }
}
