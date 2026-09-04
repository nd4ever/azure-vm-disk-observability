#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys the VM Disk Observability Azure Monitor Workbook.
.DESCRIPTION
    Deploys the shared workbook to a resource group by using the checked-in Bicep
    template and resource IDs supplied at invocation time.
.PARAMETER TenantId
    Microsoft Entra tenant containing the deployment subscription.
.PARAMETER SubscriptionId
    Subscription that contains the target resource group.
.PARAMETER ResourceGroupName
    Resource group where the workbook resource is stored.
.PARAMETER LogAnalyticsWorkspaceResourceId
    Resource ID of the Log Analytics workspace containing VM Insights data.
.PARAMETER NativeVmResourceId
    Resource ID of the native Azure VM used for per-LUN platform metric charts.
.PARAMETER DeploymentName
    Resource group deployment name.
.EXAMPLE
    ./scripts/Deploy-Workbook.ps1 -TenantId <tenant> -SubscriptionId <subscription> -ResourceGroupName <group> -LogAnalyticsWorkspaceResourceId <id> -NativeVmResourceId <id>
.NOTES
    Run validation first with: npm run validate
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LogAnalyticsWorkspaceResourceId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NativeVmResourceId,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DeploymentName = 'vm-disk-observability'
)

$ErrorActionPreference = 'Stop'

#region Functions
function ConvertFrom-AzureResourceId {
    <#
    .SYNOPSIS
        Parses a resource-group-scoped Azure resource ID.
    .OUTPUTS
        [hashtable] Parsed subscription, provider, and resource type values.
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
        ProviderNamespace = $ResourceIdParts[5]
        ResourceType = $ResourceIdParts[6]
    }
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $AzureCli = (Get-Command az -ErrorAction Stop).Source
        $TemplateFile = Join-Path $PSScriptRoot '../infra/main.bicep'
        $Account = & $AzureCli account show --subscription $SubscriptionId --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to access subscription '$SubscriptionId'."
        }
        if ($Account.tenantId -ne $TenantId) {
            throw "Subscription '$SubscriptionId' belongs to tenant '$($Account.tenantId)', not '$TenantId'."
        }

        $WorkspaceParts = ConvertFrom-AzureResourceId -ResourceId $LogAnalyticsWorkspaceResourceId
        $NativeVmParts = ConvertFrom-AzureResourceId -ResourceId $NativeVmResourceId
        if ($WorkspaceParts.ProviderNamespace -ne 'Microsoft.OperationalInsights' -or $WorkspaceParts.ResourceType -ne 'workspaces') {
            throw 'LogAnalyticsWorkspaceResourceId does not identify a Log Analytics workspace.'
        }
        if ($NativeVmParts.ProviderNamespace -ne 'Microsoft.Compute' -or $NativeVmParts.ResourceType -ne 'virtualMachines') {
            throw 'NativeVmResourceId does not identify an Azure virtual machine.'
        }

        foreach ($ReferencedSubscriptionId in @($WorkspaceParts.SubscriptionId, $NativeVmParts.SubscriptionId) | Select-Object -Unique) {
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

        & $AzureCli resource show --ids $LogAnalyticsWorkspaceResourceId --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to resolve Log Analytics workspace '$LogAnalyticsWorkspaceResourceId'."
        }
        & $AzureCli resource show --ids $NativeVmResourceId --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to resolve native Azure VM '$NativeVmResourceId'."
        }

        & $AzureCli deployment group create `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroupName `
            --name $DeploymentName `
            --template-file $TemplateFile `
            --parameters `
                logAnalyticsWorkspaceResourceId=$LogAnalyticsWorkspaceResourceId `
                nativeVmResourceId=$NativeVmResourceId `
                shouldDeployGrafana=false `
            --output table

        if ($LASTEXITCODE -ne 0) {
            throw "Azure deployment failed with exit code $LASTEXITCODE."
        }
    }
    catch {
        Write-Error -ErrorAction Continue "Workbook deployment failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution