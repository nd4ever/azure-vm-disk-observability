#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys the VM Disk Observability workbook and Grafana dashboard.
.DESCRIPTION
    Prompts for environment-specific Azure values when they are not supplied,
    discovers an existing Azure Managed Grafana instance or creates one, grants
    its managed identity access to monitored resources, and imports the dashboard.
.PARAMETER TenantId
    Microsoft Entra tenant containing all referenced subscriptions.
.PARAMETER SubscriptionId
    Subscription used for the resource group deployment.
.PARAMETER ResourceGroupName
    Resource group used for the workbook and any new Managed Grafana instance.
.PARAMETER Location
    Azure region used when the target resource group must be created.
.PARAMETER LogAnalyticsWorkspaceResourceId
    Resource ID of the Log Analytics workspace containing VM Insights data.
.PARAMETER AzureMonitorWorkspaceResourceId
    Optional resource ID of an existing Azure Monitor workspace containing default
    OpenTelemetry guest metrics. The deployment creates one when this is omitted.
.PARAMETER AzureMonitorWorkspaceName
    Name of the Azure Monitor workspace to create when a resource ID is not supplied.
.PARAMETER FreeGuestMetricsDcrResourceId
    Optional resource ID of an existing regional data collection rule for default
    OpenTelemetry guest metrics. The deployment creates one when this is omitted.
.PARAMETER FreeGuestMetricsDcrName
    Name of the guest metrics data collection rule to create.
.PARAMETER GuestMetricsLocation
    Region for the Azure Monitor workspace and guest metrics data collection rule.
    Defaults to the selected native VM region.
.PARAMETER ManagementGroupName
    Management group where the free guest metrics initiative is defined and assigned.
.PARAMETER FreeGuestMetricsAssignmentName
    Optional management-group policy assignment name. Use a distinct value for each region.
.PARAMETER FreeGuestMetricsAssignmentDisplayName
    Optional display name for the regional management-group policy assignment.
.PARAMETER NativeVmResourceId
    Resource ID of the native Azure VM used for per-LUN platform metric charts.
.PARAMETER AlertEmailAddress
    Email address that receives disk and VM SKU saturation alerts.
.PARAMETER GrafanaResourceId
    Resource ID of an existing Azure Managed Grafana instance.
.PARAMETER GrafanaName
    Name used to select an existing Managed Grafana instance or create a new one.
.PARAMETER WorkbookDisplayName
    Display name of the Azure Monitor Workbook.
.PARAMETER GrafanaAdminPrincipalId
    Object ID that receives Grafana Admin. When omitted for a new instance, the
    deploying principal receives Grafana Admin.
.PARAMETER GrafanaAdminPrincipalType
    Principal type of GrafanaAdminPrincipalId.
.PARAMETER SkipRoleAssignments
    Skips Grafana Admin and Monitoring Reader role assignments.
.PARAMETER SkipGrafanaImport
    Deploys Azure resources without importing the Grafana dashboard.
.PARAMETER Grafana
    Deploys and imports the Grafana dashboard. Acts as an artifact selector.
.PARAMETER VMInsights
    Deploys the VM Insights Azure Monitor Workbook. Acts as an artifact selector.
.PARAMETER Free
    Deploys the free, Azure VM-only Azure Monitor Workbook. Acts as an artifact selector.
.PARAMETER Alerts
    Deploys the email Action Group and disk/VM SKU metric alerts. Acts as an artifact selector.
.PARAMETER FreeGuestMetrics
    Deploys the management-group policy and remediates supported VMs. Acts as an artifact selector.
.PARAMETER SkipPolicyRemediation
    Deploys the free guest metrics policy without starting remediation tasks.

    When no artifact selectors are supplied, the Grafana dashboard, both workbooks,
    and alerts are deployed. Management-group policy deployment is always opt-in
    through -FreeGuestMetrics. Supply any combination to deploy only those artifacts.
    -Free alone does not require a Log Analytics workspace.
.EXAMPLE
    ./scripts/Deploy-Solution.ps1 -Free
.EXAMPLE
    ./scripts/Deploy-Solution.ps1 -Grafana -VMInsights
.EXAMPLE
    ./scripts/Deploy-Solution.ps1
.EXAMPLE
    ./scripts/Deploy-Solution.ps1 -TenantId <tenant> -SubscriptionId <subscription> -ResourceGroupName <group> -Location <region> -LogAnalyticsWorkspaceResourceId <id> -NativeVmResourceId <id>
.NOTES
    Runs via: npm run deploy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceResourceId,

    [Parameter(Mandatory = $false)]
    [string]$AzureMonitorWorkspaceResourceId,

    [Parameter(Mandatory = $false)]
    [string]$AzureMonitorWorkspaceName,

    [Parameter(Mandatory = $false)]
    [string]$FreeGuestMetricsDcrResourceId,

    [Parameter(Mandatory = $false)]
    [string]$FreeGuestMetricsDcrName,

    [Parameter(Mandatory = $false)]
    [string]$GuestMetricsLocation,

    [Parameter(Mandatory = $false)]
    [string]$ManagementGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateLength(1, 24)]
    [string]$FreeGuestMetricsAssignmentName,

    [Parameter(Mandatory = $false)]
    [ValidateLength(1, 128)]
    [string]$FreeGuestMetricsAssignmentDisplayName,

    [Parameter(Mandatory = $false)]
    [string]$NativeVmResourceId,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$AlertEmailAddress,

    [Parameter(Mandatory = $false)]
    [string]$GrafanaResourceId,

    [Parameter(Mandatory = $false)]
    [string]$GrafanaName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkbookDisplayName = 'VM Disk Observability',

    [Parameter(Mandatory = $false)]
    [string]$GrafanaAdminPrincipalId,

    [Parameter(Mandatory = $false)]
    [ValidateSet('User', 'ServicePrincipal')]
    [string]$GrafanaAdminPrincipalType,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRoleAssignments,

    [Parameter(Mandatory = $false)]
    [switch]$SkipGrafanaImport,

    [Parameter(Mandatory = $false)]
    [switch]$Grafana,

    [Parameter(Mandatory = $false)]
    [switch]$VMInsights,

    [Parameter(Mandatory = $false)]
    [switch]$Free,

    [Parameter(Mandatory = $false)]
    [switch]$Alerts,

    [Parameter(Mandatory = $false)]
    [switch]$FreeGuestMetrics,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPolicyRemediation
)

$ErrorActionPreference = 'Stop'

#region Functions
function Read-DeploymentValue {
    <#
    .SYNOPSIS
        Returns a supplied value or prompts for one.
    .OUTPUTS
        [string] The supplied or entered value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$DefaultValue
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $PromptText = $Prompt
    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        $PromptText = "$Prompt [$DefaultValue]"
    }

    $EnteredValue = Read-Host -Prompt $PromptText
    if ([string]::IsNullOrWhiteSpace($EnteredValue)) {
        $EnteredValue = $DefaultValue
    }
    if ([string]::IsNullOrWhiteSpace($EnteredValue)) {
        throw "$Prompt is required."
    }

    return $EnteredValue
}

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

function ConvertTo-NormalizedLocation {
    <#
    .SYNOPSIS
        Normalizes an Azure region for comparison.
    .OUTPUTS
        [string] The lower-case Azure region without spaces.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    return ($Value -replace '\s', '').ToLowerInvariant()
}

function Invoke-AzureCliJson {
    <#
    .SYNOPSIS
        Invokes Azure CLI and parses its JSON response.
    .OUTPUTS
        [object] Parsed Azure CLI response.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FailureMessage
    )

    $CommandOutput = & $script:AzureCli @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
    if ([string]::IsNullOrWhiteSpace(($CommandOutput -join ''))) {
        return $null
    }

    return $CommandOutput | ConvertFrom-Json
}

function Ensure-AzureProvider {
    <#
    .SYNOPSIS
        Ensures that an Azure resource provider is registered.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProviderNamespace
    )

    $RegistrationState = (& $script:AzureCli provider show `
            --subscription $SubscriptionId `
            --namespace $ProviderNamespace `
            --query registrationState `
            --output tsv 2>$null).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect $ProviderNamespace provider registration in '$SubscriptionId'."
    }
    if ($RegistrationState -eq 'Registered') {
        return
    }

    & $script:AzureCli provider register `
        --subscription $SubscriptionId `
        --namespace $ProviderNamespace `
        --wait `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to register the $ProviderNamespace resource provider in '$SubscriptionId'."
    }
}

function Ensure-AzureCliExtension {
    <#
    .SYNOPSIS
        Ensures that an Azure CLI extension is installed.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    & $script:AzureCli extension show --name $Name --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    & $script:AzureCli extension add --name $Name --yes --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to install the Azure CLI '$Name' extension."
    }
}

function Assert-FreeGuestMetricsDcr {
    <#
    .SYNOPSIS
        Validates the regional OpenTelemetry guest metrics data collection rule.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Dcr,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AzureMonitorWorkspaceResourceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GuestMetricsLocation
    )

    if ([string]$Dcr.type -ine 'Microsoft.Insights/dataCollectionRules') {
        throw "Resolved resource type '$($Dcr.type)' is not Microsoft.Insights/dataCollectionRules."
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Dcr.kind)) {
        throw "The free guest metrics DCR must support both Windows and Linux, but its kind is '$($Dcr.kind)'."
    }
    if (
        (ConvertTo-NormalizedLocation -Value ([string]$Dcr.location)) -ne
        (ConvertTo-NormalizedLocation -Value $GuestMetricsLocation)
    ) {
        throw "The free guest metrics DCR location '$($Dcr.location)' does not match '$GuestMetricsLocation'."
    }
    if (
        -not [string]::IsNullOrWhiteSpace([string]$Dcr.properties.provisioningState) -and
        [string]$Dcr.properties.provisioningState -ine 'Succeeded'
    ) {
        throw "The free guest metrics DCR provisioning state is '$($Dcr.properties.provisioningState)'."
    }

    $ExpectedGuestMetricCounters = @(
        'system.filesystem.usage'
        'system.disk.io'
        'system.disk.operations'
        'system.disk.operation_time'
    )
    $ConfiguredGuestMetricCounters = @(
        $Dcr.properties.dataSources.performanceCountersOTel |
            ForEach-Object { $_.counterSpecifiers } |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $MissingGuestMetricCounters = @(
        $ExpectedGuestMetricCounters |
            Where-Object { $ConfiguredGuestMetricCounters -inotcontains $_ }
    )
    if ($MissingGuestMetricCounters.Count -gt 0) {
        throw "The free guest metrics DCR is missing required OpenTelemetry counters: $($MissingGuestMetricCounters -join ', ')."
    }

    $NormalizedAzureMonitorWorkspaceResourceId = $AzureMonitorWorkspaceResourceId.TrimEnd('/')
    $MatchingMonitoringAccountDestinations = @(
        $Dcr.properties.destinations.monitoringAccounts |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.accountResourceId) -and
                [string]$_.accountResourceId.TrimEnd('/') -ieq $NormalizedAzureMonitorWorkspaceResourceId
            }
    )
    if ($MatchingMonitoringAccountDestinations.Count -ne 1) {
        throw "The free guest metrics DCR does not send metrics to Azure Monitor workspace '$AzureMonitorWorkspaceResourceId'."
    }
    $MonitoringAccountDestinationName = [string]$MatchingMonitoringAccountDestinations[0].name
    $ValidOtelDataFlows = @(
        $Dcr.properties.dataFlows |
            Where-Object {
                $_.streams -contains 'Microsoft-OtelPerfMetrics' -and
                $_.destinations -contains $MonitoringAccountDestinationName
            }
    )
    if ($ValidOtelDataFlows.Count -eq 0) {
        throw "The free guest metrics DCR has no Microsoft-OtelPerfMetrics data flow to '$MonitoringAccountDestinationName'."
    }
}

