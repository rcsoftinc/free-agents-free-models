<#
.SYNOPSIS
  One-time setup bridge for Windows: merges .env into opencode's auth.json.

.DESCRIPTION
  opencode does NOT read .env files natively. This script does the bridging.
  auth.json belongs to OPENCODE (~/.local/share/opencode/auth.json); we only
  merge entries, never remove. You maintain .env exclusively.

  .env resolution order (first found wins):
    1. -EnvFile parameter
    2. $PWD\.env
    3. <skill folder>\.env
    4. $HOME\.config\opencode-free-agents\.env  (machine-global)
    5. none -> continue with existing credentials (additive-only, never fails)

  Safety: auth.json is backed up before first modification, created with ACLs,
  keys are NEVER printed in output. -SelfTest flag runs a full sandbox test
  without touching any real file.

.PARAMETER EnvFile
  Explicit path to an .env file.

.PARAMETER Force
  Overwrite keys that changed since last merge.

.PARAMETER NoRefresh
  Skip running refresh.ps1 after merging keys.

.PARAMETER SelfTest
  Run end-to-end test with fake keys in a temp sandbox. No real files touched.

.EXAMPLE
  bootstrap.ps1 -Force
  bootstrap.ps1 -EnvFile "D:\secrets\.env" -SelfTest
  powershell -File scripts\bootstrap.ps1 -SelfTest    # required invocation syntax
