# Screenshots each comp board (light + dark side by side) with headless Chrome.
# Needs the comp server running on 127.0.0.1:8777 (preview "comps").
param([string[]]$Screens = @('test-a', 'test-b', 'dashboard', 'paper-review'))

$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$out = Join-Path $PSScriptRoot '..\design\screenshots'
New-Item -ItemType Directory -Force $out | Out-Null
$profileDir = Join-Path $env:TEMP 'ca-shoot-profile'

foreach ($s in $Screens) {
  $file = Join-Path (Resolve-Path $out) "$s.png"
  $url = "http://127.0.0.1:8777/board.html?screen=$s"
  & $chrome --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check `
    --user-data-dir="$profileDir" --force-device-scale-factor=2 --window-size=898,894 `
    --virtual-time-budget=8000 --screenshot="$file" $url 2>$null | Out-Null
  if (Test-Path $file) { "{0,-14} {1:N0} bytes" -f "$s.png", (Get-Item $file).Length } else { "$s.png  FAILED" }
}
