<#
.SYNOPSIS
  Full maintenance cycle: balance check -> discover free models from metadata ->
  rebuild category rankings. Run manually or on a schedule; oc.ps1 also triggers
  it when the model list is stale (config.autoRefreshOnStale).

.EXAMPLE
  refresh.ps1              # respects staleness; cheap incremental pass
  refresh.ps1 -Force       # destroy and recreate from scratch

.NOTES
  Exit codes: 0 ok, 3 bootstrap/config error.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$pkgRoot = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $pkgRoot 'data'
$modelsPath  = Join-Path $dataDir 'models.json'
$rankingsPath = Join-Path $dataDir 'rankings.json'
$seedPath    = Join-Path $PSScriptRoot 'rankings-seed.json'
$config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$authFile = if ($env:OPENCODE_AUTH) { $env:OPENCODE_AUTH } else { Join-Path $env:USERPROFILE '.local\share\opencode\auth.json' }

# --- force: destroy and recreate from scratch ----------------------------------
if ($Force) {
  if (Test-Path -LiteralPath $modelsPath)  { Remove-Item -Force -LiteralPath $modelsPath }
  if (Test-Path -LiteralPath $rankingsPath) { Remove-Item -Force -LiteralPath $rankingsPath }
  Write-Host "[refresh] --force: cleared models.json + rankings.json"
}

# --- rate-limit the whole cycle (skipped on --force) ---------------------------
if (-not $Force -and (Test-Path -LiteralPath $modelsPath)) {
  try {
    $m = Get-Content $modelsPath -Raw | ConvertFrom-Json
    $ageH = ((Get-Date) - [datetime]$m.updatedAt).TotalHours
    if ($ageH -lt [double]$config.staleHours) {
      Write-Host ("Model list refreshed {0:N1}h ago (< {1}h). Nothing to do; use -Force." -f $ageH, $config.staleHours)
      exit 0
    }
  } catch { }
}

# --- provider key check --------------------------------------------------------
function Test-ProviderKey([string]$provider) {
  if ($provider -eq 'opencode') { return $true }  # zen works without key
  if (-not (Test-Path -LiteralPath $authFile)) { return $false }
  try {
    $auth = Get-Content $authFile -Raw | ConvertFrom-Json
    $entry = $auth.$provider
    if ($null -ne $entry -and $null -ne $entry.key -and $entry.key -ne '') { return $true }
  } catch { }
  return $false
}

# ============================================================================
# Step 1: Provider balances
# ============================================================================
Write-Host "== [1/2] Provider balances =="
& (Join-Path $PSScriptRoot 'get-balance.ps1') -Force:$Force
if ($LASTEXITCODE -ne 0) { Write-Warning "balance check reported a problem (continuing)" }

# ============================================================================
# Step 2: Discover free models from metadata (instant, no probing)
# ============================================================================
Write-Host "`n== [2/2] Discovering free models =="

$raw = & opencode models --verbose 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "opencode models --verbose failed"; exit 3 }

$discovered = New-Object System.Collections.ArrayList
$currentId = $null; $buf = @()

function Flush-Record {
  if ($null -eq $script:currentId) { return }
  $meta = $script:buf -join "`n" | ConvertFrom-Json -ErrorAction SilentlyContinue
  if ($null -ne $meta) {
    $free = ($meta.cost.input -eq 0 -and $meta.cost.output -eq 0)
    $ctx = [int64]($meta.limit.context)
    $reasoning = [bool]($meta.capabilities.reasoning)
    if ($free) {
      [void]$script:discovered.Add([pscustomobject]@{ id=$script:currentId; context=$ctx; reasoning=$reasoning })
    }
  }
  $script:currentId = $null; $script:buf = @()
}

foreach ($line in $raw) {
  if ($line -match '^[A-Za-z0-9~]') {
    Flush-Record
    $currentId = ($line -split '\s+')[0]
    $buf = @()
  } elseif ($null -ne $currentId) {
    $buf += $line
  }
}
Flush-Record

# build models.json: only free models from providers with keys
$models = New-Object System.Collections.ArrayList
foreach ($d in $discovered) {
  $provider = ($d.id -split '/')[0]
  if (Test-ProviderKey $provider) {
    $rec = [pscustomobject]@{
      id = $d.id; provider = $provider; free = $true; source = 'metadata'
      context = if ($d.context -gt 0) { $d.context } else { $null }
      reasoning = $d.reasoning
    }
    [void]$models.Add($rec)
  }
}

