# 전세AI프 — 개발 한 번에 켜기 (2026-10-26)
#
# 하는 일 (순서대로):
#   ① 최신 코드 받기(git pull)
#   ② 폰 연결 — USB면 그대로, 없으면 무선 디버깅 주소(IP:포트)로 연결(지난번 주소를 기억한다)
#   ③ 서버를 새 창에서 켜기(이미 켜져 있으면 그대로) → 켜질 때까지 기다리기
#   ④ adb reverse(폰:8000 → PC:8000)
#   ⑤ flutter run (이 창에서 — r = 화면 새로고침, R = 앱 다시 시작, q = 끝)
#      카카오 네이티브 앱 키를 넣어 켠다(처음 한 번 물어보고 기억) → 개발 앱에도 카카오 버튼이 보인다.
#      개발 앱(`….jeonse_ai.dev`)으로 로그인까지 되려면 카카오 콘솔에 개발 앱을 한 번 등록해야 한다 —
#      이 창이 ⑤에서 패키지명·키 해시를 보여 준다(NOW.md 6-2).
#
# 폰이 두 번 잡혀도(IP 주소 + 무선 이름 = 같은 폰) 첫 번째 하나만 골라 쓴다 — adb·flutter가 '기기가 여러 대'라고 멈추지 않게.
#
# 쓰는 법: 탐색기에서 scripts\개발시작.bat 더블클릭 (바탕화면에 바로가기를 만들어 두면 편하다)
#   또는:  powershell -ExecutionPolicy Bypass -File .\scripts\dev-start.ps1

$ErrorActionPreference = "Continue"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$memo = Join-Path $PSScriptRoot ".last-adb-address"   # 지난번 무선 주소 (git에 안 올라감)
$kakaoMemo = Join-Path $PSScriptRoot ".kakao-native-app-key"   # 카카오 네이티브 앱 키 (공개 값이지만 git에 안 올림)
Set-Location $root

function Step($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Devices { @((adb devices) -split "`n" | Where-Object { $_ -match "\tdevice\s*$" }) }
function Serial($line) { ($line -split "\s+")[0] }

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
# 같은 폰이 두 줄(IP 주소 + 무선 이름)로 잡힐 때가 있다 → 첫 줄 하나만 쓴다
$serial = Serial $dev[0]
Write-Host "  OK $serial" -ForegroundColor Green

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
adb -s $serial reverse tcp:8000 tcp:8000 | Out-Null
$rev = adb -s $serial reverse --list
if ($rev -match "tcp:8000") { Write-Host "  OK $rev" -ForegroundColor Green }
else { Write-Host "  ! 터널을 못 뚫었어요 — 앱이 서버에 못 붙을 수 있어요. 이 창을 닫고 다시 실행해 주세요." -ForegroundColor Yellow }

Step "⑤ 앱 켜기 (flutter run) — r 새로고침 · R 다시 시작 · q 끝"
Set-Location (Join-Path $root "frontend")
flutter pub get | Out-Null

# 카카오 네이티브 앱 키 — 처음 한 번만 묻고 기억한다(GitHub 저장소 → Settings → Variables의 KAKAO_NATIVE_APP_KEY 값)
$kakaoKey = if (Test-Path $kakaoMemo) { (Get-Content $kakaoMemo -Raw).Trim() } else { "" }
if (-not $kakaoKey) {
    Write-Host "  카카오 버튼을 개발 앱에도 보이게 하려면 '네이티브 앱 키'를 붙여 넣어 주세요 (없으면 그냥 엔터)" -ForegroundColor Yellow
    $kakaoKey = (Read-Host "  네이티브 앱 키").Trim()
    if ($kakaoKey) { Set-Content -Path $kakaoMemo -Value $kakaoKey -Encoding ascii }
}
$defines = @()
if ($kakaoKey) {
    $defines += "--dart-define=KAKAO_NATIVE_APP_KEY=$kakaoKey"
    # 개발 앱을 카카오 콘솔에 등록할 값 — 키 해시는 이 PC의 디버그 키로 만든다(PC마다 다르다)
    $debugKeystore = Join-Path $env:USERPROFILE ".android\debug.keystore"
    $keytool = if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\keytool.exe"))) { Join-Path $env:JAVA_HOME "bin\keytool.exe" }
               elseif (Test-Path "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe") { "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" }
               else { "keytool" }
    $hash = ""
    if (Test-Path $debugKeystore) {
        try {
            $sha1 = (& $keytool -list -v -alias androiddebugkey -keystore $debugKeystore -storepass android 2>$null |
                     Select-String "SHA1:\s*([0-9A-Fa-f:]+)").Matches[0].Groups[1].Value
            $bytes = [byte[]]($sha1 -split ":" | ForEach-Object { [Convert]::ToByte($_, 16) })
            $hash = [Convert]::ToBase64String($bytes)
        } catch { $hash = "" }
    }
    Write-Host "  카카오 버튼 켬. 개발 앱 로그인까지 되려면 카카오 콘솔 → 플랫폼 → Android에 한 번 등록:" -ForegroundColor Cyan
    Write-Host "     패키지명  com.jeonseai.jeonse_ai.dev"
    if ($hash) { Write-Host "     키 해시   $hash" } else { Write-Host "     키 해시   (못 구했어요 — 한 번 flutter run을 끝까지 돌린 뒤 다시 실행해 주세요)" -ForegroundColor Yellow }
    # 노트북 서버가 카카오 토큰을 확인하려면 backend/.env에도 카카오 값이 있어야 한다
    $envFile = Join-Path $root "backend\.env"
    $envText = if (Test-Path $envFile) { Get-Content $envFile -Raw } else { "" }
    if ($envText -notmatch "(?m)^\s*KAKAO_APP_ID\s*=\s*\S" -or $envText -notmatch "(?m)^\s*ACCOUNT_HASH_SECRET\s*=\s*\S{32,}") {
        Write-Host "  ! backend\.env에 KAKAO_APP_ID · ACCOUNT_HASH_SECRET(32자 이상)이 없어요 — Railway Variables와 같은 값으로 넣어야 노트북 서버에서 로그인이 돼요" -ForegroundColor Yellow
    }
}
flutter run -d $serial @defines
