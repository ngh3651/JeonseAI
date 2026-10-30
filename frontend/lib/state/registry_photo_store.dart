/// **폰 원본 보관** — 분석에 **실제로 전송한 JPEG 파일**과 **원본 리포트**(실명이 보이는 분석 응답)를 보관한다.
///
/// "폰엔 원본, 서버엔 가린 사본" (2026-10-22 규혁 결정): 서버 기록에는 사람 이름을 `홍○○`로 가린 사본만 남는다.
/// 실제 만난 계약자와 이름을 맞춰 보려면 원본이 있어야 하므로 **이 폰에만** 둔다. 리포트를 다시 열 때(기록 목록·
/// 같은 사진 캐시 적중 포함) 저장소(`ApiAnalysisRepository`)가 이 원본을 서버 사본보다 **먼저** 쓴다.
/// 기록을 지우면 [forget]이 사진·원본을 함께 지운다.
///
/// 왜 필요한가:
/// 서버가 주는 하이라이트 좌표는 **서버로 보낸 그 JPEG의 픽셀 기준**이다. 화면에
/// 갤러리 원본을 띄우면 해상도·회전이 달라 좌표가 전부 어긋난다(원본은 EXIF 회전이
/// 남아 있고 재인코딩(quality 90)도 거치지 않았다). 그래서 업로드에 쓴 **그 파일**을
/// 그대로 다시 그려야 한다 — 갤러리 경로를 기억해 두었다가 다시 읽으면 안 된다.
///
/// 보관 정책 — [keepOriginalsOnPhone] 한 줄로 갈린다:
/// - **true (기본)**: 전송한 JPEG를 앱 영구 저장소로 복사하고, 원본 리포트 JSON도 같은 폴더에 남긴다.
///   앱을 껐다 켜도 '내가 올린 사진에서 보기'와 실명 리포트가 계속 열린다.
/// - **false**: **메모리 전용**. 복사·기록·복원이 전부 꺼지고, 앱을 껐다 켜면 사진이 사라져
///   뷰어 진입점도 함께 사라진다. 리포트는 서버의 가린 사본으로 보인다.
///
/// 저장 위치·형태:
/// ```
/// <getApplicationDocumentsDirectory()>/registry_photos/<reportId>/page_1.jpg …
///                                                      └ report.json  (원본 리포트 — 실명)
/// SharedPreferences['registry_photos_v1']
///     = [{"id": "<reportId>", "photos": ["page_1.jpg", …]}, …]   ← 최신순
/// ```
/// **캐시(임시) 폴더를 쓰지 않는다** — OS가 임의로 비우기 때문이다.
/// prefs에는 절대경로가 아니라 **폴더 안 파일 이름**만 적는다. 앱 문서 경로는 런타임에
/// 다시 물어보면 되고, 절대경로를 굳혀 두면 경로가 바뀌었을 때 통째로 못 읽는다.
///
/// ⚠ 등기부 사진·원본 리포트에는 소유자 실명·주소가 있다. 그래서 최근 [keepRecentReports]건만 남기고
/// 오래된 폴더는 통째로 지운다(원본 리포트는 사진과 같은 폴더라 함께 지워진다).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/config.dart';

class RegistryPhotoStore {
  RegistryPhotoStore._();

  static final RegistryPhotoStore instance = RegistryPhotoStore._();

  /// 남겨 둘 최근 분석 건수. 넘치면 오래된 폴더부터 통째로 지운다.
  /// 무한정 쌓이면 기기 용량도 문제지만, 실명이 담긴 사진이 계속 남는 것이 더 문제다.
  static const int keepRecentReports = 5;

