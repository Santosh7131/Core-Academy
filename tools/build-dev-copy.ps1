# Builds a copy of the app to try before a version goes live: release speed (so it feels as the real one will), its own app id
# (com.coreacademy.core_academy.dev, named "Core Academy Dev") so it sits beside the live app, and the dev server's address, so nothing
# it does touches the live data. Signed with the release key, arm64 only (that is every current phone).
#
#   .\tools\build-dev-copy.ps1      # writes tools\out\core-academy-dev-<version>.apk and checks it
$ErrorActionPreference = 'Stop'

# Flutter prints warnings and progress on stderr, which PowerShell turns into a fatal error under 'Stop' whenever the output is
# captured; judge it by its exit code instead.
function Invoke-Native([string]$What, [scriptblock]$Run) {
  $ErrorActionPreference = 'Continue'
  & $Run
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

$root = Split-Path $PSScriptRoot -Parent
$devApi = 'https://br-nameless-shape-azg23hcy-api.compute.c-3.ap-southeast-1.aws.neon.tech'
$liveHost = 'br-cold-shape-azcvozbw'
$line = (Get-Content (Join-Path $root 'app\pubspec.yaml')) -match '^version:\s*' | Select-Object -First 1
if ($line -notmatch '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'No version like 1.2.0+3 in pubspec.yaml' }
$version = "$($Matches[1])+$($Matches[2])"

Push-Location (Join-Path $root 'app')
try {
  Invoke-Native 'flutter build' {
    & C:\src\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --android-project-arg=devCopy=true "--dart-define=API_BASE=$devApi"
  }
} finally { Pop-Location }

$built = Join-Path $root 'app\build\app\outputs\flutter-apk\app-release.apk'
$out = Join-Path $root "tools\out\core-academy-dev-$($version.Replace('+', '-b')).apk"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
Copy-Item $built $out -Force

# Check what was built: the app id and name, that the dev server's address is inside it and the live one is not, and the signature.
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:USERPROFILE 'Android\Sdk' }
$tools = Get-ChildItem (Join-Path $sdk 'build-tools') | Sort-Object Name -Descending | Select-Object -First 1
$badging = & (Join-Path $tools.FullName 'aapt2.exe') dump badging $out
$pkg = ($badging | Select-String "^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'").Matches[0]
$label = ($badging | Select-String "^application-label:'([^']+)'").Matches[0].Groups[1].Value
"package $($pkg.Groups[1].Value), version $($pkg.Groups[3].Value) (build $($pkg.Groups[2].Value)), named $label"
if ($pkg.Groups[1].Value -ne 'com.coreacademy.core_academy.dev') { throw 'This is not the dev copy: its app id has no .dev' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($out)
try {
  $entry = $zip.Entries | Where-Object { $_.FullName -eq 'lib/arm64-v8a/libapp.so' }
  $bytes = New-Object byte[] $entry.Length
  $s = $entry.Open(); $read = 0
  while ($read -lt $bytes.Length) { $read += $s.Read($bytes, $read, $bytes.Length - $read) }
  $s.Dispose()
  $text = [Text.Encoding]::ASCII.GetString($bytes)
  $hasDev = $text.Contains($devApi)
  $hasLive = $text.Contains($liveHost)
} finally { $zip.Dispose() }
"the dev server's address is inside: $hasDev; the live server's address is inside: $hasLive"
if (-not $hasDev -or $hasLive) { throw 'The build does not point at the dev server alone' }

& (Join-Path $tools.FullName 'apksigner.bat') verify --print-certs $out | Select-Object -First 3
"$out ({0:N1} MB)" -f ((Get-Item $out).Length / 1MB)
