# Builds a signed release of the app and publishes it on GitHub with the update feed that
# installed copies read (app/lib/core/updater.dart). Every phone on 1.2.0 or later then offers
# the update by itself.
#
#   .\tools\release-app.ps1 -Notes notes.txt              # build, then publish v<version>
#   .\tools\release-app.ps1 -Notes notes.txt -NoPublish   # build and write the files only
#
# Raise `version:` in app/pubspec.yaml first; the number after + must go up every release.
# The notes file is plain text: the GitHub release shows it, and so does the app's
# "What is new" card (with ** marks removed).
param([Parameter(Mandatory = $true)][string]$Notes, [switch]$NoPublish)
$ErrorActionPreference = 'Stop'

# Flutter and gh print warnings and progress on stderr, which PowerShell turns into a fatal
# error under 'Stop' whenever the output is captured; judge them by their exit code instead.
function Invoke-Native([string]$What, [scriptblock]$Run) {
  $ErrorActionPreference = 'Continue'
  & $Run
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

$root = Split-Path $PSScriptRoot -Parent
$repo = 'Santosh7131/Core-Academy'
$line = (Get-Content (Join-Path $root 'app\pubspec.yaml')) -match '^version:\s*' | Select-Object -First 1
if ($line -notmatch '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw "No version like 1.2.0+3 in pubspec.yaml" }
$version = $Matches[1]
$build = [int]$Matches[2]
$tag = "v$version"
$text = (Get-Content -Raw -Encoding utf8 (Resolve-Path $Notes)).Trim()

# Needs app/android/key.properties and the keystore it names. ARM only: that is every phone.
Push-Location (Join-Path $root 'app')
try {
  Invoke-Native 'flutter build' { & C:\src\flutter\bin\flutter.bat build apk --release --target-platform android-arm,android-arm64 }
} finally { Pop-Location }

$out = Join-Path $root 'tools\out'
New-Item -ItemType Directory -Force $out | Out-Null
$apk = Join-Path $out "core-academy-$version.apk"
Copy-Item (Join-Path $root 'app\build\app\outputs\flutter-apk\app-release.apk') $apk -Force

$feed = [ordered]@{
  version = $version
  build   = $build
  apk     = "https://github.com/$repo/releases/download/$tag/core-academy-$version.apk"
  sha256  = (Get-FileHash $apk -Algorithm SHA256).Hash.ToLower()
  size    = (Get-Item $apk).Length
  notes   = $text -replace '\*\*', ''
}
$json = Join-Path $out 'update.json'
# UTF-8 without a byte-order mark, which the app's JSON reader expects.
[IO.File]::WriteAllText($json, ($feed | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
"$apk"
"$json  (build $build, $($feed.size) bytes, sha256 $($feed.sha256))"

if ($NoPublish) { return }
$notesFile = Join-Path $out "notes-$version.md"
[IO.File]::WriteAllText($notesFile, $text, (New-Object Text.UTF8Encoding $false))
Invoke-Native 'gh release create' { gh release create $tag $apk $json --repo $repo --title "Core Academy $version" --notes-file $notesFile }
# The feed every installed copy reads; it should now name this version.
$r = Invoke-WebRequest "https://github.com/$repo/releases/latest/download/update.json" -UseBasicParsing
if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { $r.Content }
