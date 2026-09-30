#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys management-group policy onboarding for default no-charge guest metrics.
.DESCRIPTION
    Validates Azure CLI authentication, the target management group, its descendant
    subscriptions, and a regional cross-subscription data collection rule. Deploys
    the checked-in management-group Bicep template, waits for the assignment
    identity's required role assignments, and optionally starts one remediation
    task for each initiative policy reference in every descendant subscription.
.PARAMETER ManagementGroupName
    Management group name. The script prompts for this value when it is omitted.
.PARAMETER TenantId
    Optional Microsoft Entra tenant ID. When supplied, it must match the active
    Azure CLI tenant, management group, and data collection rule subscription.
.PARAMETER DcrResourceId
    Resource ID of the data collection rule used for default OpenTelemetry metrics.
    Its subscription must be a descendant of the target management group.
.PARAMETER Location
    Optional Azure region override for the deployment record, assignment identity,
    policy parameters, resource selector, and remediation location filter. When omitted,
    the script uses the DCR region.
.PARAMETER InitiativeName
    Resource name of the custom policy initiative.
.PARAMETER InitiativeDisplayName
    Display name of the custom policy initiative.
.PARAMETER AssignmentName
    Resource name of the management-group policy assignment.
.PARAMETER AssignmentDisplayName
    Display name of the management-group policy assignment.
.PARAMETER DeploymentName
    Name of the management-group deployment.
.PARAMETER StartRemediation
    Starts remediation tasks after RBAC propagation when true. Defaults to true.
.PARAMETER RoleAssignmentTimeoutSeconds
    Maximum time to wait for all required role assignments to become visible.
.PARAMETER RoleAssignmentRetrySeconds
    Delay between role-assignment visibility checks.
.EXAMPLE
    ./scripts/Deploy-FreeGuestMetricsPolicy.ps1 -DcrResourceId <dcr-resource-id>
.EXAMPLE
    ./scripts/Deploy-FreeGuestMetricsPolicy.ps1 -ManagementGroupName <management-group> -TenantId <tenant-id> -DcrResourceId <dcr-resource-id> -StartRemediation:$false
.NOTES
    Requires Azure CLI authentication and permissions to deploy policy and role
    assignments at the management group. This script does not create the DCR.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagementGroupName,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DcrResourceId,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [ValidateLength(1, 64)]
    [string]$InitiativeName = 'free-guest-metrics',

    [Parameter(Mandatory = $false)]
    [ValidateLength(1, 128)]
    [string]$InitiativeDisplayName = 'Default no-charge Azure Monitor guest metrics',

    [Parameter(Mandatory = $false)]
    [ValidateLength(1, 24)]
    [string]$AssignmentName = 'free-guest-metrics',

    [Parameter(Mandatory = $false)]
    [ValidateLength(1, 128)]
    [string]$AssignmentDisplayName = 'Default no-charge guest metrics',

    [Parameter(Mandatory = $false)]
    [ValidateLength(1, 64)]
    [string]$DeploymentName = 'free-guest-metrics-policy',

    [Parameter(Mandatory = $false)]
    [bool]$StartRemediation = $true,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 3600)]
    [int]$RoleAssignmentTimeoutSeconds = 600,

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 300)]
    [int]$RoleAssignmentRetrySeconds = 15
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

