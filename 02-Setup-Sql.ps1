#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Step 2 (run on the SQL Server VM as a sysadmin Windows login).
  Creates/updates the Collector's SQL login, grants least-privilege permissions,
  configures Query Store in each database, and (optionally) grants read access
  to SQL Agent job history in msdb. Safe to re-run.

.PARAMETER ResetPassword
  Also reset the password of an existing login.
#>
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot "deploy.config.psd1"),
    [switch] $ResetPassword
)

$ErrorActionPreference = "Stop"
$cfg = Import-PowerShellDataFile $ConfigPath
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

$cs = "Server=$($cfg.SqlServer),$($cfg.SqlPort);Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
$conn.add_InfoMessage({ param($s, $e) Write-Host "  $($e.Message)" })

function Exec([string] $sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 120; $cmd.CommandText = $sql
    [void]$cmd.ExecuteNonQuery()
}
function Scalar([string] $sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.ExecuteScalar()
}
function Q([string] $s) { $s.Replace("'", "''") }          # literal
function N([string] $s) { '[' + $s.Replace(']', ']]') + ']' } # identifier

$login = $cfg.SqlLogin
$major = [int](Scalar "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int)")
$modern = $major -ge 16   # SQL Server 2022+: narrower PERFORMANCE STATE permissions
"SQL Server major version: $major"

# ---------------------------------------------------------------------------
Step "Login $login"
$exists = [int](Scalar "SELECT COUNT(*) FROM sys.server_principals WHERE name = N'$(Q $login)'")
if (-not $exists -or $ResetPassword) {
    $sec = Read-Host "Password for SQL login $login" -AsSecureString
    $plainPwd = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if ($exists) { Exec "ALTER LOGIN $(N $login) WITH PASSWORD = N'$(Q $plainPwd)';"; "Password reset." }
    else         { Exec "CREATE LOGIN $(N $login) WITH PASSWORD = N'$(Q $plainPwd)', CHECK_POLICY = ON;"; "Login created." }
    $plainPwd = $null
} else { "Login exists (use -ResetPassword to change its password)." }

$serverPerm = if ($modern) { 'VIEW SERVER PERFORMANCE STATE' } else { 'VIEW SERVER STATE' }
Exec "GRANT $serverPerm TO $(N $login);"
"Granted $serverPerm (Agent service status)."

# ---------------------------------------------------------------------------
$dbPerm = if ($modern) { 'VIEW DATABASE PERFORMANCE STATE' } else { 'VIEW DATABASE STATE' }
foreach ($db in $cfg.Databases) {
    Step "Database $db"
    if (-not [int](Scalar "SELECT COUNT(*) FROM sys.databases WHERE name = N'$(Q $db)' AND state_desc = 'ONLINE'")) {
        Write-Warning "$db not found or not online; skipped."; continue
    }
    Exec @"
USE $(N $db);
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(Q $login)')
    CREATE USER $(N $login) FOR LOGIN $(N $login);
GRANT $dbPerm TO $(N $login);
GRANT VIEW DEFINITION TO $(N $login);   -- resolves procedure names in every schema
ALTER DATABASE CURRENT SET QUERY_STORE = ON
(
    OPERATION_MODE          = READ_WRITE,
    INTERVAL_LENGTH_MINUTES = $([int]$cfg.QueryStoreIntervalMinutes),
    QUERY_CAPTURE_MODE      = AUTO,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    WAIT_STATS_CAPTURE_MODE = ON
);
"@
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT actual_state_desc, interval_length_minutes, current_storage_size_mb, max_storage_size_mb FROM $(N $db).sys.database_query_store_options"
    $r = $cmd.ExecuteReader(); $t = New-Object System.Data.DataTable; $t.Load($r)
    $t | Format-Table -AutoSize | Out-String | Write-Host
}

# ---------------------------------------------------------------------------
if ($cfg.CollectAgentJobs) {
    Step "SQL Agent (msdb)"
    Exec @"
USE msdb;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(Q $login)')
    CREATE USER $(N $login) FOR LOGIN $(N $login);
GRANT SELECT ON dbo.sysjobs       TO $(N $login);
GRANT SELECT ON dbo.sysjobhistory TO $(N $login);
GRANT SELECT ON dbo.sysjobactivity TO $(N $login);
GRANT SELECT ON dbo.syssessions   TO $(N $login);
GRANT SELECT ON dbo.syscategories TO $(N $login);
"@
    "Granted read access to job metadata and history."

    $agent = Scalar "SELECT TOP (1) status_desc FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%'"
    "SQL Agent service: $agent"
    if ($agent -ne 'Running') { Write-Warning "SQL Agent is not running; job data will be empty until it is started." }

    # Default history retention (1000 rows / 100 per job) purges fast; the Collector
    # ships rows every minute, but a little headroom helps if the Collector is down.
    Write-Host "  Tip: raise Agent history retention if needed:" -ForegroundColor DarkGray
    Write-Host "  EXEC msdb.dbo.sp_set_sqlagent_properties @jobhistory_max_rows = 10000, @jobhistory_max_rows_per_job = 1000;" -ForegroundColor DarkGray
}

$conn.Close()
Write-Host "`nDone. Next: 03-Install-Collector.ps1" -ForegroundColor Green
