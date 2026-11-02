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

/// 서버로 보낼 사진의 **짧은 변** 최소 크기(px) — 이보다 크면 짧은 변이 이 값이 되게 줄이고, 작으면 그대로 둔다.
///
/// 2026-11-03: 예전엔 라이브러리 기본값(가로 1920·세로 1080)이라 태블릿 1300만 화소 사진이 약 500만 화소로,
/// **가로로 찍으면** 1920×1440(돌려 세우면 1440 폭)까지 줄었다 → 멀리서·비스듬히 찍으면 글자가 작아 OCR이
/// 이름·금액 위치를 놓쳤다. 가로·세로 같은 값을 줘서 방향과 상관없이 짧은 변을 2560으로 맞춘다
/// (4:3 → 2560×3413 ≈ 870만 화소). 가장 길쭉한 사진(9:21)도 서버 상한 1600만 화소(`MAX_IMAGE_PIXELS`) 안이다.
const int kUploadShortSide = 2560;

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

      final XFile? converted = await FlutterImageCompress.compressAndGetFile(
        sourcePath,
        targetPath,
        format: CompressFormat.jpeg,
        quality: 90, // OCR 가독성을 위해 화질을 비교적 높게 유지
        // 짧은 변 기준으로 줄인다(가로·세로 같은 값 = 찍은 방향과 상관없이 같은 크기) — 위 [kUploadShortSide]
        minWidth: kUploadShortSide,
        minHeight: kUploadShortSide,
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
