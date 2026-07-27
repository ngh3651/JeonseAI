/// 세로로 이어 붙인 등기부 사진 뭉치의 **기하** — 쪽 높이·쪽 시작 위치·전체 높이.
///
/// 왜 따로 떼어 두는가:
/// 위치 레일의 쪽 눈금, 표시 점의 위치, "표시로 스크롤"의 목표 지점이 전부 이 계산에서
/// 나온다. 위젯 안에 섞여 있으면 눈으로만 검증하게 되는데, 여기가 틀리면 레일이 조용히
/// 거짓말을 한다(눈금이 종이 경계와 어긋나도 화면은 멀쩡해 보인다).
///
/// ⚠ **쪽 높이를 균등하게 나누지 않는다.** 시안의 눈금값(20.6 / 39.2 / 61.1 / 81.0%)은
///   시안 샘플의 계산 결과이지 상수가 아니다. 쪽마다 해상도가 다르다
///   (실측: 1212x1776, 1162x1538, 1256x1776, 1256x1778, 1256x1776 — 두 번째 쪽만
///   종횡비가 눈에 띄게 다르다). 실제 이미지의 종횡비로 매번 계산한다.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

/// 문서 좌우 여백 (종이와 화면 가장자리 사이)
const double kDocPadH = 8;

/// 문서 상하 여백
const double kDocPadV = 9;

/// 쪽과 쪽 사이 간격
const double kPageGap = 10;

/// 원본 크기를 읽지 못한 쪽에 쓰는 비율 — A4 (1 : 1.414).
///
/// 0을 넣으면 그 쪽이 사라져 **뒤 쪽들의 위치가 통째로 밀린다.** 표시가 엉뚱한 자리에
/// 찍히느니 높이만 근사로 채우고 사진은 실패 안내를 띄우는 편이 낫다.
const double kFallbackPageAspect = 1.414;

class RegistryDocumentLayout {
  RegistryDocumentLayout._({
    required this.pageWidth,
    required this.pageHeights,
    required this.padTop,
    required this.padBottom,
    required this.gap,
  }) : _pageTops = _cumulativeTops(pageHeights, padTop, gap),
       totalHeight =
           padTop +
           padBottom +
           pageHeights.fold<double>(0, (a, b) => a + b) +
           gap * math.max(0, pageHeights.length - 1);

  /// 원본 픽셀 크기 목록 + 화면에 그릴 폭 → 기하.
  ///
  /// [sizes]는 **서버로 보낸 그 JPEG**의 픽셀 크기여야 한다. 갤러리 원본 크기를 넣으면
  /// 회전·재인코딩 차이로 종횡비가 달라져 레일과 사진이 어긋난다.
  factory RegistryDocumentLayout.fromSizes({
    required List<Size> sizes,
    required double pageWidth,
    double padTop = kDocPadV,
    double padBottom = kDocPadV,
    double gap = kPageGap,
  }) {
    final w = math.max(0.0, pageWidth);
    return RegistryDocumentLayout._(
      pageWidth: w,
      pageHeights: [
        for (final s in sizes)
          w * (s.width > 0 && s.height > 0 ? s.height / s.width : kFallbackPageAspect),
      ],
      padTop: padTop,
      padBottom: padBottom,
      gap: gap,
    );
  }

  final double pageWidth;
  final List<double> pageHeights;
  final double padTop;
  final double padBottom;
  final double gap;

  /// 스크롤 콘텐츠 전체 높이 (여백·간격 포함). 레일의 모든 비율이 이 값을 분모로 쓴다.
  final double totalHeight;

  final List<double> _pageTops;

  int get pageCount => pageHeights.length;

  /// 쪽 [i]의 문서 내 시작 y.
  double pageTop(int i) => _pageTops[i];

  double pageHeight(int i) => pageHeights[i];

  /// 표시(정규화 y 0~1) 하나의 문서 내 **윗변** y.
  double markTop(int page, double normY) =>
      pageTop(page) + normY * pageHeight(page);

  /// 표시 하나의 문서 내 **세로 중심** y — 레일 점은 중심에 찍는다.
  double markCenterY(int page, double normY, double normH) =>
      pageTop(page) + (normY + normH / 2) * pageHeight(page);

  /// 문서 내 절대 y → 레일 위 비율(0~1).
  double fractionOf(double y) =>
      totalHeight <= 0 ? 0 : (y / totalHeight).clamp(0.0, 1.0);

  /// 쪽 [i]와 [i+1] 사이 경계의 레일 비율 — 눈금 위치. (간격 한가운데)
  double boundaryFraction(int i) =>
      fractionOf(pageTop(i) + pageHeight(i) + gap / 2);

  /// 쪽 [i] 한가운데의 레일 비율 — 쪽번호 라벨 위치.
  double pageCenterFraction(int i) => fractionOf(pageTop(i) + pageHeight(i) / 2);

  static List<double> _cumulativeTops(
    List<double> heights,
    double padTop,
    double gap,
  ) {
    final tops = <double>[];
    var y = padTop;
    for (final h in heights) {
      tops.add(y);
      y += h + gap;
    }
    return tops;
  }
}

/// "이 표시로 스크롤"의 목표 오프셋.
///
/// 시안은 `절대 y − 190dp`라는 고정값을 쓰지만, 190dp는 시안이 가정한 뷰포트에서만
/// 맞는 값이다(작은 화면에서는 표시가 화면 밖으로 밀리고, 큰 화면에서는 한가운데로
/// 온다). **뷰포트 높이의 1/3**로 계산해 어떤 기기에서도 표시가 위쪽 1/3 지점에 온다.
double scrollTargetFor({
  required double markY,
  required double viewportHeight,
  required double maxScrollExtent,
}) {
  if (maxScrollExtent <= 0) return 0;
  return (markY - viewportHeight / 3).clamp(0.0, maxScrollExtent);
}
