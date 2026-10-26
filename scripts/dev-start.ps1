# 전세AI프 — 개발 한 번에 켜기 (2026-10-26)
#
# 하는 일 (순서대로):
#   ① 최신 코드 받기(git pull)
#   ② 폰 연결 — USB면 그대로, 없으면 무선 디버깅 주소(IP:포트)로 연결(지난번 주소를 기억한다)
#   ③ 서버를 새 창에서 켜기(이미 켜져 있으면 그대로) → 켜질 때까지 기다리기
#   ④ adb reverse(폰:8000 → PC:8000)
#   ⑤ flutter run (이 창에서 — r = 화면 새로고침, R = 앱 다시 시작, q = 끝)
#
# 쓰는 법: 탐색기에서 scripts\개발시작.bat 더블클릭 (바탕화면에 바로가기를 만들어 두면 편하다)
#   또는:  powershell -ExecutionPolicy Bypass -File .\scripts\dev-start.ps1

$ErrorActionPreference = "Continue"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$memo = Join-Path $PSScriptRoot ".last-adb-address"   # 지난번 무선 주소 (git에 안 올라감)
Set-Location $root

function Step($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Devices { @((adb devices) -split "`n" | Where-Object { $_ -match "\tdevice\s*$" }) }

Step "① 최신 코드 받기"
git -c core.autocrlf=true pull --ff-only
if ($LASTEXITCODE -ne 0) { Write-Host "  ! 받기 실패 — 고친 파일이 있으면 그대로 두고 계속해요" -ForegroundColor Yellow }

Step "② 폰 연결"
adb start-server | Out-Null
if ((Devices).Count -eq 0) {
    $last = if (Test-Path $memo) { (Get-Content $memo -Raw).Trim() } else { "" }
    if ($last) {
        Write-Host "  지난번 무선 주소로 연결해 봐요: $last"
        adb connect $last | Out-Host
    }
    if ((Devices).Count -eq 0) {
        Write-Host "  폰: 설정 → 개발자 옵션 → 무선 디버깅 → 화면에 보이는 'IP 주소 및 포트'를 적어 주세요 (예: 192.168.0.12:37123)" -ForegroundColor Yellow
        $addr = Read-Host "  IP:포트"
        adb connect $addr | Out-Host
        if ((Devices).Count -eq 0) {
            Write-Host "  처음 연결하는 폰이면 짝 맺기가 먼저예요: 무선 디버깅 → '페어링 코드로 기기 페어링'" -ForegroundColor Yellow
            $pairAddr = Read-Host "  페어링 화면의 IP:포트"
            $code = Read-Host "  페어링 코드(6자리)"
            adb pair $pairAddr $code | Out-Host
            adb connect $addr | Out-Host
        }
        if ((Devices).Count -gt 0) { Set-Content -Path $memo -Value $addr -Encoding ascii }
    }
}
$dev = Devices
if ($dev.Count -eq 0) { Write-Host "  X 폰을 찾지 못했어요. USB를 꽂거나 무선 디버깅을 켜고 다시 실행해 주세요." -ForegroundColor Red; Read-Host "엔터를 누르면 닫혀요"; exit 1 }
Write-Host "  OK $($dev -join ', ')" -ForegroundColor Green

Step "③ 서버"
function ServerUp { try { Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/ -TimeoutSec 2 | Out-Null; $true } catch { $false } }
if (ServerUp) {
    Write-Host "  OK 이미 켜져 있어요" -ForegroundColor Green
} else {
    Start-Process powershell -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "run-backend.ps1")
    Write-Host "  새 창에서 서버를 켜는 중…"
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 1; if (ServerUp) { $ok = $true; break } }
    if ($ok) { Write-Host "  OK 서버 켜짐" -ForegroundColor Green }
    else { Write-Host "  ! 40초 안에 안 켜졌어요 — 서버 창의 빨간 글씨를 확인해 주세요. 앱은 그대로 켭니다." -ForegroundColor Yellow }
}

Step "④ 폰 → PC 터널 (adb reverse)"
adb reverse tcp:8000 tcp:8000 | Out-Null
Write-Host "  OK $(adb reverse --list)" -ForegroundColor Green

Step "⑤ 앱 켜기 (flutter run) — r 새로고침 · R 다시 시작 · q 끝"
Set-Location (Join-Path $root "frontend")
flutter pub get | Out-Null
flutter run
