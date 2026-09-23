#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Step 4 (run on the SQL Server VM). End-to-end health check of the VM side:
  service, config, Collector counters, AMA ports/version, Collector warnings,
  and what the Collector's SQL login can see. Prints no secrets.
  Output is also saved to C:\temp\otel-diag.txt.
#>
param([string] $ConfigPath = (Join-Path $PSScriptRoot "deploy.config.psd1"))

$ErrorActionPreference = "Continue"
$cfg = Import-PowerShellDataFile $ConfigPath
New-Item -ItemType Directory -Force -Path C:\temp | Out-Null
Start-Transcript -Path C:\temp\otel-diag.txt -Force | Out-Null
function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Cyan }
function Check($ok, $msg) { if ($ok) { Write-Host "[ OK ] $msg" -ForegroundColor Green } else { Write-Host "[FAIL] $msg" -ForegroundColor Red } }

$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\otelcol-contrib"
$cfgFile = Join-Path $cfg.InstallRoot "config.yaml"

# ---------------------------------------------------------------------------
Section "Collector service"
$svc = Get-Service otelcol-contrib -ErrorAction SilentlyContinue
Check ($svc.Status -eq 'Running') "Service running ($($svc.Status))"
$envNames = (Get-ItemProperty $svcKey -ErrorAction SilentlyContinue).Environment | ForEach-Object { ($_ -split '=')[0] }
Check (($envNames -contains 'MSSQL_PASSWORD') -and ($envNames -contains 'AI_APP_ID')) "Service env vars: $($envNames -join ', ')"
$appIdLine = (Get-ItemProperty $svcKey -ErrorAction SilentlyContinue).Environment | Where-Object { $_ -like 'AI_APP_ID=*' }
$outFile = Join-Path $PSScriptRoot "azure-outputs.json"
if ((Test-Path $outFile) -and $appIdLine) {
    $expected = (Get-Content $outFile -Raw | ConvertFrom-Json).ApplicationId
    Check ($appIdLine -eq "AI_APP_ID=$expected") "AI_APP_ID matches azure-outputs.json ApplicationId"
}

# ---------------------------------------------------------------------------
Section "Pipelines in config.yaml"
if (Test-Path $cfgFile) {
    Select-String -Path $cfgFile -Pattern '^\s{4}(logs|metrics)/\S+:|^\s{6}receivers:' | ForEach-Object { $_.Line }
    Check (-not (Select-String -Path $cfgFile -Pattern 'endpoint: localhost:431[79]' -Quiet)) "Exporters use 127.0.0.1 (not localhost)"
} else { Check $false "config.yaml at $cfgFile" }

# ---------------------------------------------------------------------------
Section "Collector counters (localhost:8888)"
try {
    $m = (Invoke-WebRequest http://localhost:8888/metrics -UseBasicParsing -TimeoutSec 10).Content -split "`n"
    $m | Where-Object { $_ -match '^otelcol_(receiver_(accepted|refused|failed)|exporter_(sent|send_failed))_(metric_points|log_records)' } |
         ForEach-Object { $_.Trim() }
    $failed = $m | Where-Object { $_ -match '^otelcol_exporter_send_failed_\S+ ([0-9.e+]+)' -and [double]$Matches[1] -gt 0 }
    Check (-not $failed) "No export failures"
} catch { Check $false "Read internal metrics: $_" }

# ---------------------------------------------------------------------------
Section "Azure Monitor Agent"
foreach ($port in 4317, 4319) {
    $l = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    $pr = if ($l) { Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue }
    Check ($l -and $pr.Path -like '*AzureMonitor*') "Port $port listening: $($l.LocalAddress) $($pr.ProcessName)"
}
$ver = Get-ChildItem "C:\Packages\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent" -Directory -ErrorAction SilentlyContinue |
       ForEach-Object { try { [version]$_.Name } catch { } } | Sort-Object -Descending | Select-Object -First 1
Check ($ver -ge [version]'1.38.1') "AMA version $ver (needs >= 1.38.1)"

# ---------------------------------------------------------------------------
Section "Collector warnings/errors (Application log, last 2 hours)"
$events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'otelcol-contrib'; StartTime = (Get-Date).AddHours(-2) } -ErrorAction SilentlyContinue
$bad = $events | ForEach-Object { ($_.Properties | ForEach-Object Value) -join ' ' } | Where-Object { $_ -match '\s(warn|error)\s' }
Check (-not $bad) "$(@($bad).Count) warning/error entries"
$bad | Select-Object -First 8 | ForEach-Object { "  " + ($_.Substring(0, [Math]::Min(300, $_.Length))) }

# ---------------------------------------------------------------------------
Section "Tracking state"
Get-ChildItem $cfg.StorageDir -ErrorAction SilentlyContinue | Format-Table Name, Length, LastWriteTime -AutoSize

# ---------------------------------------------------------------------------
Section "What $($cfg.SqlLogin) can see"
$sec = Read-Host "Password for SQL login $($cfg.SqlLogin) (used only for this check)" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
function SqlTable($db, $sql) {
    $cs = "Server=$($cfg.SqlServer),$($cfg.SqlPort);Database=$db;User ID=$($cfg.SqlLogin);Password=$plain;Encrypt=True;TrustServerCertificate=True;Connect Timeout=10"
    $c = New-Object System.Data.SqlClient.SqlConnection $cs
    try { $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $sql
          $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); $t }
    catch { Write-Host "  [$db] $($_.Exception.Message)" -ForegroundColor Red }
    finally { $c.Close() }
}
foreach ($db in $cfg.Databases) {
    SqlTable $db @"
SELECT DB_NAME() AS db,
       o.actual_state_desc AS qs_state, o.interval_length_minutes AS interval_min,
       (SELECT COUNT(*) FROM sys.query_store_runtime_stats_interval WHERE end_time < SYSDATETIMEOFFSET()) AS closed_intervals,
       (SELECT MAX(end_time) FROM sys.query_store_runtime_stats_interval WHERE end_time < SYSDATETIMEOFFSET()) AS last_closed_end,
       (SELECT COUNT(DISTINCT q.object_id) FROM sys.query_store_query q WHERE q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NOT NULL) AS procs_named,
       (SELECT COUNT(DISTINCT q.object_id) FROM sys.query_store_query q WHERE q.object_id <> 0 AND OBJECT_NAME(q.object_id) IS NULL) AS procs_unresolved
FROM sys.database_query_store_options o;
"@ | Format-List
}
if ($cfg.CollectAgentJobs) {
    SqlTable 'msdb' @"
SELECT (SELECT COUNT(*) FROM dbo.sysjobs) AS jobs,
       (SELECT COUNT(*) FROM dbo.sysjobs WHERE enabled = 1) AS enabled_jobs,
       (SELECT COUNT(*) FROM dbo.sysjobhistory) AS history_rows,
       (SELECT COUNT(*) FROM dbo.sysjobhistory WHERE step_id = 0 AND run_status = 0) AS failed_outcomes,
       (SELECT MAX(instance_id) FROM dbo.sysjobhistory) AS max_instance_id,
       (SELECT TOP (1) status_desc FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%') AS agent_service;
"@ | Format-List
}
$plain = $null

Stop-Transcript | Out-Null
Write-Host "`nSaved to C:\temp\otel-diag.txt" -ForegroundColor Green
