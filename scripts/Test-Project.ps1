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
        $GrafanaPath = Join-Path $ProjectRoot 'grafana/vm-disk-observability.dashboard.json'
        $BicepPath = Join-Path $ProjectRoot 'infra/main.bicep'
        $QueryRoot = Join-Path $ProjectRoot 'queries'
        $PowerShellRoot = Join-Path $ProjectRoot 'scripts'

        $Workbook = Get-Content -Path $WorkbookPath -Raw | ConvertFrom-Json -Depth 100
        $Grafana = Get-Content -Path $GrafanaPath -Raw | ConvertFrom-Json -Depth 100

        if ($Workbook.version -ne 'Notebook/1.0') {
            throw 'The Azure Workbook does not use Notebook/1.0 format.'
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

        $WorkbookMetricItems = @($Workbook.items | Where-Object { $_.type -eq 10 })
        $InvalidWorkbookMetricItems = @(
            $WorkbookMetricItems |
                Where-Object {
                    $_.content.version -ne 'MetricsItem/2.0' -or
                    $_.content.chartType -ne 2 -or
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

        $DeploymentSourcePaths = @(
            (Join-Path $ProjectRoot 'README.md')
            (Join-Path $ProjectRoot 'package.json')
            $BicepPath
        ) + @(Get-ChildItem -Path $PowerShellRoot -Filter '*.ps1' | Select-Object -ExpandProperty FullName)
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
        & $AzureCli bicep build --file $BicepPath --stdout | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Bicep template compilation failed.'
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

        Write-Output "Validation passed: 2 dashboard files, 1 Bicep template, $((Get-ChildItem -Path $PowerShellRoot -Filter '*.ps1').Count) PowerShell scripts, and $($QueryFiles.Count) KQL files."
    }
    catch {
        Write-Error -ErrorAction Continue "Project validation failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution