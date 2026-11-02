import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/services/registry_upload_service.dart';

void main() {
  group('사진 압축 크기 (2026-11-03 태블릿에만)', () {
    test('폰은 예전 그대로 — 라이브러리 기본값 1920·1080', () {
      expect(uploadMinSize(360), (1920, 1080));
      expect(uploadMinSize(411), (1920, 1080));
      expect(uploadMinSize(0), (1920, 1080)); // 화면 정보를 못 얻으면 폰으로 본다
    });

    test('태블릿은 방향과 상관없이 짧은 변 2560', () {
      expect(uploadMinSize(600), (kTabletUploadShortSide, kTabletUploadShortSide));
      expect(uploadMinSize(800), (2560, 2560));
    });
  });
}
