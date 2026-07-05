# 전세AI프 — 백엔드 서버 실행 (긴 venv 명령 대신)
#
# 이 터미널은 서버 로그 창으로 계속 켜 두세요. 끄려면 Ctrl+C.
# --reload 라 백엔드 코드를 고치면 알아서 재시작됩니다.
#
# 사용법 (프로젝트 루트에서):
#   .\scripts\run-backend.ps1
# 만약 실행 정책 오류가 나면:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-backend.ps1

$backend = Join-Path $PSScriptRoot "..\backend"
$python = Join-Path $backend ".venv\Scripts\python.exe"

if (-not (Test-Path $python)) {
    Write-Host "X .venv를 찾을 수 없어요. backend에서 가상환경을 먼저 만들어 주세요:" -ForegroundColor Red
    Write-Host "   cd backend" -ForegroundColor Yellow
    Write-Host "   python -m venv .venv" -ForegroundColor Yellow
    Write-Host "   .\.venv\Scripts\python.exe -m pip install -r requirements.txt" -ForegroundColor Yellow
    exit 1
}

Write-Host "백엔드 서버 시작: http://127.0.0.1:8000  (Ctrl+C 로 종료)" -ForegroundColor Green
# python.exe -m uvicorn 으로 실행 → uvicorn.exe 런처의 절대경로 문제를 피함 (CLAUDE.local.md 참고)
Push-Location $backend
try {
    & $python -m uvicorn app.main:app --reload
} finally {
    Pop-Location
}
