#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Step 3 (run on the SQL Server VM). Installs otelcol-contrib, generates config.yaml
  for Query Store (+ SQL Agent) collection, test-runs it, and installs it as a
  Windows service that sends to the local Azure Monitor Agent.

  Logs are enabled automatically when AMA is listening on 127.0.0.1:4319.
  Re-run any time (e.g. after adding databases); tracking state is preserved.

.PARAMETER ApplicationId
  Overrides the value from azure-outputs.json.
#>
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot "deploy.config.psd1"),
    [string] $ApplicationId,
    [switch] $ForceLogs,        # enable the logs pipeline even if 4319 isn't listening yet
    [switch] $NoLogs            # metrics only
)

$ErrorActionPreference = "Stop"
$cfg = Import-PowerShellDataFile $ConfigPath
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

$ServiceName = "otelcol-contrib"
$Root    = $cfg.InstallRoot
$Storage = $cfg.StorageDir
$CfgFile     = Join-Path $Root "config.yaml"
$Key     = $cfg.ReceiverKey
$SvcKey  = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

# ---------------------------------------------------------------------------
Step "Inputs"
if (-not $ApplicationId) {
    $outFile = Join-Path $PSScriptRoot "azure-outputs.json"
    if (-not (Test-Path $outFile)) { throw "azure-outputs.json not found next to this script. Run 01-Setup-Azure.ps1 or pass -ApplicationId." }
    $ApplicationId = (Get-Content $outFile -Raw | ConvertFrom-Json).ApplicationId
}
if ($ApplicationId -notmatch '^[0-9a-fA-F-]{36}$') { throw "ApplicationId '$ApplicationId' is not a GUID." }
"ApplicationId : $ApplicationId"
"Databases     : $($cfg.Databases -join ', ')"
"SQL Agent     : $($cfg.CollectAgentJobs)"

function Listening($port) {
    [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
           Where-Object LocalAddress -eq '127.0.0.1')
}
$amaMetrics = Listening 4317
$amaLogs    = Listening 4319
"AMA 4317 (metrics): $amaMetrics"
"AMA 4319 (logs)   : $amaLogs"
if (-not $amaMetrics) { Write-Warning "AMA is not listening on 4317. Check the DCR association (01-Setup-Azure.ps1). Continuing anyway." }
$EnableLogs = -not $NoLogs -and ($amaLogs -or $ForceLogs)
if (-not $EnableLogs -and -not $NoLogs) { Write-Warning "4319 not listening yet: installing metrics only. Re-run this script once AMA opens 4319." }

# ---------------------------------------------------------------------------
Step "SQL password for '$($cfg.SqlLogin)'"
$encodedPwd = $null
$existingEnv = (Get-ItemProperty $SvcKey -ErrorAction SilentlyContinue).Environment
$existingPwd = $existingEnv | Where-Object { $_ -like 'MSSQL_PASSWORD=*' }
if ($existingPwd -and (Read-Host "Reuse the password already stored for the service? [Y/n]") -notmatch '^[nN]') {
    $encodedPwd = $existingPwd -replace '^MSSQL_PASSWORD=', ''
} else {
    $sec = Read-Host "Password" -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $encodedPwd = [System.Uri]::EscapeDataString($plain)   # safe inside the connection URL
    $plain = $null
}

# ---------------------------------------------------------------------------
Step "Removing previous service (tracking state is kept)"
if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep 3
}
New-Item -ItemType Directory -Force -Path $Root, $Storage | Out-Null

# ---------------------------------------------------------------------------
Step "otelcol-contrib v$($cfg.CollectorVersion)"
$exe = Get-ChildItem $Root -Recurse -Filter "otelcol-contrib.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
$installed = if ($exe) { (& $exe.FullName --version) -replace '.*version\s+', '' } else { $null }
if ($installed -ne $cfg.CollectorVersion) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $v = $cfg.CollectorVersion
    $tgz = Join-Path $env:TEMP "otelcol-contrib.tar.gz"
    Invoke-WebRequest "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$v/otelcol-contrib_${v}_windows_amd64.tar.gz" -OutFile $tgz -UseBasicParsing
    tar -xzf $tgz -C $Root
    $exe = Get-ChildItem $Root -Recurse -Filter "otelcol-contrib.exe" | Select-Object -First 1
}
$Exe = $exe.FullName
& $Exe --version

# ---------------------------------------------------------------------------
Step "Generating $CfgFile"

function DataSource([string] $db) {
    "sqlserver://$($cfg.SqlLogin):`${env:MSSQL_PASSWORD}@$($cfg.SqlServer):$($cfg.SqlPort)?database=$db&encrypt=true&TrustServerCertificate=true"
}
function Fill([string] $tpl, [string] $id, [string] $db) {
    $tpl.Replace('__KEY__', $Key).Replace('__ID__', $id).Replace('__DS__', (DataSource $db))
}

# ---- Query Store: logs (per query, plan, interval) ----
$qsLogs = @'
  __KEY__/qs_logs___ID__:
    driver: sqlserver
    datasource: "__DS__"
    collection_interval: 60s
    initial_delay: 10s
    timeout: 30s
    max_open_conn: 1
    storage: file_storage
    queries:
      - sql: |
          SELECT TOP (5000)
                 'mssql.querystore'                     AS event_source,
                 DB_NAME()                              AS db_name,
                 rs.runtime_stats_id, q.query_id, p.plan_id,
                 CASE WHEN q.object_id = 0 THEN '(ad hoc)'
                      ELSE COALESCE(QUOTENAME(OBJECT_SCHEMA_NAME(q.object_id)) + '.' +
                                    QUOTENAME(OBJECT_NAME(q.object_id)),
                                    '(dropped object ' + CAST(q.object_id AS varchar(20)) + ')')
                 END                                    AS object_name,
                 COALESCE(o.type_desc, 'AD_HOC')        AS object_type,
                 LEFT(qt.query_sql_text, 4000)          AS query_sql_text,
                 CONVERT(varchar(33), rsi.start_time, 127) AS interval_start,
                 CONVERT(varchar(33), rsi.end_time, 127)   AS interval_end,
                 rs.count_executions,
                 rs.avg_duration / 1000.0               AS avg_duration_ms,
                 rs.max_duration / 1000.0               AS max_duration_ms,
                 rs.avg_cpu_time / 1000.0               AS avg_cpu_ms,
                 rs.avg_logical_io_reads,
                 rs.avg_physical_io_reads,
                 rs.avg_rowcount,
                 rs.execution_type_desc
          FROM sys.query_store_runtime_stats rs
          JOIN sys.query_store_runtime_stats_interval rsi
               ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
          JOIN sys.query_store_plan p        ON rs.plan_id = p.plan_id
          JOIN sys.query_store_query q       ON p.query_id = q.query_id
          JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
          LEFT JOIN sys.objects o            ON o.object_id = q.object_id
          WHERE rsi.end_time < SYSDATETIMEOFFSET()
            AND rs.runtime_stats_id > @p1
          ORDER BY rs.runtime_stats_id ASC
        tracking_column: runtime_stats_id
        tracking_start_value: "0"
        logs:
          - body_column: query_sql_text
            attribute_columns: [event_source, db_name, query_id, plan_id, object_name, object_type,
                                interval_start, interval_end, count_executions,
                                avg_duration_ms, max_duration_ms, avg_cpu_ms,
                                avg_logical_io_reads, avg_physical_io_reads,
                                avg_rowcount, execution_type_desc]
'@

