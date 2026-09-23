<#
.SYNOPSIS
  Step 1 (run on your workstation, PowerShell 7 + Azure CLI, logged in with `az login`).
  Registers the OTLP preview, finds the Application Insights OTLP DCR and its
  ApplicationId, makes sure AMA is current, associates the DCR with the VM, and
  writes azure-outputs.json for the VM-side scripts.

  Prerequisite (portal, one time): create the Application Insights resource named in
  deploy.config.psd1 with "Enable OTLP support" checked on the Basics tab.
#>
param([string] $ConfigPath = (Join-Path $PSScriptRoot "deploy.config.psd1"))

$ErrorActionPreference = "Stop"
$cfg = Import-PowerShellDataFile $ConfigPath
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function AzJson { $out = & az @args -o json; if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }; if ($out) { $out | ConvertFrom-Json } }

Step "Subscription"
az account set --subscription $cfg.SubscriptionId | Out-Null
(AzJson account show).name

# ---------------------------------------------------------------------------
Step "OTLP preview feature"
$state = (AzJson feature show --name OtlpApplicationInsights --namespace Microsoft.Insights).properties.state
if ($state -ne 'Registered') {
    az feature register --name OtlpApplicationInsights --namespace Microsoft.Insights | Out-Null
    $deadline = (Get-Date).AddMinutes(20)
    do {
        Start-Sleep 30
        $state = (AzJson feature show --name OtlpApplicationInsights --namespace Microsoft.Insights).properties.state
        Write-Host "  state: $state"
    } while ($state -ne 'Registered' -and (Get-Date) -lt $deadline)
    if ($state -ne 'Registered') { throw "Feature still '$state'. Re-run this script later." }
    az provider register -n Microsoft.Insights | Out-Null
    Write-Warning "Feature was just registered. If Application Insights was created before this, recreate it with 'Enable OTLP support' checked."
}
"OtlpApplicationInsights: $state"

# ---------------------------------------------------------------------------
Step "Application Insights '$($cfg.AppInsightsName)'"
$ai = AzJson resource list --name $cfg.AppInsightsName --resource-type "microsoft.insights/components"
if (-not $ai) {
    throw "Application Insights '$($cfg.AppInsightsName)' not found. Create it in the portal with 'Enable OTLP support' checked, then re-run."
}
$ai = $ai[0]
$conn = (AzJson resource show --ids $ai.id).properties.ConnectionString
$appId = (($conn -split ';') | Where-Object { $_ -like 'ApplicationId=*' }) -replace '^ApplicationId=', ''
if (-not $appId) { throw "No ApplicationId= in the connection string. Is this a workspace-based Application Insights resource?" }
"ApplicationId: $appId   (use this, NOT the InstrumentationKey)"

# ---------------------------------------------------------------------------
Step "OTLP data collection rule"
$dcrs = AzJson monitor data-collection rule list
$dcr = $dcrs | Where-Object { $_.resourceGroup -match [regex]::Escape($appId) -or $_.name -ieq "managed-$($cfg.AppInsightsName)-dcr" } | Select-Object -First 1
if (-not $dcr) {
    $dcrs | Select-Object name, resourceGroup | Format-Table | Out-String | Write-Host
    throw "Could not find the Application Insights OTLP DCR. Copy its ID from AppInsights > Overview > OTLP Connection Info."
}
$dcr = AzJson monitor data-collection rule show --ids $dcr.id
"DCR: $($dcr.name)  ($($dcr.resourceGroup))"

$law = $dcr.destinations.logAnalytics | Select-Object -First 1
$amw = $dcr.destinations.monitoringAccounts | Select-Object -First 1
"Logs    -> $($law.workspaceResourceId)"
"Metrics -> $($amw.accountResourceId)"
$flows = $dcr.dataFlows | ForEach-Object { ($_.streams -join ',') + ' -> ' + ($_.destinations -join ',') }
$flows | ForEach-Object { "  flow: $_" }
if (-not ($flows -match 'OTel-Logs')) { Write-Warning "No Microsoft-OTel-Logs flow in this DCR; logs will not be ingested." }

# ---------------------------------------------------------------------------
Step "Azure Monitor Agent on $($cfg.VmName)"
$vm = AzJson vm show -g $cfg.VmResourceGroup -n $cfg.VmName
$isWindows = $vm.storageProfile.osDisk.osType -eq 'Windows'
$extName = if ($isWindows) { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' }
$minVer  = if ($isWindows) { [version]'1.38.1' } else { [version]'1.37.0' }
$ext = $null
try { $ext = AzJson vm extension show -g $cfg.VmResourceGroup --vm-name $cfg.VmName -n $extName } catch { }
$cur = if ($ext) { [version]($ext.typeHandlerVersion + '.0.0' -replace '^(\d+\.\d+\.\d+).*', '$1') } else { $null }
if (-not $ext -or $cur -lt $minVer) {
    Write-Host "  Installing/upgrading $extName (current: $($ext.typeHandlerVersion))..."
    az vm extension set -g $cfg.VmResourceGroup --vm-name $cfg.VmName --name $extName `
        --publisher Microsoft.Azure.Monitor --enable-auto-upgrade true | Out-Null
} else { "  $extName $($ext.typeHandlerVersion) OK (auto-upgrade handles patch versions)" }
"  Exact version is checked on the VM by 04-Test-Pipeline.ps1 (needs >= $minVer)."

# ---------------------------------------------------------------------------
Step "DCR association"
$assoc = AzJson monitor data-collection rule association list --resource $vm.id
if ($assoc | Where-Object { $_.dataCollectionRuleId -ieq $dcr.id }) {
    "Already associated."
} else {
    $assocName = ("otlp-" + $cfg.AppInsightsName).ToLower()
    az monitor data-collection rule association create --name $assocName `
        --rule-id $dcr.id --resource $vm.id | Out-Null
    "Associated. AMA opens 127.0.0.1:4317 (metrics) and 127.0.0.1:4319 (logs) within ~15 minutes."
}
AzJson monitor data-collection rule association list --resource $vm.id |
    ForEach-Object { "  " + ($_.dataCollectionRuleId -split '/')[-1] }

# ---------------------------------------------------------------------------
Step "Writing azure-outputs.json"
$outputs = [ordered]@{
    ApplicationId            = $appId
    DcrId                    = $dcr.id
    LogAnalyticsWorkspaceId  = $law.workspaceId
    LogAnalyticsResourceId   = $law.workspaceResourceId
    AzureMonitorWorkspaceId  = $amw.accountResourceId
    VmResourceId             = $vm.id
    GeneratedUtc             = (Get-Date).ToUniversalTime().ToString('o')
}
$outPath = Join-Path $PSScriptRoot "azure-outputs.json"
$outputs | ConvertTo-Json | Set-Content $outPath -Encoding utf8
Get-Content $outPath

Write-Host "`nDone. Copy the whole folder (including azure-outputs.json) to the VM, e.g. C:\otel\, then run 02-Setup-Sql.ps1." -ForegroundColor Green