# --- merge manual-overrides.txt -----------------------------------------------
$overridesPath = Join-Path $dataDir 'manual-overrides.txt'
if (Test-Path -LiteralPath $overridesPath) {
  $manualAdded = 0
  foreach ($line in (Get-Content $overridesPath)) {
    $line = $line.Trim()
    if ($line -match '^\s*#' -or $line -eq '') { continue }
    $id = $line -replace '\s', ''
    $exists = @($models | Where-Object { $_.id -eq $id }).Count
    if ($exists -gt 0) { continue }
    $provider = ($id -split '/')[0]
    if (Test-ProviderKey $provider) {
      $rec = [pscustomobject]@{
        id = $id; provider = $provider; free = $true; source = 'manual'
        context = $null; reasoning = $false
      }
      [void]$models.Add($rec)
      $manualAdded++
    }
  }
  if ($manualAdded -gt 0) {
    Write-Host "[refresh] added $manualAdded manual overrides from manual-overrides.txt"
  }
}

$modelsObj = [pscustomobject]@{
  version   = 1
  updatedAt = (Get-Date).ToUniversalTime().ToString('o')
  models    = [object[]]$models.ToArray()
}
$tmp = "$modelsPath.tmp"
$json = $modelsObj | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -Force -LiteralPath $tmp -Destination $modelsPath
Write-Host ("[refresh] discovered {0} free models -> data\models.json" -f $models.Count)

# ============================================================================
# Step 3: Rebuild category rankings
# ============================================================================
Write-Host "`n== [3/2] Rebuilding rankings =="

$seed = Get-Content $seedPath -Raw | ConvertFrom-Json
$lastResort = $config.lastResortModel

function Score([object]$rec) {
  if ($null -eq $rec) { return 0 }
  $ctxVal = if ($null -ne $rec.context) { [double]$rec.context } else { 0 }
  $ctxScore = $ctxVal / 1000.0
  $reasonScore = if ($rec.reasoning) { 50.0 } else { 0.0 }
  return $ctxScore + $reasonScore
}

$excluded = @()
if ($null -ne $seed.excluded -and $null -ne $seed.excluded.models) {
  $excluded = @($seed.excluded.models)
}

$byId = @{}
foreach ($mm in $models) { $byId[$mm.id] = $mm }

$outCategories = [ordered]@{}
foreach ($catProp in $seed.categories.PSObject.Properties) {
  $cat = $catProp.Name
  $ordered = New-Object System.Collections.Generic.List[string]

  foreach ($id in @($catProp.Value)) {
    if ($ordered -notcontains $id -and $id -notin $excluded -and $byId.ContainsKey($id)) {
      $ordered.Add($id)
    }
  }

  # append discovered models missing from seed, best score first
  $extra = @($byId.Keys | Where-Object {
      ($_ -notin $ordered) -and ($_ -notin $excluded) -and ($_ -ne $lastResort)
    } | ForEach-Object {
      $cVal = if ($null -ne $byId[$_].context) { [int64]$byId[$_].context } else { 0 }
      [pscustomobject]@{ id = $_; score = (Score $byId[$_]); ctx = $cVal }
    } | Sort-Object -Property score, ctx -Descending)
  foreach ($e in $extra) { $ordered.Add($e.id) }

  # pin last-resort auto-router at the very end
  if ($ordered -notcontains $lastResort -and $lastResort -notin $excluded -and ($byId.ContainsKey($lastResort) -or -not $excluded.Contains($lastResort))) {
    $ordered.Add($lastResort)
  }

  $outCategories[$cat] = [object[]]$ordered.ToArray()
}

$rankOut = [pscustomobject]@{
  version    = 1
  updatedAt  = (Get-Date).ToUniversalTime().ToString('o')
  categories = $outCategories
}
$rankJson = $rankOut | ConvertTo-Json -Depth 8
$tmp = "$rankingsPath.tmp"
[System.IO.File]::WriteAllText($tmp, $rankJson, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -Force -LiteralPath $tmp -Destination $rankingsPath
Write-Host ("Rankings rebuilt: {0} categories, {1} models -> data\rankings.json" -f $outCategories.Count, $models.Count)
exit 0
