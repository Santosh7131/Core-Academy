# Uploads the Firebase service-account key (api/firebase-service-account.json, git-ignored) to the
# api function on a Neon branch, so the server can send push notifications. Run once per branch.
# Like upload-groq-keys.ps1 this redeploys the function from the local source, so on main run it
# only as part of a release. Each deploy merges --env into the variables already set, so the Groq
# keys stay. The key goes up base64-encoded: one line, nothing for the shell to mangle.
# Usage: powershell -ExecutionPolicy Bypass -File tools/upload-firebase-key.ps1 [-Branch dev]
param([string]$Branch = 'dev')

$root = Split-Path $PSScriptRoot -Parent
$file = Join-Path $root 'api\firebase-service-account.json'
if (-not (Test-Path $file)) { throw 'api/firebase-service-account.json was not found' }
$json = Get-Content $file -Raw | ConvertFrom-Json
if (-not $json.project_id -or -not $json.client_email -or -not $json.private_key) {
  throw 'That file is not a Firebase service-account key (no project_id, client_email or private_key)'
}
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file))

Push-Location $root
try {
  neon functions deploy api --src api/src/index.ts --branch $Branch --env "FIREBASE_SERVICE_ACCOUNT=$b64"
} finally {
  Pop-Location
}