#region Functions
function Read-RequiredValue {
    <#
    .SYNOPSIS
        Returns a supplied value or prompts for a required value.
    .OUTPUTS
        [string] The trimmed supplied or entered value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value.Trim()
    }

    $EnteredValue = Read-Host -Prompt $Prompt
    if ([string]::IsNullOrWhiteSpace($EnteredValue)) {
        throw "$Prompt is required."
    }

    return $EnteredValue.Trim()
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

    $ResourceIdPattern = '^/subscriptions/(?<SubscriptionId>[0-9a-fA-F-]{36})/resourceGroups/(?<ResourceGroupName>[^/]+)/providers/(?<ProviderNamespace>[^/]+)/(?<ResourceType>[^/]+)/(?<Name>[^/]+)$'
    $NormalizedResourceId = "/$($ResourceId.Trim().Trim('/'))"
    $ResourceIdMatch = [regex]::Match(
        $NormalizedResourceId,
        $ResourceIdPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $ResourceIdMatch.Success) {
        throw "Not a valid resource-group-scoped Azure resource ID: '$ResourceId'."
    }

    $ParsedSubscriptionId = $ResourceIdMatch.Groups['SubscriptionId'].Value
    if (-not [guid]::TryParse($ParsedSubscriptionId, [ref]([guid]::Empty))) {
        throw "The subscription segment in resource ID '$ResourceId' is not a valid GUID."
    }

    return @{
        Name = $ResourceIdMatch.Groups['Name'].Value
        NormalizedResourceId = $NormalizedResourceId
        ProviderNamespace = $ResourceIdMatch.Groups['ProviderNamespace'].Value
        ResourceGroupName = $ResourceIdMatch.Groups['ResourceGroupName'].Value
        ResourceType = $ResourceIdMatch.Groups['ResourceType'].Value
        SubscriptionId = $ParsedSubscriptionId
    }
}