  /// 사진·이름을 **어디에 얼마나** 남기는지 — 화면 문구는 전부 이 한 줄에서 가져온다 (2026-10-22).
  ///
  /// 실제 동작 그대로다: ⑴ 사진은 국내 AI(Upstage)가 **글자를 읽는 데만** 쓰고, 우리 서버에는 사진도 실명도
  /// 남지 않는다(서버 기록은 이름을 가린 사본 — api-contract §9.11·서버 테스트), ⑵ 실명이 보이는 **원본 리포트와
  /// 사진은 이 폰에만** 최근 [keepRecentReports]건 남는다([keepOriginalsOnPhone]).
  /// 스위치·건수가 바뀌면 문구도 저절로 따라간다 — 문구와 동작이 다시 갈라지지 않게.
  static const String retentionNotice = keepOriginalsOnPhone
      ? '사진은 국내 AI(Upstage)가 글자를 읽는 데만 써요. 저희 서버에는 사진도 실명도 남지 않아요. '
            '실명이 보이는 원본 리포트와 사진은 이 휴대폰에만 최근 $keepRecentReports건 남아요.'
      : '사진은 국내 AI(Upstage)가 글자를 읽는 데만 써요. 저희 서버에는 사진도 실명도 남지 않아요. '
            '이 휴대폰에도 남기지 않아요.';

  static const String _prefsKey = 'registry_photos_v1';
  static const String _folderName = 'registry_photos';
  static const String _reportFile = 'report.json';

  /// reportId → 사진 절대경로 목록 (업로드 순서 = 페이지 순서).
  final Map<String, List<String>> _byReportId = {};

  /// 보관 순서 (앞이 최신) — 오래된 것부터 지우기 위해 필요하다.
  final List<String> _order = [];

  // ── 읽기 (동기) ───────────────────────────────────────────────────────────
  // 화면 build()에서 바로 부르므로 동기여야 한다. 그래서 앱 시작 시 restore()로
  // 목록을 메모리에 올려 두고, 이후에는 메모리만 본다.

  /// 이 리포트로 볼 수 있는 사진 경로들. **지금 실제로 존재하는 파일만** 돌려준다.
  ///
  /// 한 장이라도 사라졌으면 좌표와 사진의 순서가 어긋나므로 **전부 없는 것으로 친다**
  /// (page 인덱스가 밀려 엉뚱한 사진에 형광펜이 그려지는 것을 막는다).
  /// 영구 저장으로 바뀐 뒤에도 이 검사는 그대로 둔다 — 사용자가 저장소를 비우거나
  /// OS가 정리했을 수 있고, 그때 밀린 인덱스로 그리는 것이 가장 나쁜 결과다.
  List<String> pathsFor(String reportId) {
    final paths = _byReportId[reportId];
    if (paths == null || paths.isEmpty) return const [];
    for (final p in paths) {
      if (!File(p).existsSync()) return const [];
    }
    return paths;
  }

  bool hasPhotos(String reportId) => pathsFor(reportId).isNotEmpty;

  /// 분석 직후 호출 — 이 세션에서 **즉시** 쓸 수 있게 메모리에 올린다(동기).
  /// 영구 보관은 [keep]이 이어서 한다.
  void register(String reportId, List<String> jpegPaths) {
    _byReportId[reportId] = List.unmodifiable(jpegPaths);
  }

  /// 테스트용 초기화.
  void clear() {
    _byReportId.clear();
    _order.clear();
  }

  /// 테스트에서 보관 폴더를 임시 폴더로 바꾼다(위젯 테스트에는 앱 문서 폴더 플러그인이 없다).
  @visibleForTesting
  static Future<Directory> Function()? rootForTest;

  // ── 영구 보관 (비동기) ────────────────────────────────────────────────────
  // 이 아래는 전부 실패를 삼킨다. 보관은 편의 기능이라, 실패했다고 분석이나 화면이
  // 깨져서는 안 된다. 실패하면 그 세션 동안은 메모리 전용으로 동작할 뿐이다.

