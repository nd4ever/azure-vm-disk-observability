#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Validates the VM Disk Observability project artifacts.
.DESCRIPTION
    Parses dashboard JSON, compiles Bicep without producing output files, and can
    execute all shared KQL files against a Log Analytics workspace.
.PARAMETER Live
    Prompts for a Log Analytics customer ID and executes every KQL query.
.PARAMETER WorkspaceId
    Optional Log Analytics customer ID used to execute the KQL queries.
.EXAMPLE
    ./scripts/Test-Project.ps1
.EXAMPLE
    ./scripts/Test-Project.ps1 -Live
.NOTES
    The KQL execution check requires an authenticated Azure CLI session.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Live,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId
)

$ErrorActionPreference = 'Stop'

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $ProjectRoot = Split-Path -Path $PSScriptRoot -Parent
        $WorkbookPath = Join-Path $ProjectRoot 'workbooks/vm-disk-observability.workbook.json'
        $FreeWorkbookPath = Join-Path $ProjectRoot 'workbooks/vm-disk-observability-vmonly.workbook.json'
        $GrafanaPath = Join-Path $ProjectRoot 'grafana/vm-disk-observability.dashboard.json'
        $MainBicepPath = Join-Path $ProjectRoot 'infra/main.bicep'
        $AlertBicepPath = Join-Path $ProjectRoot 'infra/alerts.bicep'
        $PolicyBicepPath = Join-Path $ProjectRoot 'infra/free-guest-metrics-policy.bicep'
        $DeploySolutionScriptPath = Join-Path $ProjectRoot 'scripts/Deploy-Solution.ps1'
        $GrafanaImportScriptPath = Join-Path $ProjectRoot 'scripts/Import-GrafanaDashboard.ps1'
        $PolicyScriptPath = Join-Path $ProjectRoot 'scripts/Deploy-FreeGuestMetricsPolicy.ps1'
        $BicepFiles = @(Get-ChildItem -Path (Join-Path $ProjectRoot 'infra') -Filter '*.bicep')
        $QueryRoot = Join-Path $ProjectRoot 'queries'
        $PowerShellRoot = Join-Path $ProjectRoot 'scripts'

        $Workbook = Get-Content -Path $WorkbookPath -Raw | ConvertFrom-Json -Depth 100
        $FreeWorkbookSource = Get-Content -Path $FreeWorkbookPath -Raw
        $FreeWorkbook = $FreeWorkbookSource | ConvertFrom-Json -Depth 100
        $Grafana = Get-Content -Path $GrafanaPath -Raw | ConvertFrom-Json -Depth 100

        if ($Workbook.version -ne 'Notebook/1.0') {
            throw 'The Azure Workbook does not use Notebook/1.0 format.'
        }
        if ($FreeWorkbook.version -ne 'Notebook/1.0') {
            throw 'The free Azure Workbook does not use Notebook/1.0 format.'
        }

        if ($Grafana.schemaVersion -lt 41) {
            throw 'The Grafana dashboard schema version is older than the lab instance.'
        }

        $MultiSelectParameters = @(
            $Workbook.items |
                Where-Object { $_.type -eq 9 } |
                ForEach-Object { $_.content.parameters } |
                Where-Object { $_.multiSelect }
        )
        $ScalarMultiSelectDefaults = @(
            $MultiSelectParameters |
                Where-Object { $_.PSObject.Properties.Name -contains 'value' -and $_.value -is [string] }
        )
        if ($ScalarMultiSelectDefaults.Count -gt 0) {
            throw "Workbook multi-select defaults must be arrays: $($ScalarMultiSelectDefaults.name -join ', ')."
        }

        $WorkbookTimeRange = @(
            $Workbook.items |
                Where-Object { $_.type -eq 9 } |
                ForEach-Object { $_.content.parameters } |
                Where-Object { $_.name -eq 'TimeRange' }
        )
        if ($WorkbookTimeRange.Count -ne 1 -or @($WorkbookTimeRange[0].typeSettings.selectableValues).Count -eq 0) {
            throw 'The Workbook TimeRange parameter must define selectableValues for metric item rendering.'
        }

        $InvalidWorkbookLogQueryParameters = @(
            $Workbook.items |
                Where-Object { $_.type -eq 9 } |
                ForEach-Object { $_.content.parameters } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.query) -and
                    $_.name -ne 'VirtualMachines' -and
                    $_.name -ne 'VmSkuSize' -and
                    ($_.queryType -ne 0 -or $_.resourceType -ne 'microsoft.operationalinsights/workspaces')
                }
        )
        if ($InvalidWorkbookLogQueryParameters.Count -gt 0) {
            throw "Workbook log query parameters must target Log Analytics explicitly: $($InvalidWorkbookLogQueryParameters.name -join ', ')."
        }

        $WorkbookVirtualMachines = @(
            $Workbook.items |
                Where-Object { $_.type -eq 9 } |
                ForEach-Object { $_.content.parameters } |
                Where-Object { $_.name -eq 'VirtualMachines' }
        )
        if (
            $WorkbookVirtualMachines.Count -ne 1 -or
            $WorkbookVirtualMachines[0].queryType -ne 1 -or
            $WorkbookVirtualMachines[0].resourceType -ne 'microsoft.resourcegraph/resources' -or
            $WorkbookVirtualMachines[0].crossComponentResources -notcontains 'value::all'
        ) {
            throw 'The Workbook VirtualMachines parameter must query Azure Resource Graph across all accessible subscriptions.'
        }

        $FreeWorkbookPrometheusWorkspace = @(
            $FreeWorkbook.items |
                Where-Object { $_.type -eq 9 } |
                ForEach-Object { $_.content.parameters } |
                Where-Object { $_.name -eq 'PrometheusWorkspace' }
        )
        if (
            $FreeWorkbookPrometheusWorkspace.Count -ne 1 -or
            $FreeWorkbookPrometheusWorkspace[0].type -ne 5 -or
            $FreeWorkbookPrometheusWorkspace[0].value -ne '__AZURE_MONITOR_WORKSPACE_RESOURCE_ID__' -or
            -not $FreeWorkbookPrometheusWorkspace[0].typeSettings.resourceTypeFilter.'microsoft.monitor/accounts'
        ) {
            throw 'The free Workbook must define one Azure Monitor workspace resource parameter.'
        }

        $FreeWorkbookPrometheusItems = @(
            $FreeWorkbook.items |
                Where-Object { $_.type -eq 3 -and $_.content.queryType -eq 16 }
        )
        if ($FreeWorkbookPrometheusItems.Count -ne 4) {
            throw 'The free Workbook must contain exactly four Prometheus guest disk items.'
        }
        foreach ($PrometheusItem in $FreeWorkbookPrometheusItems) {
            if (
                $PrometheusItem.content.version -ne 'KqlItem/1.0' -or
                $PrometheusItem.content.resourceType -ne 'microsoft.monitor/accounts' -or
                $PrometheusItem.content.crossComponentResources -notcontains '{PrometheusWorkspace}' -or
                $PrometheusItem.content.timeContextFromParameter -ne 'TimeRange'
            ) {
                throw "Prometheus item '$($PrometheusItem.name)' is not bound to the Azure Monitor workspace and TimeRange parameters."
            }

            $PrometheusQuery = $PrometheusItem.content.query | ConvertFrom-Json
            if (
                $PrometheusQuery.version -ne 'PrometheusQueryProvider/1.0' -or
                $PrometheusQuery.queryText -notmatch '\{VirtualMachines\}' -or
                $PrometheusQuery.queryText -notmatch 'microsoft\.resourceid'
            ) {
                throw "Prometheus item '$($PrometheusItem.name)' does not use the expected provider and selected-VM filter."
            }

            $ExpectedQueryType = if ($PrometheusItem.name -eq 'GuestFilesystemCapacity') { 'query' } else { 'query_range' }
            $ExpectedVisualization = if ($ExpectedQueryType -eq 'query') { 'table' } else { 'timechart' }
            if (
                $PrometheusQuery.type -ne $ExpectedQueryType -or
                $PrometheusItem.content.visualization -ne $ExpectedVisualization
            ) {
                throw "Prometheus item '$($PrometheusItem.name)' has an invalid query or visualization type."
            }
        }

        $GuestFilesystemCapacity = @(
            $FreeWorkbookPrometheusItems |
                Where-Object { $_.name -eq 'GuestFilesystemCapacity' }
        )
        if ($GuestFilesystemCapacity.Count -ne 1) {
            throw 'The free Workbook must contain one guest filesystem capacity table.'
        }
        $GuestDiskHeading = @(
            $FreeWorkbook.items |
                Where-Object { $_.name -eq 'GuestDiskHeading' }
        )
        if (
            $GuestDiskHeading.Count -ne 1 -or
            $GuestDiskHeading[0].content.json -notmatch 'default OpenTelemetry metrics; no additional collection charge' -or
            $GuestDiskHeading[0].content.json -notmatch 'logs-based VM Insights and Log Analytics'
        ) {
            throw 'The free Workbook must describe the default OpenTelemetry metric cost boundary precisely.'
        }
        $GuestFilesystemCapacityQuery = $GuestFilesystemCapacity[0].content.query | ConvertFrom-Json
        $GuestFilesystemValueLabel = @(
            $GuestFilesystemCapacity[0].content.gridSettings.labelSettings |
                Where-Object { $_.columnId -eq 'value' }
        )
        if (
            $GuestFilesystemCapacityQuery.queryText -notmatch '/ 1000000000' -or
            $GuestFilesystemCapacityQuery.queryText -notmatch 'round\(' -or
            $GuestFilesystemCapacityQuery.queryText -notmatch 'Size \(GB\)' -or
            $GuestFilesystemValueLabel.Count -ne 1 -or
            $GuestFilesystemValueLabel[0].label -ne 'Value (GB or %)'
        ) {
            throw 'The guest filesystem capacity table must round values and label decimal GB and percentage units.'
        }

        $GuestDiskPerformanceItems = @(
            $FreeWorkbookPrometheusItems |
                Where-Object { $_.name -ne 'GuestFilesystemCapacity' }
        )
        foreach ($GuestDiskPerformanceItem in $GuestDiskPerformanceItems) {
            $GuestDiskPerformanceQuery = $GuestDiskPerformanceItem.content.query | ConvertFrom-Json
            if (
                $GuestDiskPerformanceQuery.queryText -notmatch 'device!~' -or
                $GuestDiskPerformanceQuery.queryText -notmatch 'system\.filesystem\.usage' -or
                $GuestDiskPerformanceQuery.queryText -notmatch 'group_left'
            ) {
                throw "Prometheus item '$($GuestDiskPerformanceItem.name)' must exclude pseudo devices and retain only filesystem-backed disk series."
            }
        }
        foreach ($Placeholder in @('__NATIVE_VM_RESOURCE_ID__', '__AZURE_MONITOR_WORKSPACE_RESOURCE_ID__')) {
            if ($FreeWorkbookSource -notmatch [regex]::Escape($Placeholder)) {
                throw "The free Workbook is missing deployment placeholder '$Placeholder'."
            }
        }

        if (-not (Test-Path -LiteralPath $PolicyBicepPath -PathType Leaf)) {
            throw 'The free guest metrics policy Bicep template is missing.'
        }
        if (-not (Test-Path -LiteralPath $PolicyScriptPath -PathType Leaf)) {
            throw 'The free guest metrics policy deployment script is missing.'
        }
        $PolicyBicepSource = Get-Content -Path $PolicyBicepPath -Raw
        $PolicyScriptSource = Get-Content -Path $PolicyScriptPath -Raw
        $MainBicepSource = Get-Content -Path $MainBicepPath -Raw
        $DeploySolutionScriptSource = Get-Content -Path $DeploySolutionScriptPath -Raw
        $GrafanaImportScriptSource = Get-Content -Path $GrafanaImportScriptPath -Raw
        $ExpectedPolicyDefinitionIds = @(
            'ca817e41-e85a-4783-bc7f-dc532d36235e'
            'a4034bc6-ae50-406d-bf76-50f4ee5a7811'
            '244efd75-0d92-453c-b9a3-7d73ca36ed52'
            '58e891b9-ce13-4ac3-86e4-ac3e1f20cb07'
        )
        foreach ($PolicyDefinitionId in $ExpectedPolicyDefinitionIds) {
            if ($PolicyBicepSource -notmatch [regex]::Escape($PolicyDefinitionId)) {
                throw "The policy initiative is missing built-in policy '$PolicyDefinitionId'."
            }
        }
        if (
            $PolicyBicepSource -notmatch "targetScope\s*=\s*'managementGroup'" -or
            $PolicyBicepSource -notmatch "kind:\s*'resourceLocation'" -or
            $PolicyScriptSource -notmatch "Prompt 'Management group name'" -or
            $PolicyScriptSource -notmatch "Get-Date -AsUTC -Format 'yyyyMMddHHmmssfff'" -or
            $PolicyScriptSource -notmatch 'performanceCountersOTel' -or
            $PolicyScriptSource -notmatch 'dataFlows'
        ) {
            throw 'Free guest metrics policy must use management-group scope, a resource-location selector, validated OTel counters, unique remediations, and an interactive management-group prompt.'
        }
        if (
            $DeploySolutionScriptSource -notmatch '(?s)\$DeployFreeGuestMetrics\s*=\s*if\s*\(\$SelectedArtifacts\).+?else\s*\{\s*\$false\s*\}' -or
            $DeploySolutionScriptSource -notmatch 'monitoringAccounts' -or
            $DeploySolutionScriptSource -notmatch 'performanceCountersOTel' -or
            $DeploySolutionScriptSource -notmatch "ProviderNamespace 'Microsoft\.Monitor'" -or
            $DeploySolutionScriptSource -notmatch "ProviderNamespace 'Microsoft\.Insights'" -or
            $DeploySolutionScriptSource -notmatch "RoleName 'Monitoring Data Reader'" -or
            $DeploySolutionScriptSource -notmatch "RoleName 'Log Analytics Reader'" -or
            $DeploySolutionScriptSource -notmatch "'grafana', 'integration', 'monitor', 'add'" -or
            $DeploySolutionScriptSource -notmatch 'Assert-FreeGuestMetricsDcr' -or
            $DeploySolutionScriptSource -notmatch 'Microsoft-OtelPerfMetrics data flow'
        ) {
            throw 'The unified deployment must keep policy opt-in and create, connect, authorize, and validate regional guest metric prerequisites.'
        }
        if (
            $GrafanaImportScriptSource -notmatch "type -eq 'prometheus'" -or
            $GrafanaImportScriptSource -notmatch '\$AzureMonitorWorkspaceParts\.Name' -or
            $GrafanaImportScriptSource -notmatch 'did not expose a Prometheus datasource' -or
            $GrafanaImportScriptSource -match 'dashboard will import'
        ) {
            throw 'The Grafana import must require the Prometheus datasource for the selected Azure Monitor workspace.'
        }
        if (
            $MainBicepSource -notmatch "Microsoft\.Monitor/accounts@2023-04-03" -or
            $MainBicepSource -notmatch "Microsoft\.Insights/dataCollectionRules@2024-03-11" -or
            $MainBicepSource -notmatch 'shouldDeployAzureMonitorWorkspace' -or
            $MainBicepSource -notmatch 'shouldDeployFreeGuestMetricsDcr'
        ) {
            throw 'The main Bicep template must support conditional Azure Monitor workspace and OpenTelemetry DCR creation.'
        }

        $WorkbookMetricItems = @($Workbook.items | Where-Object { $_.type -eq 10 })
        $InvalidWorkbookMetricItems = @(
            $WorkbookMetricItems |
                Where-Object {
                    $_.content.version -ne 'MetricsItem/2.0' -or
                    ($_.content.chartType -ne 2 -and $_.content.chartType -ne -1) -or
                    $_.content.resourceParameter -ne 'VirtualMachines' -or
                    $_.content.resourceIds -notcontains '{VirtualMachines}' -or
                    $_.content.timeContext.durationMs -ne 0
                }
        )
        if ($InvalidWorkbookMetricItems.Count -gt 0) {
            throw "Workbook metric items must use MetricsItem/2.0 with an explicit VirtualMachines binding: $($InvalidWorkbookMetricItems.name -join ', ')."
        }

        $GrafanaTargets = @(
            $Grafana.panels |
                ForEach-Object { $_.targets } |
                Where-Object { $null -ne $_ }
        )
        $GrafanaLogAnalyticsTargets = @(
            $GrafanaTargets |
                Where-Object { $_.queryType -eq 'Azure Log Analytics' }
        )
        $InvalidGrafanaLogAnalyticsTargets = @(
            $GrafanaLogAnalyticsTargets |
                Where-Object {
                    [string]::IsNullOrWhiteSpace($_.azureLogAnalytics.resource) -or
                    [string]::IsNullOrWhiteSpace($_.subscription) -or
                    $_.azureLogAnalytics.PSObject.Properties.Name -contains 'resources'
                }
        )
        if ($InvalidGrafanaLogAnalyticsTargets.Count -gt 0) {
            throw 'Grafana Log Analytics targets must use singular resource and a target-level subscription.'
        }

        $GrafanaCustomAllVariables = @(
            $Grafana.templating.list |
                Where-Object {
                    $_.includeAll -and
                    $_.PSObject.Properties.Name -contains 'allValue' -and
                    -not [string]::IsNullOrWhiteSpace($_.allValue)
                }
        )
        if ($GrafanaCustomAllVariables.Count -gt 0) {
            throw "Grafana query variables must let formatters expand All values: $($GrafanaCustomAllVariables.name -join ', ')."
        }

        $GrafanaGuestFilesystemPanels = @(
            $Grafana.panels |
                Where-Object { $_.id -eq 37 }
        )
        if ($GrafanaGuestFilesystemPanels.Count -ne 1) {
            throw 'The Grafana dashboard must contain one guest filesystem panel with ID 37.'
        }
        $GrafanaGuestFilesystemExpression = [string]$GrafanaGuestFilesystemPanels[0].targets[0].expr
        $NormalizedDeviceLabelCount = (
            [regex]::Matches(
                $GrafanaGuestFilesystemExpression,
                [regex]::Escape('"device", "$1", "device", "^/dev/(.*)$"')
            )
        ).Count
        if ($NormalizedDeviceLabelCount -lt 2) {
            throw 'The Grafana guest filesystem panel must normalize Linux /dev device labels before joining disk and filesystem metrics.'
        }
        $CaseSensitiveNativeVmFilter = '"microsoft.resourceid"="/subscriptions/$subscription/resourcegroups/$resourceGroup/providers/microsoft.compute/virtualmachines/$nativeVm"'
        $CaseInsensitiveNativeVmFilter = '"microsoft.resourceid"=~"(?i)^/subscriptions/$subscription/resourcegroups/$resourceGroup/providers/microsoft.compute/virtualmachines/$nativeVm$"'
        if (
            $GrafanaGuestFilesystemExpression.Contains($CaseSensitiveNativeVmFilter) -or
            -not $GrafanaGuestFilesystemExpression.Contains($CaseInsensitiveNativeVmFilter)
        ) {
            throw 'The Grafana guest filesystem panel must match normalized Azure resource IDs with a case-insensitive anchored regex.'
        }
        if ($GrafanaGuestFilesystemPanels[0].description -notmatch 'no additional collection charge') {
            throw 'The Grafana guest filesystem panel must describe the default OpenTelemetry metric cost boundary precisely.'
        }

        $DeploymentSourcePaths = @(
            (Join-Path $ProjectRoot 'README.md')
            (Join-Path $ProjectRoot 'package.json')
        ) + @($BicepFiles.FullName) + @(Get-ChildItem -Path $PowerShellRoot -Filter '*.ps1' | Select-Object -ExpandProperty FullName)
        $ConcreteAzureResourceIdPattern = '(?i)/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        $EnvironmentSpecificSourcePaths = @(
            $DeploymentSourcePaths |
                Where-Object { (Get-Content -Path $_ -Raw) -match $ConcreteAzureResourceIdPattern }
        )
        if ($EnvironmentSpecificSourcePaths.Count -gt 0) {
            throw "Deployment source contains concrete Azure resource IDs: $($EnvironmentSpecificSourcePaths -join ', ')."
        }

        foreach ($PowerShellFile in Get-ChildItem -Path $PowerShellRoot -Filter '*.ps1') {
            $ParserErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $PowerShellFile.FullName,
                [ref]$null,
                [ref]$ParserErrors
            ) | Out-Null
            if ($ParserErrors.Count -gt 0) {
                throw "PowerShell parsing failed for '$($PowerShellFile.Name)': $($ParserErrors.Message -join '; ')."
            }
        }

        $AzureCli = (Get-Command az -ErrorAction Stop).Source
        foreach ($BicepFile in $BicepFiles) {
            & $AzureCli bicep build --file $BicepFile.FullName --stdout | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Bicep template compilation failed for '$($BicepFile.Name)'."
            }
        }

        $CompiledMainTemplate = & $AzureCli bicep build --file $MainBicepPath --stdout | ConvertFrom-Json -Depth 100
        if ($LASTEXITCODE -ne 0) {
            throw 'Main Bicep template compilation failed.'
        }
        $CompiledAzureMonitorWorkspace = $CompiledMainTemplate.resources.azureMonitorWorkspace
        $CompiledFreeGuestMetricsDcr = $CompiledMainTemplate.resources.freeGuestMetricsDcr
        if (
            $CompiledAzureMonitorWorkspace.type -ne 'Microsoft.Monitor/accounts' -or
            $CompiledAzureMonitorWorkspace.apiVersion -ne '2023-04-03' -or
            $CompiledFreeGuestMetricsDcr.type -ne 'Microsoft.Insights/dataCollectionRules' -or
            $CompiledFreeGuestMetricsDcr.apiVersion -ne '2024-03-11'
        ) {
            throw 'The main template must compile the supported Azure Monitor workspace and DCR resource types.'
        }
        $CompiledOtelDataSources = @(
            $CompiledFreeGuestMetricsDcr.properties.dataSources.performanceCountersOTel
        )
        $CompiledOtelCounters = @($CompiledOtelDataSources.counterSpecifiers)
        $ExpectedOtelDiskCounters = @(
            'system.filesystem.usage'
            'system.disk.io'
            'system.disk.operations'
            'system.disk.operation_time'
        )
        $MissingCompiledOtelDiskCounters = @(
            $ExpectedOtelDiskCounters |
                Where-Object { $CompiledOtelCounters -notcontains $_ }
        )
        if (
            $CompiledOtelDataSources.Count -ne 1 -or
            $CompiledOtelDataSources[0].samplingFrequencyInSeconds -ne 60 -or
            $CompiledOtelDataSources[0].streams -notcontains 'Microsoft-OtelPerfMetrics' -or
            $MissingCompiledOtelDiskCounters.Count -gt 0 -or
            @($CompiledFreeGuestMetricsDcr.properties.destinations.monitoringAccounts).Count -ne 1 -or
            @(
                $CompiledFreeGuestMetricsDcr.properties.dataFlows |
                    Where-Object {
                        $_.streams -contains 'Microsoft-OtelPerfMetrics' -and
                        $_.destinations -contains 'monitoringAccountDestination'
                    }
            ).Count -ne 1
        ) {
            throw 'The generated DCR must send the required default OpenTelemetry disk counters to one Azure Monitor workspace every 60 seconds.'
        }

        $CompiledAlertTemplate = & $AzureCli bicep build --file $AlertBicepPath --stdout | ConvertFrom-Json -Depth 100
        if ($LASTEXITCODE -ne 0) {
            throw 'Alert Bicep template compilation failed.'
        }

        $ExpectedAlertMetrics = @(
            'Data Disk IOPS Consumed Percentage'
            'Data Disk Bandwidth Consumed Percentage'
            'VM Cached IOPS Consumed Percentage'
            'VM Uncached IOPS Consumed Percentage'
            'VM Cached Bandwidth Consumed Percentage'
            'VM Uncached Bandwidth Consumed Percentage'
        )
        $ActualAlertMetrics = @($CompiledAlertTemplate.variables.alertDefinitions.metricName)
        $AlertMetricDifference = @(Compare-Object -ReferenceObject $ExpectedAlertMetrics -DifferenceObject $ActualAlertMetrics)
        if ($ActualAlertMetrics.Count -ne 6 -or $AlertMetricDifference.Count -gt 0) {
            throw 'The alert template must contain exactly the six disk and VM SKU consumed-percentage metrics.'
        }
        if ($CompiledAlertTemplate.parameters.alertThreshold.defaultValue -ne 100) {
            throw 'The default disk and VM SKU alert threshold must be 100%.'
        }
        $CompiledMetricAlert = @(
            $CompiledAlertTemplate.resources |
                Where-Object type -EQ 'Microsoft.Insights/metricAlerts'
        )
        if ($CompiledMetricAlert.Count -ne 1) {
            throw 'The alert template must contain one looped metric-alert resource.'
        }
        if (
            $CompiledMetricAlert[0].properties.evaluationFrequency -ne 'PT15M' -or
            $CompiledMetricAlert[0].properties.windowSize -ne 'PT15M'
        ) {
            throw 'Metric alerts must evaluate every 15 minutes over a 15-minute window.'
        }

        $DataDiskAlertDefinitions = @(
            $CompiledAlertTemplate.variables.alertDefinitions |
                Where-Object metricName -Like 'Data Disk *'
        )
        $InvalidDataDiskDimensions = @(
            $DataDiskAlertDefinitions |
                Where-Object {
                    @($_.dimensions).Count -ne 1 -or
                    $_.dimensions[0].name -ne 'LUN' -or
                    $_.dimensions[0].operator -ne 'Include' -or
                    @($_.dimensions[0].values).Count -ne 1 -or
                    $_.dimensions[0].values[0] -ne '*'
                }
        )
        if ($DataDiskAlertDefinitions.Count -ne 2 -or $InvalidDataDiskDimensions.Count -gt 0) {
            throw 'Data-disk alerts must split alert time series by every LUN dimension value.'
        }

        $VmSkuAlertDefinitions = @(
            $CompiledAlertTemplate.variables.alertDefinitions |
                Where-Object metricName -Like 'VM *'
        )
        $InvalidVmSkuDimensions = @(
            $VmSkuAlertDefinitions |
                Where-Object { @($_.dimensions).Count -ne 0 }
        )
        if ($VmSkuAlertDefinitions.Count -ne 4 -or $InvalidVmSkuDimensions.Count -gt 0) {
            throw 'VM SKU alerts must remain VM-level alert time series without dimensions.'
        }

        $QueryFiles = @(Get-ChildItem -Path $QueryRoot -Filter '*.kql')
        if ($QueryFiles.Count -eq 0) {
            throw 'No KQL query files were found.'
        }

        if ($Live -and [string]::IsNullOrWhiteSpace($WorkspaceId)) {
            $WorkspaceId = Read-Host -Prompt 'Log Analytics workspace customer ID'
            if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
                throw 'A Log Analytics workspace customer ID is required for live validation.'
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
            foreach ($QueryFile in $QueryFiles) {
                $Query = (Get-Content -Path $QueryFile.FullName -Raw) -replace '\r?\n', ' '
                & $AzureCli monitor log-analytics query `
                    --workspace $WorkspaceId `
                    --analytics-query $Query `
                    --output none

                if ($LASTEXITCODE -ne 0) {
                    throw "KQL validation failed for '$($QueryFile.Name)'."
                }
            }
        }

        Write-Output "Validation passed: 3 dashboard files, $($BicepFiles.Count) Bicep templates, $((Get-ChildItem -Path $PowerShellRoot -Filter '*.ps1').Count) PowerShell scripts, and $($QueryFiles.Count) KQL files."
    }
    catch {
        Write-Error -ErrorAction Continue "Project validation failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution