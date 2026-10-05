# Uploads the AI keys from api/.env.secrets to the api function on a Neon branch: the Groq keys,
# and the Gemini key when the file has one (Gemini then reads the pages). Run once per branch (dev
# now, main when the app goes live). Later `neon deploy` runs keep the keys.
# Usage: powershell -ExecutionPolicy Bypass -File tools/upload-groq-keys.ps1 [-Branch dev]
param([string]$Branch = 'dev')

$root = Split-Path $PSScriptRoot -Parent
$lines = Get-Content (Join-Path $root 'api\.env.secrets')
$groq = $lines | Where-Object { $_ -like 'GROQ_API_KEYS=*' } | Select-Object -First 1
if (-not $groq) { throw 'GROQ_API_KEYS was not found in api/.env.secrets' }
$envs = @('--env', $groq)
$gemini = $lines | Where-Object { $_ -like 'GEMINI_API_KEY=*' } | Select-Object -First 1
if ($gemini) { $envs += @('--env', $gemini) }

Push-Location $root
try {
  neon functions deploy api --src api/src/index.ts --branch $Branch @envs
} finally {
  Pop-Location
}
