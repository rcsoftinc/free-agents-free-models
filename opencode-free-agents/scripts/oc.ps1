<#
.SYNOPSIS
  Run any opencode task headlessly with automatic free-model fallback.
  THE single entry point agents should use to delegate work to opencode.

.DESCRIPTION
  Selection: picks the best live model for -Category from data/rankings.json,
  filtered by data/models.json status (ok, or failed-but-retry-window-expired).
  Resilience: on failure the error is classified (rate_limited | no_credits |
  dead | timeout | context_overflow | auth_error), recorded to models.json and
  the NEXT model in the chain takes over — continuing the SAME session when
  -SessionId/-Continue is used (verified: history survives model switches).
  Stops with exit code 2 ONLY when every candidate has been exhausted.

  Output contract:
    stdout : model output, then a final machine-readable footer:
             ---OC-META--- {"session":"...","model":"...","attempts":N}
    stderr : [oc] progress diagnostics
  Exit codes: 0 success | 2 all models exhausted | 3 bootstrap error

.EXAMPLE
  oc.ps1 "Fix the failing unit test in src/auth.spec.ts"
  oc.ps1 "Refactor db layer" -Category coding
  oc.ps1 "Continue" -Continue                      # resume last session
  oc.ps1 "What did we decide?" -SessionId ses_xxx  # resume specific session
  oc.ps1 "Quick question..." -Model openrouter/z-ai/glm-5.2:free
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Message,
  [string]$Category = 'general',
  [string]$Model,
  [string]$SessionId,
  [switch]$Continue,
  [switch]$NoAuto,
  [string]$Agent,
  [switch]$Json,
  [switch]$SkipRefresh,
  [int]$TimeoutSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$pkgRoot = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $pkgRoot 'data'
$modelsPath   = Join-Path $dataDir 'models.json'
$rankingsPath = Join-Path $dataDir 'rankings.json'
$config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
if ($TimeoutSeconds -le 0) { $TimeoutSeconds = [int]$config.runTimeoutSeconds }

function Write-Diag([string]$msg) { Write-Host "[oc] $msg" -ForegroundColor DarkGray }
function Get-P([object]$obj, [string]$name, $default = $null) {
  if ($null -eq $obj) { return $default }
  if ($obj.PSObject.Properties.Name -contains $name) { return $obj.$name }
  return $default
}

# opencode on PATH is often an npm .ps1/.cmd shim; find the real exe.
function Resolve-OcExe {
  $c = Get-Command 'opencode' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $c) { throw 'opencode not found on PATH' }
  $src = $c.Source
  if ($src -match '\.(exe|com)$') { return @{ exe = $src; shim = $false } }
  $base = Split-Path -Parent $src
  $cand = Join-Path $base 'node_modules\opencode-ai\bin\opencode.exe'
  if (Test-Path -LiteralPath $cand) { return @{ exe = $cand; shim = $false } }
  return @{ exe = $src; shim = $true }   # launch via cmd.exe
}

$OcExe = Resolve-OcExe

function Start-Oc([string[]]$argList, [string]$workDir, [string]$outF, [string]$errF) {
  if ($OcExe.shim) {
    $cmdLine = "`"" + $OcExe.exe + "`""
    foreach ($a in $argList) { $cmdLine += " `"" + ($a -replace '"', '\"') + "`"" }
    Start-Process -FilePath 'cmd.exe' `
      -ArgumentList "/d /s /c $cmdLine" `
      -WorkingDirectory $workDir -NoNewWindow -PassThru `
      -RedirectStandardOutput $outF -RedirectStandardError $errF
  } else {
    Start-Process -FilePath $OcExe.exe `
      -ArgumentList $argList `
      -WorkingDirectory $workDir -NoNewWindow -PassThru `
      -RedirectStandardOutput $outF -RedirectStandardError $errF
  }
}
function Save-State([object]$state) {
  $json = $state | ConvertTo-Json -Depth 10
  $tmp = "$modelsPath.tmp"
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Force -LiteralPath $tmp -Destination $modelsPath
}