# ---- Query Store: metrics (last closed interval) ----
$qsMetrics = @'
  __KEY__/qs_metrics___ID__:
    driver: sqlserver
    datasource: "__DS__"
    collection_interval: 5m
    timeout: 30s
    max_open_conn: 1
    queries:
      - sql: |
          WITH last_iv AS (
            SELECT TOP (1) runtime_stats_interval_id
            FROM sys.query_store_runtime_stats_interval
            WHERE end_time < SYSDATETIMEOFFSET()
            ORDER BY end_time DESC)
          SELECT DB_NAME() AS db_name,
                 QUOTENAME(OBJECT_SCHEMA_NAME(q.object_id)) + '.' +
                 QUOTENAME(OBJECT_NAME(q.object_id))                 AS object_name,
                 SUM(rs.count_executions)                            AS statement_executions,
                 SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS total_duration_ms,
                 SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS total_cpu_ms,
                 SUM(rs.avg_logical_io_reads * rs.count_executions)  AS total_logical_reads
          FROM sys.query_store_runtime_stats rs
          JOIN last_iv ON rs.runtime_stats_interval_id = last_iv.runtime_stats_interval_id
          JOIN sys.query_store_plan p  ON rs.plan_id = p.plan_id
          JOIN sys.query_store_query q ON p.query_id = q.query_id
          JOIN sys.objects o ON o.object_id = q.object_id AND o.type = 'P'
          GROUP BY q.object_id
        metrics:
          - { metric_name: mssql.querystore.proc.statement_executions, value_column: statement_executions, attribute_columns: [db_name, object_name], data_type: gauge, unit: "{execution}" }
          - { metric_name: mssql.querystore.proc.duration,      value_column: total_duration_ms,   value_type: double, attribute_columns: [db_name, object_name], data_type: gauge, unit: ms }
          - { metric_name: mssql.querystore.proc.cpu_time,      value_column: total_cpu_ms,        value_type: double, attribute_columns: [db_name, object_name], data_type: gauge, unit: ms }
          - { metric_name: mssql.querystore.proc.logical_reads, value_column: total_logical_reads, value_type: double, attribute_columns: [db_name, object_name], data_type: gauge, unit: "{page}" }
      - sql: |
          WITH last_iv AS (
            SELECT TOP (1) runtime_stats_interval_id
            FROM sys.query_store_runtime_stats_interval
            WHERE end_time < SYSDATETIMEOFFSET()
            ORDER BY end_time DESC)
          SELECT DB_NAME() AS db_name, rs.execution_type_desc,
                 SUM(rs.count_executions) AS executions,
                 SUM(rs.avg_duration * rs.count_executions)
                   / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms
          FROM sys.query_store_runtime_stats rs
          JOIN last_iv ON rs.runtime_stats_interval_id = last_iv.runtime_stats_interval_id
          GROUP BY rs.execution_type_desc
        metrics:
          - { metric_name: mssql.querystore.executions,   value_column: executions,      attribute_columns: [db_name, execution_type_desc], data_type: gauge, unit: "{execution}" }
          - { metric_name: mssql.querystore.avg_duration, value_column: avg_duration_ms, value_type: double, attribute_columns: [db_name, execution_type_desc], data_type: gauge, unit: ms }
      - sql: |
          SELECT DB_NAME() AS db_name, actual_state_desc,
                 current_storage_size_mb, max_storage_size_mb
          FROM sys.database_query_store_options
        metrics:
          - { metric_name: mssql.querystore.storage.used,  value_column: current_storage_size_mb, attribute_columns: [db_name, actual_state_desc], data_type: gauge, unit: MiBy }
          - { metric_name: mssql.querystore.storage.limit, value_column: max_storage_size_mb,     attribute_columns: [db_name],                    data_type: gauge, unit: MiBy }
'@

# ---- SQL Agent: logs (one record per job outcome and per step) ----
$agentLogs = @'
  __KEY__/agent_logs:
    driver: sqlserver
    datasource: "__DS__"
    collection_interval: 60s
    initial_delay: 15s
    timeout: 30s
    max_open_conn: 1
    storage: file_storage
    queries:
      - sql: |
          SELECT TOP (5000)
                 'mssql.agent'                                   AS event_source,
                 h.instance_id,
                 j.name                                          AS job_name,
                 COALESCE(c.name, '')                            AS job_category,
                 h.step_id,
                 CASE WHEN h.step_id = 0 THEN '(job outcome)' ELSE h.step_name END AS step_name,
                 CASE h.run_status WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' WHEN 2 THEN 'Retry'
                                   WHEN 3 THEN 'Canceled' WHEN 4 THEN 'In Progress' ELSE 'Unknown' END AS run_status,
                 -- Agent stores local server time; convert to UTC
                 CONVERT(varchar(30),
                   DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()),
                     DATETIMEFROMPARTS(h.run_date / 10000, h.run_date / 100 % 100, h.run_date % 100,
                                       h.run_time / 10000, h.run_time / 100 % 100, h.run_time % 100, 0)), 126) + 'Z' AS run_start_utc,
                 (h.run_duration / 10000) * 3600 + (h.run_duration / 100 % 100) * 60 + (h.run_duration % 100) AS duration_s,
                 h.retries_attempted,
                 h.sql_message_id,
                 h.sql_severity,
                 LEFT(COALESCE(h.message, ''), 4000)             AS message
          FROM dbo.sysjobhistory h
          JOIN dbo.sysjobs j            ON j.job_id = h.job_id
          LEFT JOIN dbo.syscategories c ON c.category_id = j.category_id
          WHERE h.instance_id > @p1
          ORDER BY h.instance_id ASC
        tracking_column: instance_id
        tracking_start_value: "0"
        logs:
          - body_column: message
            attribute_columns: [event_source, instance_id, job_name, job_category, step_id, step_name,
                                run_status, run_start_utc, duration_s, retries_attempted,
                                sql_message_id, sql_severity]
