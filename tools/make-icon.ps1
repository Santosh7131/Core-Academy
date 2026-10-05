# Renders the launcher icon from design/icon/icon.html with headless Chrome and writes the
# Android launcher resources (legacy PNGs, adaptive foreground + monochrome, background colour).
# Usage: .\tools\make-icon.ps1            # writes app/android/app/src/main/res
#        .\tools\make-icon.ps1 -App admin # the admin app's icon, into admin/android/app/src/main/res
#        .\tools\make-icon.ps1 -Preview   # only renders design/icon/preview.png
param([switch]$Preview, [ValidateSet('app', 'admin')][string]$App = 'app')

Add-Type -AssemblyName System.Drawing
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$root = Split-Path $PSScriptRoot -Parent
$page = 'file:///' + ((Join-Path $root 'design\icon\icon.html') -replace '\\', '/' -replace ' ', '%20')
$work = Join-Path $env:TEMP 'ca-icon'
New-Item -ItemType Directory -Force $work | Out-Null

function Render([string]$layer, [string]$file, [int]$w, [int]$h) {
  if (Test-Path $file) { Remove-Item $file }
  & $chrome --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check `
    --user-data-dir="$work\profile" --default-background-color=00000000 --window-size="$w,$h" `
    --virtual-time-budget=3000 --screenshot="$file" "$page`?layer=$layer&app=$App" 2>$null | Out-Null
  if (-not (Test-Path $file)) { throw "Chrome did not render $layer" }
}

if ($Preview) {
  $out = Join-Path $root $(if ($App -eq 'admin') { 'design\icon\preview-admin.png' } else { 'design\icon\preview.png' })
  Render 'preview' $out 1500 980
  $out
  return
}

function Scale([string]$src, [string]$dst, [int]$size) {
  $img = [System.Drawing.Image]::FromFile($src)
  $bmp = New-Object System.Drawing.Bitmap $size, $size
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($img, 0, 0, $size, $size)
  $g.Dispose(); $img.Dispose()
  $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

$legacy = Join-Path $work 'legacy.png'
$fore = Join-Path $work 'foreground.png'
Render 'legacy' $legacy 1024 1024
Render 'foreground' $fore 1024 1024

$res = Join-Path $root "$App\android\app\src\main\res"
# Legacy icons are 48dp; adaptive layers are 108dp.
$densities = [ordered]@{ mdpi = 1.0; hdpi = 1.5; xhdpi = 2.0; xxhdpi = 3.0; xxxhdpi = 4.0 }
foreach ($d in $densities.Keys) {
  $dir = Join-Path $res "mipmap-$d"
  New-Item -ItemType Directory -Force $dir | Out-Null
  Scale $legacy (Join-Path $dir 'ic_launcher.png') ([int](48 * $densities[$d]))
  Scale $fore (Join-Path $dir 'ic_launcher_foreground.png') ([int](108 * $densities[$d]))
}

$anydpi = Join-Path $res 'mipmap-anydpi-v26'
New-Item -ItemType Directory -Force $anydpi | Out-Null
Set-Content -Encoding utf8 (Join-Path $anydpi 'ic_launcher.xml') @'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
'@
Set-Content -Encoding utf8 (Join-Path $res 'values\ic_launcher_background.xml') @'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">BACKGROUND</color>
</resources>
'@
$bgFile = Join-Path $res 'values\ic_launcher_background.xml'
(Get-Content -Raw $bgFile).Replace('BACKGROUND', $(if ($App -eq 'admin') { '#FAFAFB' } else { '#0E0E11' })) | Set-Content -Encoding utf8 -NoNewline $bgFile
'icon resources written'
