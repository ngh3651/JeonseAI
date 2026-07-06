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

# ── 8000 포트 선점 프로세스 정리 ──────────────────────────────────────────────
# 이전 서버가 좀비로 남아 있으면 [WinError 10013]으로 기동에 실패한다 (2026-07-06 실기기 E2E에서 재현).
# 파이썬(uvicorn) 프로세스면 자동 종료하고, 다른 프로그램이면 안내만 하고 중단한다.
$port = 8000
$listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
$owners = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
foreach ($procId in $owners) {
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($null -eq $proc) { continue }
    if ($proc.ProcessName -match '^(python|uvicorn)') {
        Write-Host "! $port 포트를 이전 서버(PID $procId, $($proc.ProcessName))가 점유 중 → 자동 종료합니다" -ForegroundColor Yellow
        try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch {
            Write-Host "X 자동 종료 실패. 직접 종료 후 다시 실행해 주세요: taskkill /PID $procId /F" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "X $port 포트를 다른 프로그램(PID $procId, $($proc.ProcessName))이 사용 중이에요." -ForegroundColor Red
        Write-Host "  서버가 아닌 프로그램이라 자동 종료하지 않아요. 확인 후 직접 종료해 주세요: taskkill /PID $procId /F" -ForegroundColor Yellow
        exit 1
    }
}
if ($owners.Count -gt 0) { Start-Sleep -Milliseconds 700 }

Write-Host "백엔드 서버 시작: http://127.0.0.1:8000  (Ctrl+C 로 종료)" -ForegroundColor Green
# python.exe -m uvicorn 으로 실행 → uvicorn.exe 런처의 절대경로 문제를 피함 (CLAUDE.local.md 참고)
Push-Location $backend
try {
    & $python -m uvicorn app.main:app --reload
} finally {
    Pop-Location
}