# --- bootstrap: ensure rankings exist / are fresh --------------------------------
$needBootstrap = -not (Test-Path -LiteralPath $modelsPath) -or -not (Test-Path -LiteralPath $rankingsPath)
$needRefresh = $needBootstrap
if (-not $needBootstrap -and [bool]$config.autoRefreshOnStale -and -not $SkipRefresh) {
  try {
    $m = Get-Content $modelsPath -Raw | ConvertFrom-Json
    $ageH = ((Get-Date) - [datetime](Get-P $m 'updatedAt' ((Get-Date).ToString('o')))).TotalHours
    if ($ageH -gt [double]$config.staleHours) {
      # refresh gap guard so concurrent agents don't hammer metadata queries
      if ($ageH -lt 4.0) { Write-Diag ("list stale ({0:N1}h) but recently refreshed; skipping refresh" -f $ageH) }
      else { $needRefresh = $true }
    }
  } catch { $needRefresh = $true }
}
if ($needRefresh -and -not $SkipRefresh) {
  Write-Diag "model list missing/stale -> running refresh.ps1 (~2-3 seconds)"
  & (Join-Path $PSScriptRoot 'refresh.ps1')
}

if (-not (Test-Path -LiteralPath $rankingsPath)) { Write-Error 'rankings.json still missing after refresh'; exit 3 }

# --- build candidate chain ---------------------------------------------------------
$rankings = Get-Content $rankingsPath -Raw | ConvertFrom-Json
$state    = Get-Content $modelsPath -Raw | ConvertFrom-Json
$byId = @{}
foreach ($mm in $state.models) { $byId[$mm.id] = $mm }
$now = Get-Date

function Retryable([object]$rec) {
  if ($null -eq $rec) { return $true }               # never seen -> worth a try
  $status = Get-P $rec 'status'
  if ($status -eq 'ok') { return $true }
  $last = Get-P $rec 'lastChecked'
  if (-not $last) { return $true }
  $ageMin = ($now - [datetime]$last).TotalMinutes
  switch ($status) {
    'rate_limited'     { return $ageMin -gt [double]$config.retryAfter.rate_limited_minutes }
    'timeout'          { return $ageMin -gt [double]$config.retryAfter.timeout_minutes * 60 }
    'no_credits'       { return $ageMin -gt [double]$config.retryAfter.no_credits_hours * 60 }
    'context_overflow' { return $false }
    'auth_error'       { return $ageMin -gt [double]$config.retryAfter.no_credits_hours * 60 }
    default            { return $ageMin -gt [double]$config.retryAfter.dead_hours * 60 }  # dead
  }
}

$catName = $Category
if (-not ($rankings.categories.PSObject.Properties.Name -contains $catName)) { $catName = 'general' }

$chain = New-Object System.Collections.Generic.List[string]
foreach ($id in @(Get-P $rankings.categories $catName @())) {
  if ($chain -notcontains $id -and (Retryable $byId[$id])) { $chain.Add($id) }
}
if ($Model) { $chain.Insert(0, $Model) }             # explicit override always first

if ($chain.Count -eq 0) {
  Write-Host "[oc] NO eligible models for category '$Category'. Run scripts\refresh.ps1 -Force." -ForegroundColor Red
  exit 2
}
Write-Diag ("chain ({0}): {1}" -f $catName, (($chain | Select-Object -First ([int]$config.maxAttemptsPerRun)) -join ' -> '))

# --- run with fallback ---------------------------------------------------------------
$maxAttempts = [math]::Min([int]$chain.Count, [int]$config.maxAttemptsPerRun)
$attempt = 0
$usedModel = $null
$sid = if ($SessionId) { $SessionId } else { $null }

foreach ($candidate in ($chain | Select-Object -First $maxAttempts)) {
  $attempt++
  Write-Diag ("attempt {0}/{1} via {2}" -f $attempt, $maxAttempts, $candidate)

  $argList = New-Object System.Collections.Generic.List[string]
  $argList.Add('run') ; $argList.Add($Message)
  if ($sid)      { $argList.Add('-s') ; $argList.Add($sid) }
  elseif ($Continue) { $argList.Add('-c') }
  $argList.Add('-m') ; $argList.Add($candidate)
  if ($Agent)    { $argList.Add('--agent') ; $argList.Add($Agent) }
  if ($Json)     { $argList.Add('--format'); $argList.Add('json') }
  if (-not $NoAuto) { $argList.Add('--auto') }
  $argList.Add('--title'); $argList.Add('oc-skill')

  $outF = [System.IO.Path]::GetTempFileName(); $errF = [System.IO.Path]::GetTempFileName()
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $proc = Start-Oc $argList.ToArray() (Get-Location).Path $outF $errF
  $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
  if ($exited) { $proc.WaitForExit() | Out-Null }   # flush exit code (PS 5.1 quirk)

  if (-not $exited) {
    try { $proc.Kill(); $proc.WaitForExit(5000) | Out-Null } catch { }
    $status = 'timeout'; $errText = "killed after ${TimeoutSeconds}s"
  } else {
    $errText = (Get-Content $errF -Raw -ErrorAction SilentlyContinue); if (-not $errText) { $errText = '' }
    # NOTE: opencode.exe's WinExitCode is unreliable via Start-Process on PS 5.1
    # -> success is judged by response content, failures by stderr patterns.
    $raw = (Get-Content $outF -Raw -ErrorAction SilentlyContinue); if (-not $raw) { $raw = '' }
    if ($raw.Trim()) { $status = 'ok' }
    else {
      $t = ($errText + ' ').ToLowerInvariant()
      if     ($t -match 'rate.?limit|429|temporarily rate')              { $status = 'rate_limited' }
      elseif ($t -match 'insufficient balance|quota exceeded|billing')   { $status = 'no_credits' }
      elseif ($t -match 'context length|too large|too long')             { $status = 'context_overflow' }
      elseif ($t -match 'unauthorized|invalid api key|401')              { $status = 'auth_error' }
      else                                                               { $status = 'dead' }
    }
  }
  $outText = ''
  if ($status -eq 'ok') {
    $outText = (Get-Content $outF -Raw -ErrorAction SilentlyContinue); if (-not $outText) { $outText = '' }
  }
  Remove-Item -Force -ErrorAction SilentlyContinue $outF, $errF | Out-Null

  # record outcome
  $rec = $byId[$candidate]
  if ($null -eq $rec) {
    $rec = [pscustomobject]@{ id = $candidate; provider = ($candidate -split '/', 2)[0]; free = $true;
      source = 'runtime'; status = $status; lastChecked = (Get-Date).ToUniversalTime().ToString('o');
      latencyMs = $(if ($status -eq 'ok') { $sw.ElapsedMilliseconds } else { $null }); context = $null;
      reasoning = $null; successCount = 0; failCount = 0; latencySamplesMs = 0L; latencyRuns = 0; lastError = $null }
    $state.models = @($state.models) + $rec; $byId[$candidate] = $rec
  }
  $rec.status = $status
  $rec.lastChecked = (Get-Date).ToUniversalTime().ToString('o')
  if ($status -eq 'ok') {
    $rec.successCount = [int](Get-P $rec 'successCount' 0) + 1
    $rec.latencySamplesMs = [long](Get-P $rec 'latencySamplesMs' 0) + [long]$sw.ElapsedMilliseconds
    $rec.latencyRuns = [int](Get-P $rec 'latencyRuns' 0) + 1
    $rec.latencyMs = $sw.ElapsedMilliseconds
    $rec.lastError = $null
  } else {
    $rec.failCount = [int](Get-P $rec 'failCount' 0) + 1
    $first = (($errText -split "`n") | Select-Object -First 1); if (-not $first) { $first = "(no stderr)" }
    $first = $first.Trim(); $rec.lastError = $first.Substring(0, [Math]::Min(200, $first.Length))
  }
  Save-State $state

  if ($status -eq 'ok') {
    $usedModel = $candidate
    break
  }
  Write-Diag ("{0} failed ({1}); falling back" -f $candidate, $status)
}

if (-not $usedModel) {
  Write-Host "[oc] ALL candidate models exhausted (category '$Category', attempts=$maxAttempts)." -ForegroundColor Red
  Write-Host "[oc] Check balance: scripts\get-balance.ps1 -Force ; refresh: scripts\refresh.ps1 -Force" -ForegroundColor Red
  exit 2
}

# --- resolve session id (for future continuation) ---------------------------------------
if (-not $sid) {
  try {
    $listing = (& opencode session list 2>$null | Out-String)
    foreach ($line in ($listing -split "`n")) {
      if ($line -match '(ses_[A-Za-z0-9]+)') { $sid = $Matches[1]; break }   # newest first
    }
  } catch { $sid = $null }
}

# --- emit result -----------------------------------------------------------------------
Write-Output $outText.TrimEnd()
$meta = [pscustomobject]@{ session = $sid; model = $usedModel; attempts = $attempt; category = $catName }
Write-Output '---OC-META---'
Write-Output (($meta | ConvertTo-Json -Compress))
exit 0
