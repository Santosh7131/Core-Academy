# Uploads the Groq keys from api/.env.secrets to the api function on a Neon branch.
# Run once per branch (dev now, main when the app goes live). Later `neon deploy` runs keep the keys.
# Usage: powershell -ExecutionPolicy Bypass -File tools/upload-groq-keys.ps1 [-Branch dev]
param([string]$Branch = 'dev')

$root = Split-Path $PSScriptRoot -Parent
$line = Get-Content (Join-Path $root 'api\.env.secrets') | Where-Object { $_ -like 'GROQ_API_KEYS=*' } | Select-Object -First 1
if (-not $line) { throw 'GROQ_API_KEYS was not found in api/.env.secrets' }

Push-Location $root
try {
  neon functions deploy api --src api/src/index.ts --branch $Branch --env $line
} finally {
  Pop-Location
}
