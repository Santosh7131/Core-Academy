# Tiles phone screenshots into one image for review.
# Usage: .\tools\contact-sheet.ps1 -Out design\screenshots\sheet-teacher-light.png -Names t-today-light,t-students-light,...
param([Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][string[]]$Names, [int]$Columns = 4, [int]$Width = 420)

Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$dir = Join-Path $root 'design\screenshots\app'
$imgs = foreach ($n in $Names) { [System.Drawing.Image]::FromFile((Join-Path $dir "$n.png")) }
$h = [int]($Width * $imgs[0].Height / $imgs[0].Width)
$gap = 16
$rows = [math]::Ceiling($imgs.Count / $Columns)
$sheet = New-Object System.Drawing.Bitmap (($Width + $gap) * $Columns + $gap), (($h + $gap) * $rows + $gap)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.Clear([System.Drawing.Color]::FromArgb(226, 226, 232))
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
for ($i = 0; $i -lt $imgs.Count; $i++) {
  $x = $gap + ($i % $Columns) * ($Width + $gap)
  $y = $gap + [math]::Floor($i / $Columns) * ($h + $gap)
  $g.DrawImage($imgs[$i], $x, $y, $Width, $h)
  $imgs[$i].Dispose()
}
$g.Dispose()
$target = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }
$sheet.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
$sheet.Dispose()
$target
