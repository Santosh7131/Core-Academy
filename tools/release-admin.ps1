# Builds a signed release of the admin app and puts it in private storage, where the admin app
# on the developer's phone finds it (Settings, or the card on Overview) and installs it itself.
# Nothing is published: only the developer login can download it.
#
#   .\tools\release-admin.ps1 -Notes notes.txt                # live (main) storage
#   .\tools\release-admin.ps1 -Notes notes.txt -Env .env.local  # dev storage, for trying it
#
# Raise `version:` in admin/pubspec.yaml first; the number after + must go up every release.
# The very first install is by hand: the APK is also copied to tools/out (git-ignored).
param([string]$Notes, [string]$Env = '.env.main')
$ErrorActionPreference = 'Stop'

function Invoke-Native([string]$What, [scriptblock]$Run) {
  $ErrorActionPreference = 'Continue'
  & $Run
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

$root = Split-Path $PSScriptRoot -Parent
# Resolved now, before the build moves between folders.
$notesPath = if ($Notes) { (Resolve-Path $Notes).Path } else { $null }
$line = (Get-Content (Join-Path $root 'admin\pubspec.yaml')) -match '^version:\s*' | Select-Object -First 1
if ($line -notmatch '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'No version like 1.0.0+1 in admin/pubspec.yaml' }
$version = $Matches[1]
$build = $Matches[2]

Push-Location (Join-Path $root 'admin')
try {
  Invoke-Native 'flutter build' { & C:\src\flutter\bin\flutter.bat build apk --release --target-platform android-arm,android-arm64 }
} finally { Pop-Location }

$out = Join-Path $root 'tools\out'
New-Item -ItemType Directory -Force $out | Out-Null
$apk = Join-Path $out "core-academy-admin-$version.apk"
Copy-Item (Join-Path $root 'admin\build\app\outputs\flutter-apk\app-release.apk') $apk -Force

Push-Location $root
try {
  $noteArgs = if ($notesPath) { @('--notes', $notesPath) } else { @() }
  Invoke-Native 'upload' { node tools/upload-admin.ts --env $Env --apk $apk --version $version --build $build @noteArgs }
} finally { Pop-Location }
"$apk"
