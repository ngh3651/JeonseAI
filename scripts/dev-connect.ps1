# 전세AI프 — 실기기 개발 연결 스크립트
#
# 하는 일: ① 기기 연결 확인 ② adb reverse 터널(폰:8000 → PC:8000) 설정 ③ 서버 접속 확인
# 언제 실행: 홈에 "다시 시도"가 뜰 때, flutter run 이후, USB 재연결·PC 재부팅 후.
#
# 사용법 (프로젝트 루트에서):
#   .\scripts\dev-connect.ps1
# 만약 "이 시스템에서 스크립트를 실행할 수 없습니다" 오류가 나면:
#   powershell -ExecutionPolicy Bypass -File .\scripts\dev-connect.ps1

Write-Host "== 기기 확인 ==" -ForegroundColor Cyan
$devices = (adb devices) -split "`n" | Where-Object { $_ -match "\tdevice$" }
if (-not $devices) {
    Write-Host "  X 연결된 기기가 없어요. USB로 폰을 연결하고 'USB 디버깅 허용'을 눌러 주세요." -ForegroundColor Red
    exit 1
}
Write-Host "  OK 기기 연결됨: $($devices -join ', ')" -ForegroundColor Green

Write-Host "`n== adb reverse 터널 설정 (폰:8000 -> PC:8000) ==" -ForegroundColor Cyan
adb reverse tcp:8000 tcp:8000 | Out-Null
$list = adb reverse --list
if ($list -match "tcp:8000") {
    Write-Host "  OK 터널 설정됨: $list" -ForegroundColor Green
} else {
    Write-Host "  X 터널 설정 실패 (adb 상태를 확인하세요)" -ForegroundColor Red
    exit 1
}

Write-Host "`n== 백엔드 서버 접속 확인 ==" -ForegroundColor Cyan
try {
    $res = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/ -TimeoutSec 5
    Write-Host "  OK 서버 살아있음: $($res.Content)" -ForegroundColor Green
    Write-Host "`n준비 끝! 앱에서 홈 '다시 시도'를 누르거나 앱을 다시 열면 데이터가 떠요." -ForegroundColor Green
} catch {
    Write-Host "  ! 서버가 응답하지 않아요. 백엔드를 먼저 켜 주세요 (다른 터미널에서):" -ForegroundColor Yellow
    Write-Host "     .\scripts\run-backend.ps1" -ForegroundColor Yellow
}