'@

# ---- SQL Agent: metrics ----
$agentMetrics = @'
  __KEY__/agent_metrics:
    driver: sqlserver
    datasource: "__DS__"
    collection_interval: 60s
    timeout: 30s
    max_open_conn: 1
    queries:
      # Per job: last run and last-24h counts (jobs with history only)
      - sql: |
          WITH outcomes AS (
            SELECT h.job_id, h.instance_id, h.run_status,
                   DATETIMEFROMPARTS(h.run_date / 10000, h.run_date / 100 % 100, h.run_date % 100,
                                     h.run_time / 10000, h.run_time / 100 % 100, h.run_time % 100, 0) AS run_start,
                   (h.run_duration / 10000) * 3600 + (h.run_duration / 100 % 100) * 60 + (h.run_duration % 100) AS duration_s
            FROM dbo.sysjobhistory h
            WHERE h.step_id = 0)
          SELECT j.name AS job_name,
                 lr.duration_s                                       AS last_duration_s,
                 CASE WHEN lr.run_status = 0 THEN 1 ELSE 0 END      AS last_run_failed,
                 (SELECT COUNT(*) FROM outcomes o WHERE o.job_id = j.job_id
                    AND o.run_start >= DATEADD(hour, -24, GETDATE()))  AS runs_24h,
                 (SELECT COUNT(*) FROM outcomes o WHERE o.job_id = j.job_id AND o.run_status = 0
                    AND o.run_start >= DATEADD(hour, -24, GETDATE()))  AS failures_24h
          FROM dbo.sysjobs j
          CROSS APPLY (SELECT TOP (1) duration_s, run_status FROM outcomes o
                       WHERE o.job_id = j.job_id ORDER BY o.instance_id DESC) lr
        metrics:
          - { metric_name: mssql.agent.job.last_duration, value_column: last_duration_s, attribute_columns: [job_name], data_type: gauge, unit: s }
          - { metric_name: mssql.agent.job.last_run_failed, value_column: last_run_failed, attribute_columns: [job_name], data_type: gauge, unit: "1" }
          - { metric_name: mssql.agent.job.runs_24h,      value_column: runs_24h,      attribute_columns: [job_name], data_type: gauge, unit: "{run}" }
          - { metric_name: mssql.agent.job.failures_24h,  value_column: failures_24h,  attribute_columns: [job_name], data_type: gauge, unit: "{run}" }
      # Jobs running right now, and for how long
      - sql: |
          SELECT j.name AS job_name,
                 DATEDIFF(second, a.start_execution_date, GETDATE()) AS running_s
          FROM dbo.sysjobactivity a
          JOIN dbo.sysjobs j ON j.job_id = a.job_id
          WHERE a.session_id = (SELECT MAX(session_id) FROM dbo.syssessions)
            AND a.start_execution_date IS NOT NULL
            AND a.stop_execution_date IS NULL
        metrics:
          - { metric_name: mssql.agent.job.running_duration, value_column: running_s, attribute_columns: [job_name], data_type: gauge, unit: s }
      - sql: |
          SELECT
            (SELECT COUNT(*) FROM dbo.sysjobactivity a
              WHERE a.session_id = (SELECT MAX(session_id) FROM dbo.syssessions)
                AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL) AS running_jobs,
            (SELECT COUNT(*) FROM dbo.sysjobs WHERE enabled = 1)                          AS enabled_jobs,
            CASE WHEN EXISTS (SELECT 1 FROM sys.dm_server_services
                              WHERE servicename LIKE 'SQL Server Agent%' AND status_desc = 'Running')
                 THEN 1 ELSE 0 END                                                        AS agent_up
        metrics:
          - { metric_name: mssql.agent.jobs.running, value_column: running_jobs, data_type: gauge, unit: "{job}" }
          - { metric_name: mssql.agent.jobs.enabled, value_column: enabled_jobs, data_type: gauge, unit: "{job}" }
          - { metric_name: mssql.agent.up,           value_column: agent_up,     data_type: gauge, unit: "1" }
'@

