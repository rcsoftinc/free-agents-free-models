<#
.SYNOPSIS
  Checks provider token/credit status for credentials configured in opencode.
  Cached to data/balance-cache.json; respects cache unless -Force.

.DESCRIPTION
  Reads ~/.local/share/opencode/auth.json (keys are NEVER printed) and, per
  known provider, queries a quota endpoint:
    - openrouter : GET /api/v1/auth/key  -> global key usage, limit_remaining,
                                            is_free_tier. NOTE: ':free' models
                                            additionally carry per-model DAILY
                                            request caps managed by OpenRouter
                                            (~50 req/day on free tier); those
                                            caps are not exposed by this API,
                                            they surface as rate-limit errors.
    - freemodel  : no public balance endpoint known -> status "probe-only"
                   ("Unauthorized: Insufficient balance" at runtime = drained).
    - opencode   : zen models are cost=0; no balance endpoint -> "probe-only".
  Exit codes: 0 ok, 1 no usable provider/quota evidence of credit.

.NOTES
  Agent-agnostic: only wraps the opencode CLI + its auth store.
#>
[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$pkgRoot   = Split-Path -Parent $PSScriptRoot
$dataDir   = Join-Path $pkgRoot 'data'
$cachePath = Join-Path $dataDir 'balance-cache.json'
$config    = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json

function Write-Json([string]$path, [object]$obj) {
  $json = $obj | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Render-Provider([object]$p) {
  $parts = @("[$($p.provider)]")
  if ($null -ne $p.usageUsd)     { $parts += "used=`$$($p.usageUsd)" }
  if ($null -ne $p.remainingUsd) { $parts += "remaining=`$$($p.remainingUsd)" }
  elseif ($null -ne $p.limitUsd) { $parts += "limit=`$$($p.limitUsd) (exhausted)" }
  if ($null -ne $p.freeTier)     { $parts += "freeTier=$($p.freeTier)" }
  if ($p.note)                   { $parts += "- $($p.note)" }
  Write-Host ($parts -join ' ')
}

$authPath = $config.authJsonPath -replace '^~/', "$env:USERPROFILE\"
if (-not (Test-Path -LiteralPath $authPath)) {
  if ($AsJson) { Write-Json $cachePath @{ providers = @(); checkedAt = (Get-Date).ToUniversalTime().ToString('o'); error = 'auth.json not found' } }
  Write-Error "opencode auth store not found at $authPath"
  exit 1
}

# --- cache -------------------------------------------------------------------
if (-not $Force -and (Test-Path -LiteralPath $cachePath)) {
  try {
    $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
    $ageMin = ((Get-Date) - [datetime]$cache.checkedAtLocal).TotalMinutes
    if ($ageMin -lt $config.balanceCacheMinutes) {
      if ($AsJson) { $cache | ConvertTo-Json -Depth 8 }
      else {
        foreach ($p in $cache.providers) { Render-Provider $p }
        Write-Host "(cached $([math]::Round($ageMin)) min ago; use -Force to recheck)"
      }
      exit 0
    }
  } catch { } # corrupt cache -> recompute
}

# --- gather credentials -------------------------------------------------------
$auth = Get-Content $authPath -Raw | ConvertFrom-Json
$providers = @()

foreach ($prop in $auth.PSObject.Properties) {
  $name = $prop.Name
  if ($name -eq '$schema') { continue }

  if ($name -eq 'openrouter') {
    $key = $prop.Value.key
    $entry = [ordered]@{
      provider   = 'openrouter'
      kind       = 'api'
      reachable  = $false
      usageUsd   = $null
      limitUsd   = $null
      remainingUsd = $null
      freeTier   = $null
      note       = ''
    }
    try {
      $resp = Invoke-RestMethod -Uri $config.openrouterKeyApiUrl -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 20
      $d = $resp.data
      $entry.reachable    = $true
      $entry.usageUsd     = [math]::Round($d.usage, 4)
      $entry.limitUsd     = $d.limit
      $entry.remainingUsd = $d.limit_remaining
      $entry.freeTier     = $d.is_free_tier
      $entry.note = if ($null -ne $d.limit_remaining) { 'global key limit not exhausted' }
                    elseif ($null -eq $d.limit)       { 'no hard limit set (pay-as-you-go); :free models still have daily request caps' }
                    else                               { '' }
    } catch {
      $entry.note = "key check failed: $($_.Exception.Message)"
    }
    $providers += ,([pscustomobject]$entry)
  }
  elseif ($name -eq 'freemodel') {
    $providers += [pscustomobject]@{
      provider  = 'freemodel'; kind = $prop.Value.type; reachable = $null
      usageUsd = $null; limitUsd = $null; remainingUsd = $null; freeTier = $null
      note      = 'no public balance endpoint; runtime errors report "Insufficient balance" when drained (probe-only)'
    }
  }
  elseif ($name -eq 'opencode') {
    $providers += [pscustomobject]@{
      provider  = 'opencode'; kind = $prop.Value.type; reachable = $null
      usageUsd = $null; limitUsd = $null; remainingUsd = $null; freeTier = $true
      note      = 'zen models are cost=0; probe-only'
    }
  }
  elseif ($name -eq 'kilo') {
    $providers += [pscustomobject]@{
      provider  = 'kilo'; kind = $prop.Value.type; reachable = $null
      usageUsd = $null; limitUsd = $null; remainingUsd = $null; freeTier = $null
      note      = 'no public balance endpoint; probe-only'
    }
  }
  else {
    $providers += [pscustomobject]@{
      provider  = $name; kind = $prop.Value.type; reachable = $null
      usageUsd = $null; limitUsd = $null; remainingUsd = $null; freeTier = $null
      note      = 'unknown provider; probe-only'
    }
  }
}

$result = [pscustomobject]@{
  checkedAt      = (Get-Date).ToUniversalTime().ToString('o')
  checkedAtLocal = (Get-Date).ToString('o')
  providers      = $providers
}
Write-Json $cachePath $result

if ($AsJson) { $result | ConvertTo-Json -Depth 8; exit 0 }

foreach ($p in $providers) { Render-Provider $p }
exit 0
