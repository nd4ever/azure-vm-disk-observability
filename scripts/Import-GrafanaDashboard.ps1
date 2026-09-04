#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Imports the VM Disk Observability dashboard into Azure Managed Grafana.
.DESCRIPTION
    Resolves resource properties and the Azure Monitor datasource UID, replaces
    deployment placeholders, and imports the dashboard by using the Azure Managed
    Grafana CLI extension.
.PARAMETER TenantId
    Microsoft Entra tenant containing all referenced subscriptions.
.PARAMETER GrafanaResourceId
    Resource ID of the Azure Managed Grafana instance.
.PARAMETER WorkspaceResourceId
    Resource ID of the Log Analytics workspace containing VM Insights metrics.
.PARAMETER NativeVmResourceId
    Resource ID of the native Azure VM used for LUN metric panels.
.PARAMETER DashboardFile
    Path to the Grafana dashboard template.
.EXAMPLE
    ./scripts/Import-GrafanaDashboard.ps1 -TenantId <tenant> -GrafanaResourceId <id> -WorkspaceResourceId <id> -NativeVmResourceId <id>
.NOTES
    Requires the Azure CLI amg extension and a Grafana role that can read datasources
    and create dashboards, such as Grafana Admin.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GrafanaResourceId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NativeVmResourceId,

    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$DashboardFile = (Join-Path $PSScriptRoot '../grafana/vm-disk-observability.dashboard.json')
)

$ErrorActionPreference = 'Stop'

