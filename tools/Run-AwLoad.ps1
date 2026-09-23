<#
.SYNOPSIS
  Runs aw2019-load.sql in several parallel sqlcmd sessions for heavier load.
  Uses Windows authentication (run as a login that can execute the procs).

.EXAMPLE
  .\Run-AwLoad.ps1 -Sessions 4
#>
param(
    [int]    $Sessions  = 4,
    [string] $Server    = "localhost",
    [string] $Database  = "AdventureWorks2019",
    [string] $Script    = (Join-Path $PSScriptRoot "aw2019-load.sql"),
    [string] $OutFolder = "C:\temp\aw-load"
)

$ErrorActionPreference = "Stop"

# ---- Pre-flight -------------------------------------------------------------
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "sqlcmd not found. Install the SQL Server command-line tools or run the script in SSMS."
}
if (-not (Test-Path $Script)) {
    throw "Load script not found: $Script  (put aw2019-load.sql next to this runner or pass -Script)"
}
$Script = (Resolve-Path $Script).Path
New-Item -ItemType Directory -Force -Path $OutFolder | Out-Null

Write-Host "sqlcmd: $((Get-Command sqlcmd).Source)"

# Test the connection; older sqlcmd builds don't support -C (trust server certificate)
$common = @("-S", $Server, "-E", "-d", $Database, "-b")
$test = & sqlcmd @common -C -Q "SET NOCOUNT ON; SELECT 'ok'" -h -1 2>&1
if ($LASTEXITCODE -ne 0 -or ($test -join "`n") -notmatch 'ok') {
    Write-Host "Connection with -C failed, retrying without it..." -ForegroundColor Yellow
    $test = & sqlcmd @common -Q "SET NOCOUNT ON; SELECT 'ok'" -h -1 2>&1
    if ($LASTEXITCODE -ne 0 -or ($test -join "`n") -notmatch 'ok') {
        Write-Host ($test -join "`n") -ForegroundColor Red
        throw "Cannot connect to $Server / $Database with Windows authentication."
    }
} else {
    $common += "-C"
}
Write-Host "Connection test passed." -ForegroundColor Green

# ---- Launch sessions ----------------------------------------------------------
$sessionsInfo = foreach ($i in 1..$Sessions) {
    $out = Join-Path $OutFolder "session-$i.txt"
    $err = Join-Path $OutFolder "session-$i.err.txt"
    Remove-Item $out, $err -ErrorAction SilentlyContinue

    $sqlArgs = $common + @("-i", "`"$Script`"", "-h", "-1", "-W")
    $p = Start-Process sqlcmd -ArgumentList $sqlArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
    Start-Sleep -Milliseconds 500   # stagger starts
    [pscustomobject]@{ Session = $i; Process = $p; Out = $out; Err = $err }
}

# Catch sessions that die immediately
Start-Sleep -Seconds 5
foreach ($s in $sessionsInfo) {
    if ($s.Process.HasExited) {
        Write-Host "Session $($s.Session) exited early (code $($s.Process.ExitCode)):" -ForegroundColor Red
        Get-Content $s.Err, $s.Out -ErrorAction SilentlyContinue | Select-Object -First 20
    }
}

$running = $sessionsInfo | Where-Object { -not $_.Process.HasExited }
if (-not $running) { throw "No sessions are running. See the errors above." }

Write-Host "$($running.Count) session(s) running (PIDs: $($running.Process.Id -join ', ')). Output in $OutFolder" -ForegroundColor Green
Write-Host "Waiting for them to finish (Ctrl+C stops waiting; sessions keep running)..."
$running.Process | Wait-Process

# ---- Summaries ----------------------------------------------------------------
foreach ($s in $sessionsInfo) {
    Write-Host "`n--- Session $($s.Session) summary ---" -ForegroundColor Cyan
    if (Test-Path $s.Out) { Get-Content $s.Out -Tail 12 }
    if ((Test-Path $s.Err) -and (Get-Item $s.Err).Length -gt 0) {
        Write-Host "stderr:" -ForegroundColor Yellow
        Get-Content $s.Err -Tail 10
    }
}
