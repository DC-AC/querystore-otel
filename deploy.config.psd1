# ---------------------------------------------------------------------------
# SQL Server -> OpenTelemetry -> Azure Monitor : deployment settings
# Edit this one file. Every script reads it.
# ---------------------------------------------------------------------------
@{
    # ---- Azure -------------------------------------------------------------
    SubscriptionId   = 'ee3cb3c0-3415-43ee-8e63-a0170716ee9e'
    VmResourceGroup  = 'demovms'
    VmName           = 'msvmi-eastus2-sql1'
    AppInsightsName  = 'AppInsights1'          # created in the portal with "Enable OTLP support"

    # ---- SQL Server --------------------------------------------------------
    SqlServer        = 'localhost'
    SqlPort          = 1433
    SqlLogin         = 'otel-collector'        # SQL login the Collector uses
    Databases        = @(
        'AdventureWorks2017'
        'AdventureWorks2019'
        'AdventureWorks2022'
        'AdventureWorks2025'
    )
    QueryStoreIntervalMinutes = 15             # allowed: 1, 5, 10, 15, 30, 60, 1440
    CollectAgentJobs = $true                   # SQL Agent job history, failures, running jobs

    # ---- Collector ---------------------------------------------------------
    CollectorVersion = '0.161.0'
    ReceiverKey      = 'sql_query'             # 'sqlquery' on older Collector builds
    InstallRoot      = 'C:\Program Files\otelcol-contrib'
    StorageDir       = 'C:\ProgramData\otelcol\storage'
}
