/// 등기부등본 이미지 업로드 서비스 — **검증 완료 자산 (실기기 E2E 확인)**.
///
/// Phase C 재구축 이전 main.dart에서 검증된 로직을 그대로 보존한 모듈입니다.
/// Phase E-1(업로드 → Information Extract 교체)에서 재사용합니다.
///
/// 핵심 규칙 (decisions.md 2026-07-01):
/// - 갤럭시 카메라의 HEIC/HEIF 등 어떤 형식이 들어와도 **항상 JPEG로 변환** 후 전송
/// - 업로드 시 Content-Type을 **image/jpeg로 명시** (미명시 시 octet-stream으로
///   전송되어 백엔드가 거부함)
library;

import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

/// 서버로 보낼 사진의 **짧은 변** 크기(px) — 원본이 더 크면 짧은 변이 이 값이 되게 줄이고, 작으면 그대로 둔다.
///
/// 2026-11-03 마지막 정리 (규혁: "화소 늘린 게 필요 없고 용량만 먹으면 돌려놔도 좋다"):
/// - 태블릿만 2560으로 올렸던 것을 **되돌린다.** 같은 4쪽 등기부에서 사진 용량이 2.6MB → 7.6MB가 되어
///   올리는 데 +4초, IE가 +5초 늘었는데, 형광펜을 놓친 까닭(말소 줄 연결·순위번호 한 글자·회사 이름)은
///   화소와 상관이 없었다(2560에서도 똑같이 놓침 — 진단 로그).
/// - 대신 **가로·세로 같은 값**을 준다. 예전 라이브러리 기본값(가로 1920·세로 1080)은 기기를 **가로로** 들고 찍으면
///   짧은 변이 1080~1440까지 줄었다. 이제 어느 방향이든 짧은 변 1920(세로로 찍은 사진은 예전과 똑같다).
const int kUploadShortSide = 1920;

/// 압축 크기 기준 (minWidth, minHeight) — 기기·방향과 상관없이 짧은 변 [kUploadShortSide].
(int, int) uploadMinSize() => (kUploadShortSide, kUploadShortSide);

class RegistryUploadService {
  /// 입력 이미지를 JPEG로 변환합니다.
  ///
  /// 안드로이드 네이티브 코덱을 사용하므로 HEIC/HEIF도 디코딩할 수 있습니다.
  /// (순수 Dart 이미지 라이브러리는 HEIC 디코딩을 지원하지 않아 flutter_image_compress 사용)
  /// 실패 시 null을 반환하고, 호출부에서 한국어 안내 메시지를 표시합니다.
  /// [tag]는 파일 이름을 구분하기 위한 접미사(여러 장을 연속 변환할 때 필수).
  /// 밀리초 타임스탬프만으로는 **같은 밀리초에 두 장이 변환되면 파일이 덮어써져**
  /// 두 페이지가 같은 사진을 가리키게 된다 → 하이라이트 좌표가 엉뚱한 장에 그려진다.
  Future<File?> convertToJpeg(String sourcePath, {String tag = ''}) async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String suffix = tag.isEmpty ? '' : '_$tag';
      final String targetPath =
          '${tempDir.path}/upload_${DateTime.now().millisecondsSinceEpoch}$suffix.jpg';

      final (minWidth, minHeight) = uploadMinSize();
      final XFile? converted = await FlutterImageCompress.compressAndGetFile(
        sourcePath,
        targetPath,
        format: CompressFormat.jpeg,
        quality: 90, // OCR 가독성을 위해 화질을 비교적 높게 유지
        // 짧은 변 1920(가로·세로 같은 값 = 찍은 방향과 상관없이 같은 크기) — 위 [uploadMinSize]
        minWidth: minWidth,
        minHeight: minHeight,
        // EXIF 회전을 **픽셀에 반영해 올바로 세운 뒤 EXIF 자체는 남기지 않는다**.
        // 이래야 서버(Pillow)가 재는 크기와 앱(Flutter 디코더)이 그리는 크기가 같아진다.
        // EXIF 방향 태그가 남으면 한쪽만 회전을 적용해 좌표가 통째로 어긋난다.
        autoCorrectionAngle: true,
        keepExif: false,
      );

      if (converted == null) return null;
      return File(converted.path);
    } catch (_) {
      return null; // 호출부에서 사용자 안내 처리
    }
  }
}