#region Functions
function ConvertFrom-AzureResourceId {
    <#
    .SYNOPSIS
        Parses a resource-group-scoped Azure resource ID.
    .OUTPUTS
        [hashtable] Parsed subscription, resource group, provider, type, and name values.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceId
    )

    $ResourceIdParts = $ResourceId.Trim('/') -split '/'
    if (
        $ResourceIdParts.Count -lt 8 -or
        $ResourceIdParts[0] -ne 'subscriptions' -or
        $ResourceIdParts[2] -ne 'resourceGroups' -or
        $ResourceIdParts[4] -ne 'providers'
    ) {
        throw "Not a valid resource-group-scoped Azure resource ID: '$ResourceId'."
    }

    return @{
        SubscriptionId = $ResourceIdParts[1]
        ResourceGroupName = $ResourceIdParts[3]
        ProviderNamespace = $ResourceIdParts[5]
        ResourceType = $ResourceIdParts[6]
        Name = $ResourceIdParts[7]
    }
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $AzureCli = (Get-Command az -ErrorAction Stop).Source
        & $AzureCli extension show --name amg --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "The Azure CLI amg extension is required. Install it with 'az extension add --name amg'."
        }

        $GrafanaParts = ConvertFrom-AzureResourceId -ResourceId $GrafanaResourceId
        $WorkspaceParts = ConvertFrom-AzureResourceId -ResourceId $WorkspaceResourceId
        $NativeVmParts = ConvertFrom-AzureResourceId -ResourceId $NativeVmResourceId
        if ($GrafanaParts.ProviderNamespace -ne 'Microsoft.Dashboard' -or $GrafanaParts.ResourceType -ne 'grafana') {
            throw "GrafanaResourceId is not an Azure Managed Grafana resource ID: '$GrafanaResourceId'."
        }
        if ($WorkspaceParts.ProviderNamespace -ne 'Microsoft.OperationalInsights' -or $WorkspaceParts.ResourceType -ne 'workspaces') {
            throw "WorkspaceResourceId is not a Log Analytics workspace resource ID: '$WorkspaceResourceId'."
        }
        if ($NativeVmParts.ProviderNamespace -ne 'Microsoft.Compute' -or $NativeVmParts.ResourceType -ne 'virtualMachines') {
            throw "NativeVmResourceId is not an Azure VM resource ID: '$NativeVmResourceId'."
        }

        foreach ($ReferencedSubscriptionId in @(
                $GrafanaParts.SubscriptionId
                $WorkspaceParts.SubscriptionId
                $NativeVmParts.SubscriptionId
            ) | Select-Object -Unique) {
            $ReferencedAccount = & $AzureCli account show `
                --subscription $ReferencedSubscriptionId `
                --output json | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to access referenced subscription '$ReferencedSubscriptionId'."
            }
            if ($ReferencedAccount.tenantId -ne $TenantId) {
                throw "Referenced subscription '$ReferencedSubscriptionId' is not in tenant '$TenantId'."
            }
        }

        $GrafanaResource = & $AzureCli resource show `
            --ids $GrafanaResourceId `
            --api-version 2023-09-01 `
            --output json | ConvertFrom-Json

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to resolve Azure Managed Grafana resource '$GrafanaResourceId'."
        }

        & $AzureCli resource show --ids $WorkspaceResourceId --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to resolve Log Analytics workspace '$WorkspaceResourceId'."
        }

        $NativeVmResource = & $AzureCli resource show --ids $NativeVmResourceId --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to resolve native Azure VM '$NativeVmResourceId'."
        }

        $GrafanaEndpoint = $GrafanaResource.properties.endpoint.TrimEnd('/')
        $AzureMonitorDatasource = $null
        $ReadinessDeadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
        do {
            $DatasourceJson = & $AzureCli grafana data-source list `
                --subscription $GrafanaParts.SubscriptionId `
                --resource-group $GrafanaParts.ResourceGroupName `
                --name $GrafanaParts.Name `
                --output json 2>$null

            if ($LASTEXITCODE -eq 0) {
                $AzureMonitorDatasource = @($DatasourceJson | ConvertFrom-Json) |
                    Where-Object { $_.type -eq 'grafana-azure-monitor-datasource' } |
                    Sort-Object -Property isDefault -Descending |
                    Select-Object -First 1
                if ($null -ne $AzureMonitorDatasource) {
                    break
                }
            }

            if ([DateTimeOffset]::UtcNow -lt $ReadinessDeadline) {
                Start-Sleep -Seconds 10
            }
        } while ([DateTimeOffset]::UtcNow -lt $ReadinessDeadline)

        if ($null -eq $AzureMonitorDatasource) {
            throw 'Azure Managed Grafana did not expose an Azure Monitor datasource within 10 minutes. Verify Grafana access and datasource configuration.'
        }

        $DashboardJson = Get-Content -Path $DashboardFile -Raw
        $Replacements = [ordered]@{
            '__AZURE_MONITOR_DATASOURCE_UID__' = $AzureMonitorDatasource.uid
            '__WORKSPACE_RESOURCE_ID__' = $WorkspaceResourceId
            '__WORKSPACE_SUBSCRIPTION_ID__' = $WorkspaceParts.SubscriptionId
            '__AZURE_VM_SUBSCRIPTION_ID__' = $NativeVmParts.SubscriptionId
            '__AZURE_VM_RESOURCE_GROUP__' = $NativeVmParts.ResourceGroupName
            '__AZURE_VM_NAME__' = $NativeVmParts.Name
            '__AZURE_VM_REGION__' = $NativeVmResource.location
        }

        foreach ($Replacement in $Replacements.GetEnumerator()) {
            $DashboardJson = $DashboardJson.Replace($Replacement.Key, $Replacement.Value)
        }

        $DashboardJson | ConvertFrom-Json -Depth 100 | Out-Null
        $RenderedDashboardPath = Join-Path ([System.IO.Path]::GetTempPath()) "vm-disk-observability-$([guid]::NewGuid()).json"

        try {
            Set-Content -Path $RenderedDashboardPath -Value $DashboardJson -Encoding utf8NoBOM
            $ImportResult = & $AzureCli grafana dashboard import `
                --subscription $GrafanaParts.SubscriptionId `
                --resource-group $GrafanaParts.ResourceGroupName `
                --name $GrafanaParts.Name `
                --definition $RenderedDashboardPath `
                --overwrite true `
                --output json | ConvertFrom-Json

            if ($LASTEXITCODE -ne 0) {
                throw 'The Azure Managed Grafana dashboard import command failed.'
            }
        }
        finally {
            Remove-Item -Path $RenderedDashboardPath -Force -ErrorAction SilentlyContinue
        }

        Write-Output "Dashboard imported: $GrafanaEndpoint$($ImportResult.url)"
    }
    catch {
        Write-Error -ErrorAction Continue "Grafana dashboard import failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution