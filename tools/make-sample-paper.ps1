# Renders the 2-page sample question paper (design/comps/paper/sample.html) to JPEGs in tools/out/paper/.
# Needs the comp server running on 127.0.0.1:8777 (preview "comps").
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'tools\out\paper'
New-Item -ItemType Directory -Force $out | Out-Null
Add-Type -AssemblyName System.Drawing
$jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$params = New-Object System.Drawing.Imaging.EncoderParameters 1
$params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 85L

foreach ($n in 1, 2) {
  $png = Join-Path $out "page$n.png"
  & $chrome --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$env:TEMP\ca-shoot-profile" `
    --window-size=1240,1754 --virtual-time-budget=8000 --screenshot="$png" "http://127.0.0.1:8777/paper/sample.html?page=$n" 2>$null | Out-Null
  $img = [System.Drawing.Image]::FromFile($png)
  $jpg = Join-Path $out "page$n.jpg"
  $img.Save($jpg, $jpeg, $params)
  $img.Dispose()
  Remove-Item $png
  "{0}  {1:N0} bytes" -f "page$n.jpg", (Get-Item $jpg).Length
}
