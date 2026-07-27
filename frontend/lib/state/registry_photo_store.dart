/// 분석에 **실제로 전송한 JPEG 파일**과 그 리포트를 보관하는 저장소.
///
/// 왜 필요한가:
/// 서버가 주는 하이라이트 좌표는 **서버로 보낸 그 JPEG의 픽셀 기준**이다. 화면에
/// 갤러리 원본을 띄우면 해상도·회전이 달라 좌표가 전부 어긋난다(원본은 EXIF 회전이
/// 남아 있고 재인코딩(quality 90)도 거치지 않았다). 그래서 업로드에 쓴 **그 파일**을
/// 그대로 다시 그려야 한다 — 갤러리 경로를 기억해 두었다가 다시 읽으면 안 된다.
///
/// 보관 정책 — [devKeepRegistryPhotos] 한 줄로 갈린다:
/// - **true (개발 기본)**: 전송한 JPEG를 앱 영구 저장소로 복사하고, 리포트 JSON도
///   같은 폴더에 남긴다. 앱을 껐다 켜도, 백엔드를 재시작해 서버 메모리의 리포트가
///   사라져도 '원본에서 보기'가 계속 열린다(테스트마다 재분석 = 크레딧 소모를 막는다).
/// - **false (제출·배포)**: 예전 그대로 **메모리 전용**. 복사·기록·복원이 전부 꺼지고,
///   앱을 껐다 켜면 사진이 사라져 뷰어 진입점도 함께 사라진다.
///
/// 저장 위치·형태:
/// ```
/// <getApplicationDocumentsDirectory()>/registry_photos/<reportId>/page_1.jpg …
///                                                      └ report.json  (fallback 전용 캐시)
/// SharedPreferences['registry_photos_v1']
///     = [{"id": "<reportId>", "photos": ["page_1.jpg", …]}, …]   ← 최신순
/// ```
/// **캐시(임시) 폴더를 쓰지 않는다** — OS가 임의로 비우기 때문이다.
/// prefs에는 절대경로가 아니라 **폴더 안 파일 이름**만 적는다. 앱 문서 경로는 런타임에
/// 다시 물어보면 되고, 절대경로를 굳혀 두면 경로가 바뀌었을 때 통째로 못 읽는다.
///
/// ⚠ 등기부 사진에는 소유자 실명·주소가 있다. 그래서 켜 두더라도 최근
/// [keepRecentReports]건만 남기고 오래된 폴더는 지운다.
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

  // ── 영구 보관 (비동기) ────────────────────────────────────────────────────
  // 이 아래는 전부 실패를 삼킨다. 보관은 편의 기능이라, 실패했다고 분석이나 화면이
  // 깨져서는 안 된다. 실패하면 그 세션 동안은 메모리 전용으로 동작할 뿐이다.

  /// 앱 시작 시 1회 — 저장해 둔 목록을 메모리로 올린다.
  ///
  /// 스위치가 꺼져 있으면 **예전에 남긴 것까지 지운다.** 그래야 config 한 줄을 false로
  /// 바꾸는 것만으로 "기기에 실명 사진이 남지 않는" 예전 상태로 완전히 돌아간다.
  Future<void> restore() async {
    if (!devKeepRegistryPhotos) {
      await _purgeAll();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final root = await _root();
      var restored = 0;
      for (final entry in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
        final id = entry['id'] as String;
        final names = (entry['photos'] as List).cast<String>();
        _order.add(id);
        _byReportId[id] = List.unmodifiable([
          for (final name in names) '${root.path}/$id/$name',
        ]);
        if (hasPhotos(id)) restored++;
      }
      debugPrint(
        '[사진보관] 복원 — 기록 ${_order.length}건 중 사진이 실제로 있는 것 $restored건',
      );
    } catch (e) {
      // SharedPreferences 플러그인이 없는 환경(위젯 테스트 등) 포함
      debugPrint('[사진보관] 복원 실패 — 이번 세션은 메모리 전용 (${e.runtimeType})');
    }
  }

  /// 분석 직후 호출 — 전송한 JPEG를 영구 저장소로 **복사**하고 리포트 JSON도 남긴다.
  ///
  /// ★ [jpegPaths]는 반드시 **서버로 보낸 그 변환 JPEG**여야 한다. 갤러리 원본 경로를
  ///   넘기면 해상도·회전이 달라 하이라이트가 통째로 어긋난다.
  Future<void> keep(
    String reportId,
    List<String> jpegPaths, {
    String? reportJson,
  }) async {
    if (!devKeepRegistryPhotos || jpegPaths.isEmpty) return;
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
        '${reportJson != null ? ' + 리포트 캐시' : ''} (보관 ${_order.length}/$keepRecentReports건)',
      );
    } catch (e) {
      debugPrint('[사진보관] 저장 실패 — 메모리 전용으로 계속 (${e.runtimeType})');
    }
  }

  /// 로컬에 캐시해 둔 리포트 JSON 원문. 없으면 null.
  ///
  /// **fallback 전용이다.** 서버 조회가 성공하면 이 값을 쓰지 않는다 — 서버가 항상
  /// 최신이고, 캐시는 분석 당시의 스냅샷일 뿐이다.
  Future<String?> cachedReportJson(String reportId) async {
    if (!devKeepRegistryPhotos) return null;
    try {
      final root = await _root();
      final file = File('${root.path}/$reportId/$_reportFile');
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } catch (e) {
      debugPrint('[사진보관] 리포트 캐시 읽기 실패 (${e.runtimeType})');
      return null;
    }
  }

  /// 보관 폴더와 기록을 통째로 지운다 (스위치를 끈 채 앱이 켜졌을 때).
  Future<void> _purgeAll() async {
    try {
      final root = await _root();
      if (root.existsSync()) {
        await root.delete(recursive: true);
        debugPrint('[사진보관] 스위치 off — 보관해 둔 사진·리포트를 삭제했어요');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {
      // 플러그인이 없는 환경 등 — 지울 것도 없으므로 조용히 넘어간다
    }
  }

  Future<Directory> _root() async {
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
      debugPrint('[사진보관] 오래된 ${dropped.length}건 삭제 (최근 $keepRecentReports건만 유지)');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([
        for (final id in _order)
          {
            'id': id,
            'photos': [for (final p in _byReportId[id] ?? const []) _basename(p)],
          },
      ]),
    );
  }

  static String _basename(String path) =>
      path.split(RegExp(r'[\\/]')).last;
}
