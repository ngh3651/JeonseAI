# RESUME — 중단 시 이어서 하기

> 작업 단위마다 덮어쓴다. 항상 아래 4가지만 최신 상태로 유지한다.
> 재개하면 **코드보다 이 파일과 `docs/night-log.md`를 먼저 읽어라.**

## 1. 지금 어디까지
라운드 2(앱) 시작 직전. 라운드 0(검증 스크립트)·1(백엔드) 완료.

## 2. 마지막 커밋
`2e4d764` — 백엔드: Document OCR 병렬 호출 + IE↔OCR 좌표 매칭. **빌드되는 상태.**
(backend pytest 111건 통과 / 기존 86건 포함)

## 3. 커밋 안 된 변경
없음.

## 4. 다음 할 일 딱 하나
Flutter: 리포트 화면에 '원본에서 보기' 진입점 + 사진 뷰어(InteractiveViewer +
CustomPaint 오버레이). 앱이 띄우는 이미지는 **서버로 보낸 그 JPEG**여야 한다
(`ApiAnalysisRepository.analyze`가 `convertToJpeg`로 만든 임시 파일 경로를 들고 있음).