#>
[CmdletBinding()]
param(
  [string]$EnvFile,
  [switch]$Force,
  [switch]$NoRefresh,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$PkgRoot     = Split-Path -Parent $ScriptDir
$AuthFile    = Join-Path $env:USERPROFILE '.local\share\opencode\auth.json'

function Log([string]$msg)  { Write-Host "[bootstrap] $msg" }
function Warn([string]$msg) { Write-Host "[bootstrap] WARNING: $msg" -ForegroundColor Yellow }
function Die([string]$msg)  { Write-Host "[bootstrap] ERROR: $msg" -ForegroundColor Red; exit 3 }
function Mask([string]$k)   { if ($k.Length -le 10) { "***" } else { "$($k.Substring(0,4))...$($k.Substring($k.Length-4))" } }

# --- safe KEY=VALUE parser (never executes content) ----------------------------
function Parse-Env([string]$path) {
  $entries = [ordered]@{}
  foreach ($line in (Get-Content $path)) {
    $l = $line.Trim()
    if ($l -match '^\s*#' -or $l -match '^\s*$') { continue }
    if ($l -notmatch '=') { continue }
    $key = ($l -split '=', 2)[0].Trim()
    $val = ($l -split '=', 2)[1].Trim()
    if ($val.Length -ge 2) {
      if (($val[0] -eq '"' -and $val[$val.Length-1] -eq '"') -or
          ($val[0] -eq "'" -and $val[$val.Length-1] -eq "'")) {
        $val = $val.Substring(1, $val.Length - 2)
      }
    }
    if ($key -and $val) { $entries[$key] = $val }
  }
  return $entries
}

# --- alias map: ENV VAR -> opencode provider id ---------------------------------
function Alias-ToProvider([string]$key) {
  $map = @{
    'OPENROUTER_API_KEY'   = 'openrouter'
    'FREEMODEL_API_KEY'    = 'freemodel'
    'OPENCODE_ZEN_API_KEY' = 'opencode'
    'ANTHROPIC_API_KEY'    = 'anthropic'
    'OPENAI_API_KEY'       = 'openai'
    'GROQ_API_KEY'         = 'groq'
    'DEEPSEEK_API_KEY'     = 'deepseek'
    'NVIDIA_API_KEY'       = 'nvidia'
    'TOGETHER_API_KEY'     = 'together-ai'
    'MISTRAL_API_KEY'      = 'mistral'
    'XAI_API_KEY'          = 'xai'
    'KILO_GATEWAY_API_KEY' = 'kilo'
  }
  if ($map.ContainsKey($key)) { return $map[$key] }
  return ''
}

# --- merge one key into auth.json ------------------------------------------------
function Merge-Key([string]$id, [string]$key, [string]$type = 'api', [ref]$merged, [ref]$skipped) {
  $dir = Split-Path -Parent $AuthFile
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (-not (Test-Path -LiteralPath $AuthFile)) {
    '{}' | Set-Content -Path $AuthFile -Encoding UTF8 -NoNewline
  }
  if (-not (Test-Path -LiteralPath "$AuthFile.bak.bootstrap")) {
    Copy-Item -LiteralPath $AuthFile -Destination "$AuthFile.bak.bootstrap" -Force
  }
  $existing = ''
  try { $obj = Get-Content $AuthFile -Raw | ConvertFrom-Json; if ($obj.PSObject.Properties.Name -contains $id) { $existing = $obj.$id.key } } catch {}
  if ($existing -eq $key) { $skipped.Value++; return }
  if ($existing -and -not $Force) { Log "[$id] already configured ($(($existing.Substring(0,6))))... - keeping existing (use -Force to override)"; $skipped.Value++; return }
  $tmp = "$AuthFile.tmp"
  $obj = Get-Content $AuthFile -Raw | ConvertFrom-Json
  if ($null -eq $obj) { $obj = @{} }
  $obj | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{ type = $type; key = $key }) -Force
  ($obj | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8 -NoNewline
  Move-Item -LiteralPath $tmp -Destination $AuthFile -Force
  Log "[$id] merged key $(Mask "$key")"
  $merged.Value++
}

# --- locate .env ----------------------------------------------------------------
$locatedEnv = $null
if ($EnvFile -and (Test-Path -LiteralPath $EnvFile)) { $locatedEnv = $EnvFile }
if (-not $locatedEnv) {
  foreach ($cand in @(
    (Join-Path (Get-Location).Path '.env'),
    (Join-Path $PkgRoot '.env'),
    (Join-Path "$env:USERPROFILE\.config\opencode-free-agents" '.env')
  )) {
    if (Test-Path -LiteralPath $cand) { $locatedEnv = $cand; break }
  }
}

# --- SELF-TEST (sandbox only) ----------------------------------------------------
if ($SelfTest) {
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "oc-bootstrap-test-$([guid]::NewGuid().ToString('n').Substring(0,8))"
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  @('OPENROUTER_API_KEY="sk-or-test-1234567890abcd"',
    "FREEMODEL_API_KEY='fe_test_9876543210'",
    'PROVIDER_1_ID=my-provider',
    'PROVIDER_1_KEY=pk_custom_42',
    'PROVIDER_2_ID=openrouter',
    'PROVIDER_2_KEY=ignored_duplicate'
  ) | Set-Content (Join-Path $tmp '.env') -Encoding UTF8
  $origAuth = $AuthFile
  $AuthFile = Join-Path $tmp 'auth.json'
  try {
    $entries = Parse-Env (Join-Path $tmp '.env')
    $genericIds = @{}
    $totalMerged = 0; $totalSkipped = 0
    foreach ($key in $entries.Keys) {
      $val = $entries[$key]
      $providerId = Alias-ToProvider $key
      if ($providerId) { Merge-Key $providerId $val 'api' ([ref]$totalMerged) ([ref]$totalSkipped) }
      elseif ($key -match '^PROVIDER_(\d+)_ID$') { $genericIds[$Matches[1]] = $val }
    }
    foreach ($key in $entries.Keys) {
      if ($key -match '^PROVIDER_(\d+)_KEY$') {
        $idx = $Matches[1]
        $val = $entries[$key]
        $genId = $genericIds[$idx]
        if (-not $genId) { Warn "$key without matching PROVIDER_${idx}_ID - skipped"; continue }
        $genType = if ($entries.Contains("PROVIDER_${idx}_TYPE")) { $entries["PROVIDER_${idx}_TYPE"] } else { 'api' }
        Merge-Key $genId $val $genType ([ref]$totalMerged) ([ref]$totalSkipped)
      }
    }
    $obj = Get-Content $AuthFile -Raw | ConvertFrom-Json
    $providers = @($obj.PSObject.Properties | Where-Object { $_.Name -ne '$schema' })
    $pass = $true
    if ($providers.Count -ne 3)                { Warn "expected 3 providers, got $($providers.Count)"; $pass = $false }
    if ($obj.openrouter.key -ne 'sk-or-test-1234567890abcd') { Warn "openrouter key wrong"; $pass = $false }
    if ($obj.freemodel.key  -ne 'fe_test_9876543210')         { Warn "freemodel key wrong";  $pass = $false }
    if ($obj.'my-provider'.key -ne 'pk_custom_42')            { Warn "generic block wrong";  $pass = $false }
    if ($obj.openrouter.type -ne 'api')  { Warn "type wrong"; $pass = $false }
    if ($pass) { Log "SELF-TEST PASS"; exit 0 }
    else { Warn "SELF-TEST FAIL"; exit 1 }
  } finally {
    $AuthFile = $origAuth
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

# --- main merge ------------------------------------------------------------------
if (-not $locatedEnv) {
  Log "no .env found (looked at `$PWD\.env, skill folder, ~\.config\opencode-free-agents\.env)"
  Log "continuing with existing credentials"
} else {
  Log "using env file: $locatedEnv"
  $entries = Parse-Env "$locatedEnv"
  $genericIds = @{}   # index -> provider id
  $totalMerged = 0; $totalSkipped = 0

  foreach ($key in $entries.Keys) {
    $val = $entries[$key]
    $providerId = Alias-ToProvider $key
    if ($providerId) {
      Merge-Key $providerId $val 'api' ([ref]$totalMerged) ([ref]$totalSkipped)
    }
    elseif ($key -match '^PROVIDER_(\d+)_ID$') {
      $genericIds[$Matches[1]] = $val
    }
  }
  foreach ($key in $entries.Keys) {
    if ($key -match '^PROVIDER_(\d+)_KEY$') {
      $idx = $Matches[1]
      $val = $entries[$key]
      $genId = $genericIds[$idx]
      if (-not $genId) { Warn "$key without matching PROVIDER_${idx}_ID - skipped"; continue }
      $genType = if ($entries.Contains("PROVIDER_${idx}_TYPE")) { $entries["PROVIDER_${idx}_TYPE"] } else { 'api' }
      Merge-Key $genId $val $genType ([ref]$totalMerged) ([ref]$totalSkipped)
    }
  }
}

try { $acl = Get-Acl $AuthFile; $acl.SetAccessRuleProtection($true, $false); Set-Acl $AuthFile $acl } catch {}

# --- sanity check ----------------------------------------------------------------
if (-not $NoRefresh) {
  Log "running initial refresh (first run discovers free models)..."
  & (Join-Path $ScriptDir 'refresh.ps1') -Force
}

Log "bootstrap complete"
exit 0