function Grant-AzureRole {
    <#
    .SYNOPSIS
        Ensures that a principal has an Azure role at a scope.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PrincipalType,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RoleName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Scope
    )

    $ScopeParts = ConvertFrom-AzureResourceId -ResourceId $Scope
    $Assignments = @(
        & $script:AzureCli role assignment list `
            --subscription $ScopeParts.SubscriptionId `
            --scope $Scope `
            --include-inherited `
            --query "[?principalId=='$PrincipalId' && roleDefinitionName=='$RoleName']" `
            --output json 2>$null | ConvertFrom-Json
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect '$RoleName' assignments at '$Scope'."
    }
    if ($Assignments.Count -gt 0) {
        return
    }

    & $script:AzureCli role assignment create `
        --subscription $ScopeParts.SubscriptionId `
        --assignee-object-id $PrincipalId `
        --assignee-principal-type $PrincipalType `
        --role $RoleName `
        --scope $Scope `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to grant '$RoleName' at '$Scope'."
    }
}

function Add-GrafanaAzureMonitorWorkspaceIntegration {
    <#
    .SYNOPSIS
        Links an Azure Monitor workspace to Azure Managed Grafana.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GrafanaResourceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AzureMonitorWorkspaceResourceId
    )

    $GrafanaParts = ConvertFrom-AzureResourceId -ResourceId $GrafanaResourceId
    $AzureMonitorWorkspaceParts = ConvertFrom-AzureResourceId -ResourceId $AzureMonitorWorkspaceResourceId
    $LinkedWorkspaceResourceIds = @(
        Invoke-AzureCliJson `
            -Arguments @(
                'grafana', 'integration', 'monitor', 'list',
                '--subscription', $GrafanaParts.SubscriptionId,
                '--resource-group', $GrafanaParts.ResourceGroupName,
                '--name', $GrafanaParts.Name,
                '--output', 'json'
            ) `
            -FailureMessage "Unable to list Azure Monitor workspace integrations for Grafana '$($GrafanaParts.Name)'."
    )

    if ($LinkedWorkspaceResourceIds -inotcontains $AzureMonitorWorkspaceResourceId.TrimEnd('/')) {
        Invoke-AzureCliJson `
            -Arguments @(
                'grafana', 'integration', 'monitor', 'add',
                '--subscription', $GrafanaParts.SubscriptionId,
                '--resource-group', $GrafanaParts.ResourceGroupName,
                '--name', $GrafanaParts.Name,
                '--monitor-subscription-id', $AzureMonitorWorkspaceParts.SubscriptionId,
                '--monitor-resource-group-name', $AzureMonitorWorkspaceParts.ResourceGroupName,
                '--monitor-name', $AzureMonitorWorkspaceParts.Name,
                '--skip-role-assignments', 'true',
                '--output', 'json'
            ) `
            -FailureMessage "Unable to link Azure Monitor workspace '$($AzureMonitorWorkspaceParts.Name)' to Grafana '$($GrafanaParts.Name)'." | Out-Null
    }

    $VerifiedWorkspaceResourceIds = @(
        Invoke-AzureCliJson `
            -Arguments @(
                'grafana', 'integration', 'monitor', 'list',
                '--subscription', $GrafanaParts.SubscriptionId,
                '--resource-group', $GrafanaParts.ResourceGroupName,
                '--name', $GrafanaParts.Name,
                '--output', 'json'
            ) `
            -FailureMessage "Unable to verify Azure Monitor workspace integrations for Grafana '$($GrafanaParts.Name)'."
    )
    if ($VerifiedWorkspaceResourceIds -inotcontains $AzureMonitorWorkspaceResourceId.TrimEnd('/')) {
        throw "Azure Monitor workspace '$AzureMonitorWorkspaceResourceId' is not linked to Grafana '$GrafanaResourceId'."
    }
}

function Select-GrafanaResource {
    <#
    .SYNOPSIS
        Prompts the user to select an existing Managed Grafana resource or create one.
    .OUTPUTS
        [object] The selected resource, or null when a new resource should be created.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Resources
    )

    if ($Resources.Count -eq 0) {
        return $null
    }

    Write-Information 'Azure Managed Grafana instances found:' -InformationAction Continue
    for ($Index = 0; $Index -lt $Resources.Count; $Index++) {
        Write-Information "  $($Index + 1). $($Resources[$Index].name) ($($Resources[$Index].resourceGroup))" -InformationAction Continue
    }
    Write-Information '  N. Create a new instance' -InformationAction Continue

    $Selection = Read-Host -Prompt 'Select a Grafana instance'
    if ($Selection -match '^[nN]$') {
        return $null
    }

    $SelectedIndex = 0
    if (-not [int]::TryParse($Selection, [ref]$SelectedIndex) -or $SelectedIndex -lt 1 -or $SelectedIndex -gt $Resources.Count) {
        throw "Grafana selection '$Selection' is invalid."
    }

    return $Resources[$SelectedIndex - 1]
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $script:AzureCli = (Get-Command az -ErrorAction Stop).Source
        $ProjectRoot = Split-Path -Path $PSScriptRoot -Parent
        $TemplateFile = Join-Path $ProjectRoot 'infra/main.bicep'
        $ImportScript = Join-Path $PSScriptRoot 'Import-GrafanaDashboard.ps1'
        $PolicyScript = Join-Path $PSScriptRoot 'Deploy-FreeGuestMetricsPolicy.ps1'

        $DefaultAccount = Invoke-AzureCliJson `
            -Arguments @('account', 'show', '--output', 'json') `
            -FailureMessage "No Azure CLI session is active. Run 'az login' first."
        $TenantId = Read-DeploymentValue -Value $TenantId -Prompt 'Microsoft Entra tenant ID' -DefaultValue $DefaultAccount.tenantId
        $DefaultSubscriptionId = if ($DefaultAccount.tenantId -eq $TenantId) { $DefaultAccount.id } else { $null }
        $SubscriptionId = Read-DeploymentValue -Value $SubscriptionId -Prompt 'Deployment subscription ID' -DefaultValue $DefaultSubscriptionId

        $DeploymentAccount = Invoke-AzureCliJson `
            -Arguments @('account', 'show', '--subscription', $SubscriptionId, '--output', 'json') `
            -FailureMessage "Unable to access subscription '$SubscriptionId'."
        if ($DeploymentAccount.tenantId -ne $TenantId) {
            throw "Subscription '$SubscriptionId' belongs to tenant '$($DeploymentAccount.tenantId)', not '$TenantId'."
        }
        & $script:AzureCli account set --subscription $SubscriptionId
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to select subscription '$SubscriptionId'."
        }

        $SelectedArtifacts = (
            $Grafana.IsPresent -or
            $VMInsights.IsPresent -or
            $Free.IsPresent -or
            $Alerts.IsPresent -or
            $FreeGuestMetrics.IsPresent
        )
        $DeployGrafana = if ($SelectedArtifacts) { $Grafana.IsPresent } else { $true }
        $DeployVMInsights = if ($SelectedArtifacts) { $VMInsights.IsPresent } else { $true }
        $DeployFree = if ($SelectedArtifacts) { $Free.IsPresent } else { $true }
        $DeployAlerts = if ($SelectedArtifacts) { $Alerts.IsPresent } else { $true }
        $DeployFreeGuestMetrics = if ($SelectedArtifacts) { $FreeGuestMetrics.IsPresent } else { $false }
        $NeedAzureMonitorWorkspace = $DeployGrafana -or $DeployFree -or $DeployFreeGuestMetrics
        $NeedFreeGuestMetricsDcr = $NeedAzureMonitorWorkspace
        $NeedResourceGroup = (
            $DeployGrafana -or
            $DeployVMInsights -or
            $DeployFree -or
            $DeployAlerts -or
            $DeployFreeGuestMetrics
        )

        if ($NeedResourceGroup) {
            $ResourceGroupName = Read-DeploymentValue -Value $ResourceGroupName -Prompt 'Deployment resource group name' -DefaultValue 'vm-disk-observability-rg'
            $ResourceGroupJson = & $script:AzureCli group show `
                --subscription $SubscriptionId `
                --name $ResourceGroupName `
                --output json 2>$null
            if ($LASTEXITCODE -eq 0) {
                $ResourceGroup = $ResourceGroupJson | ConvertFrom-Json
                $Location = $ResourceGroup.location
            }
            else {
                $Location = Read-DeploymentValue -Value $Location -Prompt 'Azure region for the new resource group'
                $ResourceGroup = Invoke-AzureCliJson `
                    -Arguments @('group', 'create', '--subscription', $SubscriptionId, '--name', $ResourceGroupName, '--location', $Location, '--output', 'json') `
                    -FailureMessage "Unable to create resource group '$ResourceGroupName'."
            }
        }

        $NeedLogAnalyticsWorkspace = $DeployVMInsights -or $DeployGrafana
        $NeedNativeVm = (
            $DeployGrafana -or
            $DeployVMInsights -or
            $DeployFree -or
            $DeployAlerts -or
            $DeployFreeGuestMetrics
        )

        if ($NeedLogAnalyticsWorkspace) {
            $LogAnalyticsWorkspaceResourceId = Read-DeploymentValue `
                -Value $LogAnalyticsWorkspaceResourceId `
                -Prompt 'Log Analytics workspace resource ID'
        }
        if ($DeployFreeGuestMetrics) {
            $ManagementGroupName = Read-DeploymentValue `
                -Value $ManagementGroupName `
                -Prompt 'Management group name for free guest metrics policy'
        }
        if ($NeedNativeVm) {
            $NativeVmResourceId = Read-DeploymentValue `
                -Value $NativeVmResourceId `
                -Prompt 'Native Azure VM resource ID'
        }
        if ($DeployAlerts) {
            $AlertEmailAddress = Read-DeploymentValue `
                -Value $AlertEmailAddress `
                -Prompt 'Email address for disk and VM SKU saturation alerts'
            if ($AlertEmailAddress -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                throw "AlertEmailAddress '$AlertEmailAddress' is not a valid email address."
            }
        }

        $FreeGuestMetricsDcr = $null
        if (
            -not [string]::IsNullOrWhiteSpace($FreeGuestMetricsDcrResourceId) -and
            [string]::IsNullOrWhiteSpace($AzureMonitorWorkspaceResourceId)
        ) {
            $SuppliedDcrParts = ConvertFrom-AzureResourceId -ResourceId $FreeGuestMetricsDcrResourceId
            if (
                $SuppliedDcrParts.ProviderNamespace -ne 'Microsoft.Insights' -or
                $SuppliedDcrParts.ResourceType -ne 'dataCollectionRules'
            ) {
                throw 'The supplied free guest metrics DCR ID does not identify a data collection rule.'
            }
            $SuppliedDcrAccount = Invoke-AzureCliJson `
                -Arguments @('account', 'show', '--subscription', $SuppliedDcrParts.SubscriptionId, '--output', 'json') `
                -FailureMessage "Unable to access referenced subscription '$($SuppliedDcrParts.SubscriptionId)'."
            if ($SuppliedDcrAccount.tenantId -ne $TenantId) {
                throw "Referenced subscription '$($SuppliedDcrParts.SubscriptionId)' is not in tenant '$TenantId'."
            }
            $FreeGuestMetricsDcr = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $FreeGuestMetricsDcrResourceId, '--api-version', '2024-03-11', '--output', 'json') `
                -FailureMessage "Unable to resolve free guest metrics DCR '$FreeGuestMetricsDcrResourceId'."
            $DcrWorkspaceResourceIds = @(
                $FreeGuestMetricsDcr.properties.destinations.monitoringAccounts |
                    ForEach-Object { [string]$_.accountResourceId } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )
            if ($DcrWorkspaceResourceIds.Count -ne 1) {
                throw 'The supplied free guest metrics DCR must reference exactly one Azure Monitor workspace.'
            }
            $AzureMonitorWorkspaceResourceId = $DcrWorkspaceResourceIds[0]
        }

        $ShouldDeployAzureMonitorWorkspace = (
            $NeedAzureMonitorWorkspace -and
            [string]::IsNullOrWhiteSpace($AzureMonitorWorkspaceResourceId)
        )
        $ShouldDeployFreeGuestMetricsDcr = (
            $NeedFreeGuestMetricsDcr -and
            [string]::IsNullOrWhiteSpace($FreeGuestMetricsDcrResourceId)
        )
        if ($ShouldDeployAzureMonitorWorkspace -and [string]::IsNullOrWhiteSpace($AzureMonitorWorkspaceName)) {
            $AzureMonitorWorkspaceName = 'amw-vm-disk-observability'
        }
        if ($ShouldDeployFreeGuestMetricsDcr -and [string]::IsNullOrWhiteSpace($FreeGuestMetricsDcrName)) {
            $FreeGuestMetricsDcrName = 'dcr-vm-disk-observability'
        }

        $ReferencedSubscriptionIds = @()
        if ($NeedNativeVm) {
            $NativeVmParts = ConvertFrom-AzureResourceId -ResourceId $NativeVmResourceId
            if ($NativeVmParts.ProviderNamespace -ne 'Microsoft.Compute' -or $NativeVmParts.ResourceType -ne 'virtualMachines') {
                throw 'The supplied VM ID does not identify an Azure virtual machine.'
            }
            $ReferencedSubscriptionIds += $NativeVmParts.SubscriptionId
        }
        if (-not [string]::IsNullOrWhiteSpace($LogAnalyticsWorkspaceResourceId)) {
            $WorkspaceParts = ConvertFrom-AzureResourceId -ResourceId $LogAnalyticsWorkspaceResourceId
            if ($WorkspaceParts.ProviderNamespace -ne 'Microsoft.OperationalInsights' -or $WorkspaceParts.ResourceType -ne 'workspaces') {
                throw 'The supplied workspace ID does not identify a Log Analytics workspace.'
            }
            $ReferencedSubscriptionIds += $WorkspaceParts.SubscriptionId
        }
        if (-not [string]::IsNullOrWhiteSpace($AzureMonitorWorkspaceResourceId)) {
            $AzureMonitorWorkspaceParts = ConvertFrom-AzureResourceId -ResourceId $AzureMonitorWorkspaceResourceId
            if (
                $AzureMonitorWorkspaceParts.ProviderNamespace -ne 'Microsoft.Monitor' -or
                $AzureMonitorWorkspaceParts.ResourceType -ne 'accounts'
            ) {
                throw 'The supplied Azure Monitor workspace ID does not identify a Microsoft.Monitor/accounts resource.'
            }
            $ReferencedSubscriptionIds += $AzureMonitorWorkspaceParts.SubscriptionId
        }
        if (-not [string]::IsNullOrWhiteSpace($FreeGuestMetricsDcrResourceId)) {
            $FreeGuestMetricsDcrParts = ConvertFrom-AzureResourceId -ResourceId $FreeGuestMetricsDcrResourceId
            if (
                $FreeGuestMetricsDcrParts.ProviderNamespace -ne 'Microsoft.Insights' -or
                $FreeGuestMetricsDcrParts.ResourceType -ne 'dataCollectionRules'
            ) {
                throw 'The supplied free guest metrics DCR ID does not identify a data collection rule.'
            }
            $ReferencedSubscriptionIds += $FreeGuestMetricsDcrParts.SubscriptionId
        }

        foreach ($ReferencedSubscriptionId in $ReferencedSubscriptionIds | Select-Object -Unique) {
            $ReferencedAccount = Invoke-AzureCliJson `
                -Arguments @('account', 'show', '--subscription', $ReferencedSubscriptionId, '--output', 'json') `
                -FailureMessage "Unable to access referenced subscription '$ReferencedSubscriptionId'."
            if ($ReferencedAccount.tenantId -ne $TenantId) {
                throw "Referenced subscription '$ReferencedSubscriptionId' is not in tenant '$TenantId'."
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($LogAnalyticsWorkspaceResourceId)) {
            Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $LogAnalyticsWorkspaceResourceId, '--output', 'json') `
                -FailureMessage "Unable to resolve Log Analytics workspace '$LogAnalyticsWorkspaceResourceId'." | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($AzureMonitorWorkspaceResourceId)) {
            $AzureMonitorWorkspace = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $AzureMonitorWorkspaceResourceId, '--api-version', '2023-04-03', '--output', 'json') `
                -FailureMessage "Unable to resolve Azure Monitor workspace '$AzureMonitorWorkspaceResourceId'."
            if ([string]$AzureMonitorWorkspace.type -ine 'Microsoft.Monitor/accounts') {
                throw "Resolved resource type '$($AzureMonitorWorkspace.type)' is not Microsoft.Monitor/accounts."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($FreeGuestMetricsDcrResourceId)) {
            if ($null -eq $FreeGuestMetricsDcr) {
                $FreeGuestMetricsDcr = Invoke-AzureCliJson `
                    -Arguments @('resource', 'show', '--ids', $FreeGuestMetricsDcrResourceId, '--api-version', '2024-03-11', '--output', 'json') `
                    -FailureMessage "Unable to resolve free guest metrics DCR '$FreeGuestMetricsDcrResourceId'."
            }
        }
        if ($NeedNativeVm) {
            $NativeVmResource = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $NativeVmResourceId, '--output', 'json') `
                -FailureMessage "Unable to resolve native Azure VM '$NativeVmResourceId'."
        }

        if ($NeedAzureMonitorWorkspace) {
            $NativeVmLocation = ConvertTo-NormalizedLocation -Value ([string]$NativeVmResource.location)
            if ([string]::IsNullOrWhiteSpace($GuestMetricsLocation)) {
                $GuestMetricsLocation = $NativeVmLocation
            }
            elseif ((ConvertTo-NormalizedLocation -Value $GuestMetricsLocation) -ne $NativeVmLocation) {
                throw "GuestMetricsLocation '$GuestMetricsLocation' does not match selected VM region '$($NativeVmResource.location)'."
            }
            else {
                $GuestMetricsLocation = ConvertTo-NormalizedLocation -Value $GuestMetricsLocation
            }

            if (
                $null -ne $AzureMonitorWorkspace -and
                (ConvertTo-NormalizedLocation -Value ([string]$AzureMonitorWorkspace.location)) -ne $GuestMetricsLocation
            ) {
                throw "Azure Monitor workspace location '$($AzureMonitorWorkspace.location)' does not match selected VM region '$GuestMetricsLocation'."
            }
            if ($null -ne $FreeGuestMetricsDcr) {
                Assert-FreeGuestMetricsDcr `
                    -Dcr $FreeGuestMetricsDcr `
                    -AzureMonitorWorkspaceResourceId $AzureMonitorWorkspaceResourceId `
                    -GuestMetricsLocation $GuestMetricsLocation
            }
        }

        if ($ShouldDeployAzureMonitorWorkspace) {
            Ensure-AzureProvider -SubscriptionId $SubscriptionId -ProviderNamespace 'Microsoft.Monitor'
        }
        if (
            $ShouldDeployFreeGuestMetricsDcr -or
            $DeployVMInsights -or
            $DeployFree -or
            $DeployAlerts
        ) {
            Ensure-AzureProvider -SubscriptionId $SubscriptionId -ProviderNamespace 'Microsoft.Insights'
        }
        if ($DeployGrafana) {
            Ensure-AzureCliExtension -Name 'amg'
            Ensure-AzureCliExtension -Name 'resource-graph'
        }

        $ShouldDeployGrafana = $false
        $ShouldGrantExplicitGrafanaAdmin = $false
        if ($DeployGrafana) {
        $GrafanaResource = $null
        $ShouldGrantExplicitGrafanaAdmin = -not [string]::IsNullOrWhiteSpace($GrafanaAdminPrincipalId)
        if (-not $ShouldGrantExplicitGrafanaAdmin -and -not [string]::IsNullOrWhiteSpace($GrafanaAdminPrincipalType)) {
            throw 'GrafanaAdminPrincipalId is required with GrafanaAdminPrincipalType.'
        }
        if (-not [string]::IsNullOrWhiteSpace($GrafanaResourceId)) {
            $GrafanaResource = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $GrafanaResourceId, '--api-version', '2024-10-01', '--output', 'json') `
                -FailureMessage "Unable to resolve Azure Managed Grafana resource '$GrafanaResourceId'."
        }
        else {
            $GrafanaResources = @(
                Invoke-AzureCliJson `
                    -Arguments @('resource', 'list', '--subscription', $SubscriptionId, '--resource-type', 'Microsoft.Dashboard/grafana', '--output', 'json') `
                    -FailureMessage 'Unable to list Azure Managed Grafana resources.'
            )

            if (-not [string]::IsNullOrWhiteSpace($GrafanaName)) {
                $MatchingGrafanaResources = @(
                    $GrafanaResources | Where-Object { $_.name -eq $GrafanaName }
                )
                if ($MatchingGrafanaResources.Count -gt 1) {
                    throw "Multiple Managed Grafana instances are named '$GrafanaName'. Use GrafanaResourceId to select one."
                }
                $GrafanaResource = $MatchingGrafanaResources | Select-Object -First 1
            }
            else {
                $GrafanaResource = Select-GrafanaResource -Resources $GrafanaResources
            }
        }

        $ShouldDeployGrafana = $null -eq $GrafanaResource
        if ($ShouldDeployGrafana) {
            $GrafanaName = Read-DeploymentValue -Value $GrafanaName -Prompt 'Name for the new Azure Managed Grafana instance' -DefaultValue 'amg-vm-disk-observability'
        }
        else {
            $GrafanaParts = ConvertFrom-AzureResourceId -ResourceId $GrafanaResource.id
            if ($GrafanaParts.ProviderNamespace -ne 'Microsoft.Dashboard' -or $GrafanaParts.ResourceType -ne 'grafana') {
                throw "The selected resource is not an Azure Managed Grafana instance."
            }
            $GrafanaAccount = Invoke-AzureCliJson `
                -Arguments @('account', 'show', '--subscription', $GrafanaParts.SubscriptionId, '--output', 'json') `
                -FailureMessage "Unable to access Grafana subscription '$($GrafanaParts.SubscriptionId)'."
            if ($GrafanaAccount.tenantId -ne $TenantId) {
                throw "The selected Grafana instance is not in tenant '$TenantId'."
            }
            $GrafanaResource = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $GrafanaResource.id, '--api-version', '2024-10-01', '--output', 'json') `
                -FailureMessage "Unable to resolve Azure Managed Grafana '$($GrafanaParts.Name)'."
            if ($GrafanaResource.identity.type -notmatch 'SystemAssigned') {
                throw "Azure Managed Grafana '$($GrafanaResource.name)' must have a system-assigned identity."
            }
            $GrafanaName = $GrafanaResource.name
        }

        if ($ShouldDeployGrafana) {
            Ensure-AzureProvider -SubscriptionId $SubscriptionId -ProviderNamespace 'Microsoft.Dashboard'
        }
        }

        $ShouldRunBicep = (
            $DeployVMInsights -or
            $DeployFree -or
            $DeployAlerts -or
            $ShouldDeployGrafana -or
            $ShouldDeployAzureMonitorWorkspace -or
            $ShouldDeployFreeGuestMetricsDcr
        )
        $Deployment = $null
        if ($ShouldRunBicep) {
            $DeploymentParameters = @(
                "location=$Location",
                "logAnalyticsWorkspaceResourceId=$LogAnalyticsWorkspaceResourceId",
                "azureMonitorWorkspaceResourceId=$AzureMonitorWorkspaceResourceId",
                "shouldDeployAzureMonitorWorkspace=$($ShouldDeployAzureMonitorWorkspace.ToString().ToLowerInvariant())",
                "azureMonitorWorkspaceName=$AzureMonitorWorkspaceName",
                "guestMetricsLocation=$GuestMetricsLocation",
                "shouldDeployFreeGuestMetricsDcr=$($ShouldDeployFreeGuestMetricsDcr.ToString().ToLowerInvariant())",
                "freeGuestMetricsDcrName=$FreeGuestMetricsDcrName",
                "nativeVmResourceId=$NativeVmResourceId",
                "workbookDisplayName=$WorkbookDisplayName",
                "shouldDeployWorkbook=$($DeployVMInsights.ToString().ToLowerInvariant())",
                "shouldDeployAzureVmOnlyWorkbook=$($DeployFree.ToString().ToLowerInvariant())",
                "shouldDeployAlerts=$($DeployAlerts.ToString().ToLowerInvariant())",
                "shouldDeployGrafana=$($ShouldDeployGrafana.ToString().ToLowerInvariant())"
            )
            if ($DeployAlerts) {
                $DeploymentParameters += "alertEmailAddress=$AlertEmailAddress"
            }
            if ($ShouldDeployGrafana) {
                $DeploymentParameters += "grafanaName=$GrafanaName"
            }

            $Deployment = Invoke-AzureCliJson `
                -Arguments (@(
                    'deployment', 'group', 'create',
                    '--subscription', $SubscriptionId,
                    '--resource-group', $ResourceGroupName,
                    '--name', 'vm-disk-observability',
                    '--template-file', $TemplateFile,
                    '--parameters'
                ) + $DeploymentParameters + @('--output', 'json')) `
                -FailureMessage 'The Azure resource deployment failed.'
        }

        if ($NeedAzureMonitorWorkspace) {
            if ($ShouldDeployAzureMonitorWorkspace) {
                $AzureMonitorWorkspaceResourceId = [string]$Deployment.properties.outputs.effectiveAzureMonitorWorkspaceResourceId.value
            }
            $AzureMonitorWorkspace = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $AzureMonitorWorkspaceResourceId, '--api-version', '2023-04-03', '--output', 'json') `
                -FailureMessage "Unable to verify Azure Monitor workspace '$AzureMonitorWorkspaceResourceId'."
            if (
                [string]$AzureMonitorWorkspace.type -ine 'Microsoft.Monitor/accounts' -or
                (ConvertTo-NormalizedLocation -Value ([string]$AzureMonitorWorkspace.location)) -ne $GuestMetricsLocation
            ) {
                throw "Azure Monitor workspace '$AzureMonitorWorkspaceResourceId' failed post-deployment validation."
            }
        }

        if ($NeedFreeGuestMetricsDcr) {
            if ($ShouldDeployFreeGuestMetricsDcr) {
                $FreeGuestMetricsDcrResourceId = [string]$Deployment.properties.outputs.freeGuestMetricsDcrResourceId.value
            }
            $FreeGuestMetricsDcr = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $FreeGuestMetricsDcrResourceId, '--api-version', '2024-03-11', '--output', 'json') `
                -FailureMessage "Unable to verify free guest metrics DCR '$FreeGuestMetricsDcrResourceId'."
            Assert-FreeGuestMetricsDcr `
                -Dcr $FreeGuestMetricsDcr `
                -AzureMonitorWorkspaceResourceId $AzureMonitorWorkspaceResourceId `
                -GuestMetricsLocation $GuestMetricsLocation
        }

        if ($DeployGrafana -and $ShouldDeployGrafana) {
            $GrafanaResourceId = $Deployment.properties.outputs.grafanaResourceId.value
            $GrafanaResource = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $GrafanaResourceId, '--api-version', '2024-10-01', '--output', 'json') `
                -FailureMessage "Unable to resolve newly created Azure Managed Grafana '$GrafanaName'."
        }
        elseif ($DeployGrafana) {
            $GrafanaResourceId = $GrafanaResource.id
        }

        $DeploymentPrincipalId = $null
        $DeploymentPrincipalType = $null
        if (-not $SkipRoleAssignments) {
            if ($DeploymentAccount.user.type -eq 'user') {
                $DeploymentPrincipalId = (& $script:AzureCli ad signed-in-user show --query id --output tsv).Trim()
                $DeploymentPrincipalType = 'User'
            }
            else {
                $DeploymentPrincipalId = (& $script:AzureCli ad sp show --id $DeploymentAccount.user.name --query id --output tsv).Trim()
                $DeploymentPrincipalType = 'ServicePrincipal'
            }
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($DeploymentPrincipalId)) {
                throw 'Unable to resolve the deploying principal object ID.'
            }

            if ($NeedLogAnalyticsWorkspace) {
                Grant-AzureRole `
                    -PrincipalId $DeploymentPrincipalId `
                    -PrincipalType $DeploymentPrincipalType `
                    -RoleName 'Log Analytics Reader' `
                    -Scope $LogAnalyticsWorkspaceResourceId
            }
            if ($NeedNativeVm) {
                Grant-AzureRole `
                    -PrincipalId $DeploymentPrincipalId `
                    -PrincipalType $DeploymentPrincipalType `
                    -RoleName 'Monitoring Reader' `
                    -Scope $NativeVmResourceId
            }
            if ($NeedAzureMonitorWorkspace) {
                Grant-AzureRole `
                    -PrincipalId $DeploymentPrincipalId `
                    -PrincipalType $DeploymentPrincipalType `
                    -RoleName 'Monitoring Data Reader' `
                    -Scope $AzureMonitorWorkspaceResourceId
            }
        }

        if ($DeployGrafana -and -not $SkipRoleAssignments) {
            $ImportPrincipalId = $DeploymentPrincipalId
            $ImportPrincipalType = $DeploymentPrincipalType

            if ($ShouldDeployGrafana -and -not $ShouldGrantExplicitGrafanaAdmin) {
                $GrafanaAdminPrincipalId = $ImportPrincipalId
                $GrafanaAdminPrincipalType = $ImportPrincipalType
                $ShouldGrantExplicitGrafanaAdmin = $true
            }

            if ($ShouldGrantExplicitGrafanaAdmin) {
                if ([string]::IsNullOrWhiteSpace($GrafanaAdminPrincipalType)) {
                    throw 'GrafanaAdminPrincipalType is required with GrafanaAdminPrincipalId.'
                }

                Grant-AzureRole `
                    -PrincipalId $GrafanaAdminPrincipalId `
                    -PrincipalType $GrafanaAdminPrincipalType `
                    -RoleName 'Grafana Admin' `
                    -Scope $GrafanaResourceId
            }

            if (-not $SkipGrafanaImport -and $ImportPrincipalId -ne $GrafanaAdminPrincipalId) {
                Grant-AzureRole `
                    -PrincipalId $ImportPrincipalId `
                    -PrincipalType $ImportPrincipalType `
                    -RoleName 'Grafana Editor' `
                    -Scope $GrafanaResourceId
            }

            $GrafanaPrincipalId = $GrafanaResource.identity.principalId
            Grant-AzureRole `
                -PrincipalId $GrafanaPrincipalId `
                -PrincipalType 'ServicePrincipal' `
                -RoleName 'Monitoring Reader' `
                -Scope $LogAnalyticsWorkspaceResourceId
            Grant-AzureRole `
                -PrincipalId $GrafanaPrincipalId `
                -PrincipalType 'ServicePrincipal' `
                -RoleName 'Monitoring Reader' `
                -Scope $NativeVmResourceId
            Grant-AzureRole `
                -PrincipalId $GrafanaPrincipalId `
                -PrincipalType 'ServicePrincipal' `
                -RoleName 'Monitoring Data Reader' `
                -Scope $AzureMonitorWorkspaceResourceId
        }

        if ($DeployGrafana) {
            Add-GrafanaAzureMonitorWorkspaceIntegration `
                -GrafanaResourceId $GrafanaResourceId `
                -AzureMonitorWorkspaceResourceId $AzureMonitorWorkspaceResourceId
        }

        if ($DeployGrafana -and -not $SkipGrafanaImport) {
            & $ImportScript `
                -TenantId $TenantId `
                -GrafanaResourceId $GrafanaResourceId `
                -WorkspaceResourceId $LogAnalyticsWorkspaceResourceId `
                -AzureMonitorWorkspaceResourceId $AzureMonitorWorkspaceResourceId `
                -NativeVmResourceId $NativeVmResourceId `
                -DashboardTitle $WorkbookDisplayName
            if ($LASTEXITCODE -ne 0) {
                throw 'The Grafana dashboard import failed.'
            }
        }

        if ($DeployFreeGuestMetrics) {
            $PolicyDeploymentParameters = @{
                ManagementGroupName = $ManagementGroupName
                TenantId = $TenantId
                DcrResourceId = $FreeGuestMetricsDcrResourceId
                StartRemediation = -not $SkipPolicyRemediation.IsPresent
            }
            if (-not [string]::IsNullOrWhiteSpace($FreeGuestMetricsAssignmentName)) {
                $PolicyDeploymentParameters.AssignmentName = $FreeGuestMetricsAssignmentName
            }
            if (-not [string]::IsNullOrWhiteSpace($FreeGuestMetricsAssignmentDisplayName)) {
                $PolicyDeploymentParameters.AssignmentDisplayName = $FreeGuestMetricsAssignmentDisplayName
            }
            & $PolicyScript @PolicyDeploymentParameters
            if ($LASTEXITCODE -ne 0) {
                throw 'The free guest metrics policy deployment failed.'
            }
        }

        if ($DeployVMInsights -and $Deployment) {
            Write-Information "VM Insights workbook deployed: $($Deployment.properties.outputs.workbookResourceId.value)" -InformationAction Continue
        }
        if ($DeployFree -and $Deployment) {
            Write-Information "Free (Azure VM-only) workbook deployed: $($Deployment.properties.outputs.azureVmOnlyWorkbookResourceId.value)" -InformationAction Continue
        }
        if ($DeployAlerts -and $Deployment) {
            Write-Information "Alert Action Group deployed: $($Deployment.properties.outputs.alertActionGroupResourceId.value)" -InformationAction Continue
            Write-Information "Metric alerts deployed: $($Deployment.properties.outputs.metricAlertResourceIds.value.Count)" -InformationAction Continue
        }
        if ($DeployGrafana) {
            Write-Information "Azure Managed Grafana: $GrafanaResourceId" -InformationAction Continue
        }
        if ($DeployFreeGuestMetrics) {
            Write-Information "Free guest metrics policy deployed at management group: $ManagementGroupName" -InformationAction Continue
        }
    }
    catch {
        Write-Error -ErrorAction Continue "Solution deployment failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution