/// 판례 **미리 불러오기** (2026-10-26) — 리포트가 열리는 순간 뒤에서 판례를 받아 둔다.
///
/// 판례 화면을 처음 열면 서버가 판례를 찾고 국내 AI가 "우리 매물과의 공통점"을 쓰느라 몇 초 걸린다.
/// 리포트·'내 사진에서 보기'를 읽는 동안 미리 받아 두면, '판례 보기'를 누를 때 바로 뜬다.
/// - 받는 중에 누르면 **같은 요청을 이어서** 기다린다(두 번 부르지 않는다).
/// - 빈 목록·실패는 기억하지 않는다 — 서버가 실패를 빈 목록으로 주므로, 다음에 다시 시도하게 둔다.
/// - 화면은 그대로다. 뒤에서만 일한다.
library;

import '../models/content_models.dart';
import '../repositories/content_repository.dart';

abstract final class CasePrefetch {
  /// 최근 리포트 몇 건만 기억한다(메모리)
  static const int keep = 10;

  static final Map<String, Future<List<CaseMatch>>> _byReport = {};

  /// 리포트가 열릴 때 — 뒤에서 받기 시작(이미 받는 중이거나 받아 뒀으면 아무것도 안 함)
  static void warm(ContentRepository repo, String reportId) {
    get(repo, reportId).ignore();
  }

  /// 판례 화면 — 받아 둔 것(또는 받는 중인 것)을 쓰고, 없으면 지금 받는다
  static Future<List<CaseMatch>> get(ContentRepository repo, String reportId) {
    // 저장소마다 따로 기억한다(앱에선 하나뿐 — 테스트마다 가짜 저장소가 달라도 섞이지 않게)
    final key = '${identityHashCode(repo)}:$reportId';
    final existing = _byReport[key];
    if (existing != null) return existing;
    final future = repo.matchedCases(reportId);
    _byReport[key] = future;
    if (_byReport.length > keep) _byReport.remove(_byReport.keys.first);
    future.then(
      (cases) {
        if (cases.isEmpty && identical(_byReport[key], future)) _byReport.remove(key);
      },
      onError: (Object _) {
        if (identical(_byReport[key], future)) _byReport.remove(key);
      },
    );
    return future;
  }

  /// 테스트용 — 기억을 비운다
  static void clear() => _byReport.clear();
}
