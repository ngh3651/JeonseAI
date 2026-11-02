import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/services/registry_upload_service.dart';

void main() {
  test('사진 압축 크기 — 기기·방향과 상관없이 짧은 변 1920 (2026-11-03 마지막 정리)', () {
    expect(kUploadShortSide, 1920);
    expect(uploadMinSize(), (1920, 1920));
  });
}