  /// 앱 시작 시 1회 — 저장해 둔 목록을 메모리로 올린다.
  ///
  /// 스위치가 꺼져 있으면 **예전에 남긴 것까지 지운다.** 그래야 config 한 줄을 false로
  /// 바꾸는 것만으로 "기기에 실명 사진이 남지 않는" 예전 상태로 완전히 돌아간다.
  Future<void> restore() async {
    if (!keepOriginalsOnPhone) {
      await _purgeAll();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final root = await _root();
      var restored = 0;
      for (final entry
          in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
        final id = entry['id'] as String;
        final names = (entry['photos'] as List).cast<String>();
        _order.add(id);
        _byReportId[id] = List.unmodifiable([
          for (final name in names) '${root.path}/$id/$name',
        ]);
        if (hasPhotos(id)) restored++;
      }
      debugPrint('[사진보관] 복원 — 기록 ${_order.length}건 중 사진이 실제로 있는 것 $restored건');
    } catch (e) {
      // SharedPreferences 플러그인이 없는 환경(위젯 테스트 등) 포함
      debugPrint('[사진보관] 복원 실패 — 이번 세션은 메모리 전용 (${e.runtimeType})');
    }
  }

  /// 분석 직후 호출 — 전송한 JPEG를 영구 저장소로 **복사**하고 원본 리포트 JSON도 남긴다.
  ///
  /// ★ [jpegPaths]는 반드시 **서버로 보낸 그 변환 JPEG**여야 한다. 갤러리 원본 경로를
  ///   넘기면 해상도·회전이 달라 하이라이트가 통째로 어긋난다.
  Future<void> keep(
    String reportId,
    List<String> jpegPaths, {
    String? reportJson,
  }) async {
    if (!keepOriginalsOnPhone || jpegPaths.isEmpty) return;
    try {
      final root = await _root();
      final dir = Directory('${root.path}/$reportId');
      if (dir.existsSync()) await dir.delete(recursive: true);
      await dir.create(recursive: true);

      final names = <String>[];
      for (var i = 0; i < jpegPaths.length; i++) {
        final name = 'page_${i + 1}.jpg';
        await File(jpegPaths[i]).copy('${dir.path}/$name');
        names.add(name);
      }
      if (reportJson != null) {
        await File('${dir.path}/$_reportFile').writeAsString(reportJson);
      }

      // 메모리 경로를 **복사본**으로 바꾼다 — 원본은 임시 폴더라 OS가 비울 수 있다.
      _byReportId[reportId] = List.unmodifiable([
        for (final name in names) '${dir.path}/$name',
      ]);
      _order
        ..remove(reportId)
        ..insert(0, reportId);
      await _pruneAndSave(root);
      debugPrint(
        '[사진보관] 저장 — $reportId 사진 ${names.length}장'
        '${reportJson != null ? ' + 원본 리포트' : ''} (보관 ${_order.length}/$keepRecentReports건)',
      );
    } catch (e) {
      debugPrint('[사진보관] 저장 실패 — 메모리 전용으로 계속 (${e.runtimeType})');
    }
  }

  /// 이 폰에 남긴 **원본 리포트**(분석 응답 그대로 — 실명). 없으면 null.
  ///
  /// 서버 기록은 이름을 가린 사본이라, 저장소는 이 원본을 **먼저** 쓴다(서버 사본은 원본이 없을 때만).
  /// 서버가 나중에 바꾸는 것은 별칭뿐이고(같은 사진 + 새 별칭), 그때는 분석 응답을 받으며 이 원본의 별칭을 고친다.
  Future<Map<String, dynamic>?> originalReport(String reportId) async {
    if (!keepOriginalsOnPhone) return null;
    try {
      final root = await _root();
      final file = File('${root.path}/$reportId/$_reportFile');
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      debugPrint('[사진보관] 원본 리포트 읽기 실패 (${e.runtimeType})');
      return null;
    }
  }

  /// 이 폰에 남긴 **원본 리포트만** 바꿔 쓴다(사진은 그대로) — 입력값 고치기(2026-10-29).
  /// 원본이 없으면(보관 안 함·지워짐) 아무것도 하지 않는다. [keep]을 다시 부르면 안 된다 — 폴더를 지운 뒤 복사해서
  /// 보관된 사진을 잃는다.
  Future<void> updateOriginalReport(String reportId, String reportJson) async {
    if (!keepOriginalsOnPhone) return;
    try {
      final root = await _root();
      final file = File('${root.path}/$reportId/$_reportFile');
      if (!file.existsSync()) return;
      await file.writeAsString(reportJson);
    } catch (e) {
      debugPrint('[사진보관] 원본 리포트 고쳐 쓰기 실패 (${e.runtimeType})');
    }
  }