$blocks = @(); $metricsRx = @(); $logsRx = @()
foreach ($db in $cfg.Databases) {
    $id = ($db -replace '[^A-Za-z0-9_]', '_').ToLower()
    $blocks += Fill $qsMetrics $id $db; $metricsRx += "$Key/qs_metrics_$id"
    if ($EnableLogs) { $blocks += Fill $qsLogs $id $db; $logsRx += "$Key/qs_logs_$id" }
}
if ($cfg.CollectAgentJobs) {
    $blocks += Fill $agentMetrics 'agent' 'msdb'; $metricsRx += "$Key/agent_metrics"
    if ($EnableLogs) { $blocks += Fill $agentLogs 'agent' 'msdb'; $logsRx += "$Key/agent_logs" }
}

$pipelines = @"
    metrics/sql:
      receivers: [$($metricsRx -join ', ')]
      processors: [memory_limiter, resource/mssql, batch]
      exporters: [otlp/ama_metrics]
"@
if ($EnableLogs) {
    $pipelines += @"

    logs/sql:
      receivers: [$($logsRx -join ', ')]
      processors: [memory_limiter, resource/mssql, batch]
      exporters: [otlp/ama_logs]
"@
}

$config = @'
extensions:
  file_storage:
    directory: __STORAGE__
  health_check:
    endpoint: localhost:13133

receivers:
__RECEIVERS__

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20
  resource/mssql:
    attributes:
      - { key: db.system.name,          value: microsoft.sql_server, action: upsert }
      - { key: microsoft.applicationId, value: "${env:AI_APP_ID}",   action: upsert }
  batch: {}

exporters:
  # AMA listens on IPv4 only; "localhost" would try [::1] first
  otlp/ama_metrics:
    endpoint: 127.0.0.1:4317
    tls: { insecure: true }
  otlp/ama_logs:
    endpoint: 127.0.0.1:4319
    tls: { insecure: true }

service:
  extensions: [file_storage, health_check]
  telemetry:
    logs:
      level: info
  pipelines:
__PIPELINES__
'@
$config = $config.Replace('__STORAGE__', $Storage).Replace('__RECEIVERS__', ($blocks -join "`n")).Replace('__PIPELINES__', $pipelines)
[System.IO.File]::WriteAllText($CfgFile, $config, (New-Object System.Text.UTF8Encoding($false)))
"Receivers: $(($metricsRx + $logsRx).Count)  (logs pipeline: $EnableLogs)"

# ---------------------------------------------------------------------------
$env:MSSQL_PASSWORD = $encodedPwd
$env:AI_APP_ID      = $ApplicationId

Step "Validating config"
& $Exe validate --config $CfgFile
if ($LASTEXITCODE -ne 0) { throw "Config validation failed." }

Step "Test run (20 seconds)"
$outLog = Join-Path $env:TEMP "otelcol-test-out.log"
$errLog = Join-Path $env:TEMP "otelcol-test-err.log"
$p = Start-Process $Exe -ArgumentList "--config `"$CfgFile`"" -NoNewWindow -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Start-Sleep 20
if ($p.HasExited) { Get-Content $errLog -Tail 40; throw "Collector exited during the test run." }
Stop-Process -Id $p.Id -Force
$errs = Select-String -Path $errLog -Pattern '\terror\t|"level":"error"'
if ($errs) { Write-Warning "Collector logged errors during the test run:"; $errs | Select-Object -Last 10 | ForEach-Object { $_.Line } }
else { Write-Host "Test run clean." -ForegroundColor Green }

# ---------------------------------------------------------------------------
Step "Installing service"
New-Service -Name $ServiceName -DisplayName "OpenTelemetry Collector (contrib)" `
    -BinaryPathName "`"$Exe`" --config `"$CfgFile`"" -StartupType Automatic `
    -Description "Ships SQL Server Query Store and Agent telemetry to Azure Monitor via AMA" | Out-Null
sc.exe config  $ServiceName start= delayed-auto | Out-Null
sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
New-ItemProperty -Path $SvcKey -Name Environment -PropertyType MultiString -Force `
    -Value @("MSSQL_PASSWORD=$encodedPwd", "AI_APP_ID=$ApplicationId") | Out-Null
Remove-Item Env:MSSQL_PASSWORD -ErrorAction SilentlyContinue; $encodedPwd = $null

Start-Service $ServiceName
Start-Sleep 10
Get-Service $ServiceName | Format-Table Status, Name -AutoSize
try { Invoke-RestMethod "http://localhost:13133/" | Format-List status, upSince } catch { Write-Warning "Health endpoint not reachable yet." }

Write-Host "Done. Next: 04-Test-Pipeline.ps1 (on the VM) and 05-Verify-Azure.ps1 (on your workstation)." -ForegroundColor Green
