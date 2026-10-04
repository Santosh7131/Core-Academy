# Taps app elements by their accessibility label or text, using uiautomator.
# Usage:
#   .\tools\ui.ps1 tap "Practice set"                     # first node whose text/label contains it
#   .\tools\ui.ps1 go "Practice set" -Expect "Your marks"  # tap, then wait for the next screen (retries once)
#   .\tools\ui.ps1 list                                    # labelled nodes with their centres (px)
param([Parameter(Position = 0)][string]$Cmd, [Parameter(Position = 1)][string]$Label, [string]$Expect, [switch]$Last, [switch]$Exact)

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:USERPROFILE 'Android\Sdk' }
$adb = Join-Path $sdk 'platform-tools\adb.exe'
# The phone to drive: PHONE_SERIAL, or else the only phone adb can see.
$serial = $env:PHONE_SERIAL
if (-not $serial) {
  $phones = @(& $adb devices | Select-String -Pattern '^(\S+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
  # The same phone shows up twice when it is on USB and wireless debugging at once; USB wins.
  $usb = @($phones | Where-Object { $_ -notmatch ':|_adb-tls' })
  if ($usb.Count -eq 1) { $phones = $usb }
  if ($phones.Count -ne 1) { "Connect one phone or set PHONE_SERIAL (adb sees $($phones.Count))"; exit 2 }
  $serial = $phones[0]
}
$local = Join-Path $env:TEMP 'ca-ui.xml'

function Dump {
  & $adb -s $serial shell uiautomator dump /sdcard/ca-ui.xml 2>$null | Out-Null
  & $adb -s $serial pull /sdcard/ca-ui.xml $local 2>$null | Out-Null
  [xml](Get-Content $local -Raw -Encoding utf8)
}

function Nodes($xml) {
  foreach ($n in $xml.SelectNodes('//node')) {
    $t = "$($n.text) $($n.'content-desc')".Trim()
    if (-not $t) { continue }
    if ($n.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      [pscustomobject]@{ label = ($t -replace '\s+', ' '); x = [int](([int]$matches[1] + [int]$matches[3]) / 2); y = [int](([int]$matches[2] + [int]$matches[4]) / 2) }
    }
  }
}

# Never touch another app on the phone: every tap first checks Core Academy is in front.
function Assert-Ours {
  $top = & $adb -s $serial shell dumpsys activity activities | Select-String -Pattern 'topResumedActivity' | Select-Object -First 1
  if ("$top" -notmatch 'com\.coreacademy\.core_academy') { "REFUSED: Core Academy is not in front ($("$top".Trim()))"; exit 2 }
}

function Find($nodes, $text) {
  $hits = if ($Exact) { $nodes | Where-Object { $_.label -eq $text } } else { $nodes | Where-Object { $_.label -like "*$text*" } }
  if ($Last) { $hits | Select-Object -Last 1 } else { $hits | Select-Object -First 1 }
}

switch ($Cmd) {
  'list' { Nodes (Dump) | ForEach-Object { '{0,5},{1,5}  {2}' -f $_.x, $_.y, $_.label.Substring(0, [Math]::Min(90, $_.label.Length)) } }
  'field' {
    # Taps the Nth text field (1-based); text fields carry no label of their own.
    Assert-Ours
    $n = if ($Label) { [int]$Label } else { 1 }
    $fields = @((Dump).SelectNodes("//node[@class='android.widget.EditText']"))
    if ($fields.Count -lt $n) { "NO FIELD $n (found $($fields.Count))"; exit 1 }
    if ($fields[$n - 1].bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      & $adb -s $serial shell input tap ([int](([int]$matches[1] + [int]$matches[3]) / 2)) ([int](([int]$matches[2] + [int]$matches[4]) / 2))
      "tapped field $n"
    }
  }
  'tap' {
    Assert-Ours
    $hit = Find @(Nodes (Dump)) $Label
    if (-not $hit) { "NOT FOUND: $Label"; exit 1 }
    & $adb -s $serial shell input tap $hit.x $hit.y
    "tapped '$Label'"
  }
  'go' {
    Assert-Ours
    for ($try = 1; $try -le 2; $try++) {
      $hit = Find @(Nodes (Dump)) $Label
      if (-not $hit) {
        if ($Expect -and (Find @(Nodes (Dump)) $Expect)) { "already on '$Expect'"; exit 0 }
        "NOT FOUND: $Label"; exit 1
      }
      Start-Sleep -Milliseconds 400
      & $adb -s $serial shell input tap $hit.x $hit.y
      if (-not $Expect) { "tapped '$Label'"; exit 0 }
      for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 700
        if (Find @(Nodes (Dump)) $Expect) { "'$Label' -> '$Expect'"; exit 0 }
      }
    }
    "TIMEOUT waiting for '$Expect' after tapping '$Label'"; exit 1
  }
  default { 'commands: list, tap <label>, go <label> -Expect <label>' }
}