  /// 기록을 지울 때 — 이 리포트의 사진·원본 리포트를 **이 폰에서도** 지운다. 실패해도 넘어간다.
  Future<void> forget(String reportId) async {
    _byReportId.remove(reportId);
    final removed = _order.remove(reportId);
    if (!keepOriginalsOnPhone) return;
    try {
      final root = await _root();
      final dir = Directory('${root.path}/$reportId');
      if (dir.existsSync()) await dir.delete(recursive: true);
      if (removed) await _pruneAndSave(root);
      debugPrint('[사진보관] 기록 삭제 — $reportId의 사진·원본 리포트도 이 폰에서 지웠어요');
    } catch (e) {
      debugPrint('[사진보관] 폰 사본 삭제 실패 (${e.runtimeType})');
    }
  }

  /// 이 폰의 원본 사진·실명 리포트를 **전부** 지운다 — 회원 탈퇴 (2026-10-30, `services/phone_wipe.dart`).
  Future<void> purgeAll() async {
    clear();
    await _purgeAll();
  }

  /// 촬영·변환 때 임시 폴더에 생긴 사진 사본을 지운다 — 앱을 켤 때 한 번 (2026-10-30 보안).
  ///
  /// 카메라 원본(`<uuid>….jpg`)·갤러리 사본(`<uuid>/파일명`)·보낼 JPEG(`upload_….jpg`)·PDF 공유 사본(`share/`)이
  /// 지우는 곳 없이 쌓여, "최근 5건만 남아요"·"기록을 지우면 폰 사본도 지워요"가 사실과 달라졌다.
  /// 보관본은 앱 문서 폴더(`registry_photos/`)라 여기서 건드리지 않는다. 실패는 조용히 넘어간다.
  static Future<int> sweepTempCopies({Directory? tempDir}) async {
    var removed = 0;
    try {
      final tmp = tempDir ?? await getTemporaryDirectory();
      if (!tmp.existsSync()) return 0;
      final uuid = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      );
      await for (final e in tmp.list(followLinks: false)) {
        final name = _basename(e.path);
        final ours = e is File
            ? (name.startsWith('upload_') || uuid.hasMatch(name))
            : (uuid.hasMatch(name) || name == 'share');
        if (!ours) continue;
        await e.delete(recursive: true);
        removed++;
      }
      if (removed > 0) debugPrint('[사진보관] 임시 사진 사본 $removed개를 지웠어요');
    } catch (e) {
      debugPrint('[사진보관] 임시 사본 정리 실패 (${e.runtimeType})');
    }
    return removed;
  }

  /// 보관 폴더와 기록을 통째로 지운다 (스위치를 끈 채 앱이 켜졌을 때 · 회원 탈퇴).
  Future<void> _purgeAll() async {
    try {
      final root = await _root();
      if (root.existsSync()) {
        await root.delete(recursive: true);
        debugPrint('[사진보관] 보관해 둔 사진·리포트를 모두 삭제했어요');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {
      // 플러그인이 없는 환경 등 — 지울 것도 없으므로 조용히 넘어간다
    }
  }

  Future<Directory> _root() async {
    final override = rootForTest;
    if (override != null) return override();
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$_folderName');
  }

  /// 최근 [keepRecentReports]건만 남기고 오래된 폴더를 지운 뒤 목록을 기록한다.
  Future<void> _pruneAndSave(Directory root) async {
    if (_order.length > keepRecentReports) {
      final dropped = _order.sublist(keepRecentReports);
      _order.removeRange(keepRecentReports, _order.length);
      for (final id in dropped) {
        _byReportId.remove(id);
        final dir = Directory('${root.path}/$id');
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
      debugPrint(
        '[사진보관] 오래된 ${dropped.length}건 삭제 (최근 $keepRecentReports건만 유지)',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([
        for (final id in _order)
          {
            'id': id,
            'photos': [
              for (final p in _byReportId[id] ?? const []) _basename(p),
            ],
          },
      ]),
    );
  }

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;
}
