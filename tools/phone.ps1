# Helpers for building, installing and screenshotting the app on the test phone over adb.
# Usage examples:
#   .\tools\phone.ps1 build                 # debug APK (arm64) and install
#   .\tools\phone.ps1 launch
#   .\tools\phone.ps1 shot login-light      # saves design/screenshots/app/login-light.png
#   .\tools\phone.ps1 tap 210 600           # in dp (density 3 on the A024)
#   .\tools\phone.ps1 text "harini.v"
param([Parameter(Position = 0)][string]$Cmd, [Parameter(Position = 1)][string]$A, [Parameter(Position = 2)][string]$B, [string]$ApiBase)

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:USERPROFILE 'Android\Sdk' }
$adb = Join-Path $sdk 'platform-tools\adb.exe'
# The phone to drive: PHONE_SERIAL, or else the only phone adb can see.
$serial = $env:PHONE_SERIAL
if (-not $serial) {
  $phones = @(& $adb devices | Select-String -Pattern '^(\S+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
  # The same phone shows up twice when it is on USB and wireless debugging at once; USB wins.
  $usb = @($phones | Where-Object { $_ -notmatch ':|_adb-tls' })
  if ($usb.Count -eq 1) { $phones = $usb }
  if ($phones.Count -ne 1) { "Connect one phone or set PHONE_SERIAL (adb sees $($phones.Count))"; exit 2 }
  $serial = $phones[0]
}
$root = Split-Path $PSScriptRoot -Parent
$pkg = 'com.coreacademy.core_academy'
$scale = 3.0

function Adb { & $adb -s $serial @args }

# Input only ever goes to Core Academy: refuse when another app is in front.
function Assert-Ours {
  $top = Adb shell dumpsys activity activities | Select-String -Pattern 'topResumedActivity' | Select-Object -First 1
  if ("$top" -notmatch [regex]::Escape($pkg)) { "REFUSED: Core Academy is not in front"; exit 2 }
}
if ($Cmd -in @('tap', 'swipe', 'text', 'key', 'back')) { Assert-Ours }

switch ($Cmd) {
  'build' {
    Push-Location (Join-Path $root 'app')
    try {
      $defines = @()
      if ($ApiBase) { $defines = @("--dart-define=API_BASE=$ApiBase") }
      & C:\src\flutter\bin\flutter.bat build apk --debug --target-platform android-arm64 @defines 2>&1 | Select-Object -Last 3
      Adb install -r 'build\app\outputs\flutter-apk\app-debug.apk'
    } finally { Pop-Location }
  }
  'launch' { Adb shell am force-stop $pkg; Adb shell am start -n "$pkg/.MainActivity" | Out-Null; 'launched' }
  'stop' { Adb shell am force-stop $pkg }
  'clear' { Adb shell pm clear $pkg }
  'shot' {
    $dir = Join-Path $root 'design\screenshots\app'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir "$A.png"
    Adb shell screencap -p /sdcard/ca-shot.png
    Adb pull /sdcard/ca-shot.png $file | Out-Null
    Adb shell rm /sdcard/ca-shot.png
    $file
  }
  'tap' { Adb shell input tap ([int]([double]$A * $scale)) ([int]([double]$B * $scale)) }
  'swipe' { $p = $A.Split(','); Adb shell input swipe ([int]([double]$p[0] * $scale)) ([int]([double]$p[1] * $scale)) ([int]([double]$p[2] * $scale)) ([int]([double]$p[3] * $scale)) 200 }
  'text' { Adb shell input text ($A -replace ' ', '%s') }
  'key' { Adb shell input keyevent $A }
  'back' { Adb shell input keyevent 4 }
  default { 'commands: build, launch, stop, clear, shot <name>, tap <x> <y>, swipe x1,y1,x2,y2, text <s>, key <code>, back' }
}
