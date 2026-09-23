<#
.SYNOPSIS
  Step 5 (run on your workstation with the Azure CLI). Confirms data is arriving
  in the Log Analytics workspace and lists what to check in the Azure Monitor
  workspace (Prometheus metrics).
#>
param(
    [string] $OutputsPath = (Join-Path $PSScriptRoot "azure-outputs.json"),
    [string] $Since = "2h"
)
$ErrorActionPreference = "Stop"
$o = Get-Content $OutputsPath -Raw | ConvertFrom-Json
$ws = $o.LogAnalyticsWorkspaceId
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Kql([string] $q) { az monitor log-analytics query -w $ws -o table --analytics-query $q }

$attrs = 'extend a = column_ifexists("LogAttributes", column_ifexists("Attributes", dynamic({})))'

Step "Tables with new data (last $Since)"
Kql "union withsource = T * | where ingestion_time() > ago($Since) | summarize rows = count() by T | order by rows desc"

Step "OTelLogs by source"
Kql "OTelLogs | where TimeGenerated > ago($Since) | $attrs | summarize rows = count(), latest = max(TimeGenerated) by source = tostring(a.event_source), db = tostring(a.db_name)"

Step "Query Store: objects seen"
Kql "OTelLogs | where TimeGenerated > ago($Since) | $attrs | where isnotempty(tostring(a.db_name)) | summarize rows = count() by db = tostring(a.db_name), object_type = tostring(a.object_type) | order by db asc"

Step "SQL Agent: job outcomes"
Kql "OTelLogs | where TimeGenerated > ago($Since) | $attrs | where tostring(a.event_source) == 'mssql.agent' and toint(a.step_id) == 0 | summarize runs = count(), failed = countif(tostring(a.run_status) == 'Failed'), avg_s = avg(todouble(a.duration_s)) by job = tostring(a.job_name) | order by failed desc"

Step "Prometheus metrics (Azure Monitor workspace)"
"Workspace: $($o.AzureMonitorWorkspaceId)"
"Open it in the portal > Metrics (PromQL) and try:"
"  mssql_querystore_storage_used"
"  topk(10, sum by (db_name, object_name) (mssql_querystore_proc_duration))"
"  mssql_agent_job_failures_24h > 0"
"  mssql_agent_up"
"(Names may carry a unit suffix such as _milliseconds or _seconds; type 'mssql' to browse.)"
