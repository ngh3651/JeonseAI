/// 분석에 **실제로 전송한 JPEG 파일 경로**를 세션 동안만 들고 있는 저장소.
///
/// 왜 필요한가:
/// 서버가 주는 하이라이트 좌표는 **서버로 보낸 그 JPEG의 픽셀 기준**이다. 화면에
/// 갤러리 원본을 띄우면 해상도·회전이 달라 좌표가 전부 어긋난다. 그래서 업로드에 쓴
/// 그 파일을 그대로 다시 그려야 한다.
///
/// 왜 메모리에만 두는가:
/// **사진 영구 저장은 이번 범위 밖이다.** 등기부 사진에는 소유자 실명·주소가 있어
/// 함부로 남길 것이 아니다. 앱을 껐다 켜면 사라지고, 그러면 뷰어 진입점도 사라진다
/// (이력에서 다시 연 리포트는 사진이 없으므로 '원본에서 보기'가 나타나지 않는다).
///
/// 경로는 `getTemporaryDirectory()` 안이라 OS가 임의로 지울 수 있다. 그래서 읽는 쪽은
/// **파일이 실제로 있는지 항상 확인**한다(`pathsFor`).
library;

import 'dart:io';

class RegistryPhotoStore {
  RegistryPhotoStore._();

  static final RegistryPhotoStore instance = RegistryPhotoStore._();

  final Map<String, List<String>> _byReportId = {};

  /// 분석 직후 호출 — 리포트 id에 전송한 JPEG 경로들을 묶어 둔다.
  void register(String reportId, List<String> jpegPaths) {
    _byReportId[reportId] = List.unmodifiable(jpegPaths);
  }

  /// 이 리포트로 볼 수 있는 사진 경로들. **지금 실제로 존재하는 파일만** 돌려준다.
  ///
  /// 한 장이라도 사라졌으면 좌표와 사진의 순서가 어긋나므로 **전부 없는 것으로 친다**
  /// (page 인덱스가 밀려 엉뚱한 사진에 형광펜이 그려지는 것을 막는다).
  List<String> pathsFor(String reportId) {
    final paths = _byReportId[reportId];
    if (paths == null || paths.isEmpty) return const [];
    for (final p in paths) {
      if (!File(p).existsSync()) return const [];
    }
    return paths;
  }

  bool hasPhotos(String reportId) => pathsFor(reportId).isNotEmpty;

  /// 테스트용 초기화.
  void clear() => _byReportId.clear();
}