function ConvertTo-NormalizedLocation {
    <#
    .SYNOPSIS
        Converts an Azure location to its normalized resource name.
    .OUTPUTS
        [string] The lower-case location without whitespace.
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
        Invokes Azure CLI and parses the JSON response.
    .OUTPUTS
        [object] The parsed Azure CLI response.
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

    $EffectiveArguments = @($Arguments) + @('--only-show-errors', '--output', 'json')
    $CommandOutput = @(& $script:AzureCli @EffectiveArguments 2>&1)
    $ExitCode = $LASTEXITCODE
    $OutputText = ($CommandOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

    if ($ExitCode -ne 0) {
        $Details = if ([string]::IsNullOrWhiteSpace($OutputText)) {
            "Azure CLI exited with code $ExitCode."
        }
        else {
            $OutputText
        }
        throw "$FailureMessage $Details"
    }

    if ([string]::IsNullOrWhiteSpace($OutputText)) {
        return $null
    }

    try {
        return $OutputText | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "$FailureMessage Azure CLI returned invalid JSON: $($_.Exception.Message)"
    }
}

function Wait-AzureRoleAssignment {
    <#
    .SYNOPSIS
        Waits until every required role assignment is visible for a principal.
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
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$RoleDefinitionIds,

        [Parameter(Mandatory = $true)]
        [ValidateRange(30, 3600)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [ValidateRange(5, 300)]
        [int]$RetrySeconds
    )

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $LastCheckError = $null
    do {
        try {
            $Assignments = @(
                Invoke-AzureCliJson -Arguments @(
                    'role', 'assignment', 'list',
                    '--assignee-object-id', $PrincipalId,
                    '--scope', $Scope,
                    '--fill-principal-name', 'false',
                    '--fill-role-definition-name', 'false'
                ) -FailureMessage "Unable to query role assignments for policy principal '$PrincipalId'."
            )
            $ObservedRoleDefinitionIds = @(
                $Assignments |
                    ForEach-Object { [string]$_.roleDefinitionId } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { $_.ToLowerInvariant() }
            )
            $MissingRoleDefinitionIds = @(
                $RoleDefinitionIds |
                    Where-Object { $ObservedRoleDefinitionIds -notcontains $_.ToLowerInvariant() }
            )
            $LastCheckError = $null

            if ($MissingRoleDefinitionIds.Count -eq 0) {
                Write-Information 'All required management-group role assignments are visible.' -InformationAction Continue
                return
            }

            Write-Information "Waiting for $($MissingRoleDefinitionIds.Count) role assignment(s) to become visible..." -InformationAction Continue
        }
        catch {
            $LastCheckError = $_.Exception.Message
            Write-Warning "Role-assignment visibility check failed and will be retried: $LastCheckError"
        }

        if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $FailureDetail = if ($null -ne $LastCheckError) {
                " Last query error: $LastCheckError"
            }
            else {
                " Missing role definition IDs: $($MissingRoleDefinitionIds -join ', ')."
            }
            throw "Required role assignments were not visible after $TimeoutSeconds seconds.$FailureDetail"
        }

        Start-Sleep -Seconds $RetrySeconds
    } while ($true)
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $script:AzureCli = (Get-Command az -ErrorAction Stop).Source
        $TemplateFile = Join-Path $PSScriptRoot '../infra/free-guest-metrics-policy.bicep'
        if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
            throw "Bicep template was not found at '$TemplateFile'."
        }

        $ManagementGroupName = Read-RequiredValue `
            -Value $ManagementGroupName `
            -Prompt 'Management group name'
        $DcrParts = ConvertFrom-AzureResourceId -ResourceId $DcrResourceId
        $DcrResourceType = "$($DcrParts.ProviderNamespace)/$($DcrParts.ResourceType)"
        if ($DcrResourceType -ine 'Microsoft.Insights/dataCollectionRules') {
            throw "DcrResourceId must identify Microsoft.Insights/dataCollectionRules, not '$DcrResourceType'."
        }

        $Account = Invoke-AzureCliJson `
            -Arguments @('account', 'show') `
            -FailureMessage 'Azure CLI is not signed in. Run az login and try again.'
        $ActiveTenantId = [string]$Account.tenantId
        if ([string]::IsNullOrWhiteSpace($ActiveTenantId)) {
            throw 'Azure CLI did not return an active tenant ID.'
        }
        if (-not [string]::IsNullOrWhiteSpace($TenantId) -and $ActiveTenantId -ine $TenantId) {
            throw "Azure CLI is signed in to tenant '$ActiveTenantId', not requested tenant '$TenantId'."
        }
        $TenantId = $ActiveTenantId

        $EscapedManagementGroupName = [uri]::EscapeDataString($ManagementGroupName)
        $ManagementGroupApiUrl = "https://management.azure.com/providers/Microsoft.Management/managementGroups/${EscapedManagementGroupName}?api-version=2020-05-01"
        $ManagementGroup = Invoke-AzureCliJson `
            -Arguments @('rest', '--method', 'get', '--url', $ManagementGroupApiUrl) `
            -FailureMessage "Unable to access management group '$ManagementGroupName' in tenant '$TenantId'."
        $ManagementGroupTenantId = [string]$ManagementGroup.properties.tenantId
        if (
            -not [string]::IsNullOrWhiteSpace($ManagementGroupTenantId) -and
            $ManagementGroupTenantId -ine $TenantId
        ) {
            throw "Management group '$ManagementGroupName' belongs to tenant '$ManagementGroupTenantId', not '$TenantId'."
        }
        $ManagementGroupResourceId = [string]$ManagementGroup.id
        if ([string]::IsNullOrWhiteSpace($ManagementGroupResourceId)) {
            throw "Management group '$ManagementGroupName' did not return a resource ID."
        }

        $DescendantsApiUrl = "https://management.azure.com/providers/Microsoft.Management/managementGroups/${EscapedManagementGroupName}/descendants?api-version=2020-05-01"
        $Descendants = Invoke-AzureCliJson `
            -Arguments @('rest', '--method', 'get', '--url', $DescendantsApiUrl) `
            -FailureMessage "Unable to enumerate descendants of management group '$ManagementGroupName'."
        $ChildSubscriptions = @(
            $Descendants.value |
                Where-Object { [string]$_.type -imatch 'subscriptions$' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Name = [string]$_.properties.displayName
                        SubscriptionId = [string]$_.name
                        State = [string]$_.properties.state
                        IsDcrSubscription = ([string]$_.name -ieq $DcrParts.SubscriptionId)
                    }
                } |
                Sort-Object -Property Name, SubscriptionId
        )
        if ($ChildSubscriptions.Count -eq 0) {
            throw "Management group '$ManagementGroupName' has no descendant subscriptions."
        }

        Write-Information "`nDescendant subscriptions for management group '$ManagementGroupName':" -InformationAction Continue
        $SubscriptionTable = $ChildSubscriptions |
            Format-Table -Property Name, SubscriptionId, State, IsDcrSubscription -AutoSize |
            Out-String
        Write-Information ($SubscriptionTable.TrimEnd()) -InformationAction Continue

        $DcrSubscription = Invoke-AzureCliJson `
            -Arguments @('account', 'show', '--subscription', $DcrParts.SubscriptionId) `
            -FailureMessage "Unable to access DCR subscription '$($DcrParts.SubscriptionId)'."
        if ([string]$DcrSubscription.tenantId -ine $TenantId) {
            throw "DCR subscription '$($DcrParts.SubscriptionId)' belongs to tenant '$($DcrSubscription.tenantId)', not '$TenantId'."
        }
        if ($ChildSubscriptions.SubscriptionId -inotcontains $DcrParts.SubscriptionId) {
            throw "DCR subscription '$($DcrParts.SubscriptionId)' is not a descendant of management group '$ManagementGroupName'. Management-group role assignments would not grant cross-subscription DCR access."
        }

        $Dcr = Invoke-AzureCliJson `
            -Arguments @('resource', 'show', '--ids', $DcrParts.NormalizedResourceId) `
            -FailureMessage "Unable to resolve data collection rule '$($DcrParts.NormalizedResourceId)'."
        if ([string]$Dcr.type -ine 'Microsoft.Insights/dataCollectionRules') {
            throw "Resolved resource type '$($Dcr.type)' is not Microsoft.Insights/dataCollectionRules."
        }
        $DcrLocation = ConvertTo-NormalizedLocation -Value ([string]$Dcr.location)
        $NormalizedLocation = if ([string]::IsNullOrWhiteSpace($Location)) {
            $DcrLocation
        }
        else {
            ConvertTo-NormalizedLocation -Value $Location
        }
        if (-not [string]::IsNullOrWhiteSpace($Location) -and $DcrLocation -ine $NormalizedLocation) {
            throw "DCR location '$($Dcr.location)' does not match policy location '$Location'."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Dcr.kind)) {
            throw "The DCR must support both Windows and Linux, but its kind is '$($Dcr.kind)'."
        }
        $DcrProvisioningState = [string]$Dcr.properties.provisioningState
        if (
            -not [string]::IsNullOrWhiteSpace($DcrProvisioningState) -and
            $DcrProvisioningState -ine 'Succeeded'
        ) {
            throw "DCR provisioning state is '$DcrProvisioningState', not 'Succeeded'."
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
            throw "The DCR is missing required OpenTelemetry counters: $($MissingGuestMetricCounters -join ', ')."
        }
        $MonitoringAccountDestinationNames = @(
            $Dcr.properties.destinations.monitoringAccounts |
                ForEach-Object { [string]$_.name } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $ValidOtelDataFlows = @(
            $Dcr.properties.dataFlows |
                Where-Object {
                    $_.streams -contains 'Microsoft-OtelPerfMetrics' -and
                    @($_.destinations | Where-Object {
                            $MonitoringAccountDestinationNames -icontains $_
                        }).Count -gt 0
                }
        )
        if ($MonitoringAccountDestinationNames.Count -eq 0 -or $ValidOtelDataFlows.Count -eq 0) {
            throw 'The DCR must route Microsoft-OtelPerfMetrics to an Azure Monitor workspace destination.'
        }

        $OtherChildSubscriptionCount = @(
            $ChildSubscriptions |
                Where-Object { $_.SubscriptionId -ine $DcrParts.SubscriptionId }
        ).Count
        Write-Information "Validated DCR '$($Dcr.name)' in '$($Dcr.location)' and $OtherChildSubscriptionCount cross-subscription target(s)." -InformationAction Continue

        if (-not $PSCmdlet.ShouldProcess(
            $ManagementGroupResourceId,
            "Deploy initiative '$InitiativeName' and assignment '$AssignmentName'"
        )) {
            return
        }

        $DeploymentArguments = @(
            'deployment', 'mg', 'create',
            '--management-group-id', $ManagementGroupName,
            '--location', $NormalizedLocation,
            '--name', $DeploymentName,
            '--template-file', $TemplateFile,
            '--parameters',
            "initiativeName=$InitiativeName",
            "initiativeDisplayName=$InitiativeDisplayName",
            "assignmentName=$AssignmentName",
            "assignmentDisplayName=$AssignmentDisplayName",
            "dcrResourceId=$($DcrParts.NormalizedResourceId)",
            "location=$NormalizedLocation"
        )
        $Deployment = Invoke-AzureCliJson `
            -Arguments $DeploymentArguments `
            -FailureMessage "Management-group deployment '$DeploymentName' failed."
        $DeploymentOutputs = $Deployment.properties.outputs
        if ($null -eq $DeploymentOutputs) {
            throw "Management-group deployment '$DeploymentName' returned no outputs."
        }

        $AssignmentResourceId = [string]$DeploymentOutputs.assignmentResourceId.value
        $AssignmentPrincipalId = [string]$DeploymentOutputs.assignmentPrincipalId.value
        $PolicyDefinitionReferenceIds = @($DeploymentOutputs.policyDefinitionReferenceIds.value)
        $RequiredRoleDefinitionIds = @($DeploymentOutputs.requiredRoleDefinitionIds.value)
        if (
            [string]::IsNullOrWhiteSpace($AssignmentResourceId) -or
            [string]::IsNullOrWhiteSpace($AssignmentPrincipalId) -or
            $PolicyDefinitionReferenceIds.Count -ne 4 -or
            $RequiredRoleDefinitionIds.Count -ne 3
        ) {
            throw "Management-group deployment '$DeploymentName' returned incomplete policy outputs."
        }

        Wait-AzureRoleAssignment `
            -PrincipalId $AssignmentPrincipalId `
            -Scope $ManagementGroupResourceId `
            -RoleDefinitionIds $RequiredRoleDefinitionIds `
            -TimeoutSeconds $RoleAssignmentTimeoutSeconds `
            -RetrySeconds $RoleAssignmentRetrySeconds

        if ($StartRemediation) {
            $RemediationRunId = Get-Date -AsUTC -Format 'yyyyMMddHHmmssfff'
            $RemediationSuffixes = @{
                windowsAmaSystemIdentity = 'windows-ama'
                linuxAmaSystemIdentity = 'linux-ama'
                windowsDcrAssociation = 'windows-dcr'
                linuxDcrAssociation = 'linux-dcr'
            }
            foreach ($ChildSubscription in $ChildSubscriptions) {
                $ChildSubscriptionId = [string]$ChildSubscription.SubscriptionId

                foreach ($ReferenceId in $PolicyDefinitionReferenceIds) {
                    if (-not $RemediationSuffixes.ContainsKey([string]$ReferenceId)) {
                        throw "Deployment returned unexpected policy definition reference ID '$ReferenceId'."
                    }

                    $RemediationName = "$AssignmentName-$($RemediationSuffixes[[string]$ReferenceId])-$RemediationRunId"

                    $Remediation = Invoke-AzureCliJson `
                        -Arguments @(
                            'policy', 'remediation', 'create',
                            '--subscription', $ChildSubscriptionId,
                            '--name', $RemediationName,
                            '--policy-assignment', $AssignmentResourceId,
                            '--definition-reference-id', [string]$ReferenceId,
                            '--resource-discovery-mode', 'ReEvaluateCompliance',
                            '--location-filters', $NormalizedLocation
                        ) `
                        -FailureMessage "Unable to create remediation '$RemediationName' in subscription '$ChildSubscriptionId'."
                    Write-Information "Started remediation '$($Remediation.name)' for '$ReferenceId' in '$ChildSubscriptionId'." -InformationAction Continue
                }
            }
        }
        else {
            Write-Information 'Remediation creation was disabled by StartRemediation.' -InformationAction Continue
        }

        Write-Information "Policy assignment deployment completed: $AssignmentResourceId" -InformationAction Continue
    }
    catch {
        Write-Error -ErrorAction Continue "Free guest metrics policy deployment failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution
