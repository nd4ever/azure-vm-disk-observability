#!/usr/bin/env pwsh
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
.PARAMETER NativeVmResourceId
    Resource ID of the native Azure VM used for per-LUN platform metric charts.
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
    [string]$NativeVmResourceId,

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
    [switch]$SkipGrafanaImport
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

        $LogAnalyticsWorkspaceResourceId = Read-DeploymentValue `
            -Value $LogAnalyticsWorkspaceResourceId `
            -Prompt 'Log Analytics workspace resource ID'
        $NativeVmResourceId = Read-DeploymentValue `
            -Value $NativeVmResourceId `
            -Prompt 'Native Azure VM resource ID'

        $WorkspaceParts = ConvertFrom-AzureResourceId -ResourceId $LogAnalyticsWorkspaceResourceId
        $NativeVmParts = ConvertFrom-AzureResourceId -ResourceId $NativeVmResourceId
        if ($WorkspaceParts.ProviderNamespace -ne 'Microsoft.OperationalInsights' -or $WorkspaceParts.ResourceType -ne 'workspaces') {
            throw "The supplied workspace ID does not identify a Log Analytics workspace."
        }
        if ($NativeVmParts.ProviderNamespace -ne 'Microsoft.Compute' -or $NativeVmParts.ResourceType -ne 'virtualMachines') {
            throw "The supplied VM ID does not identify an Azure virtual machine."
        }

        foreach ($ReferencedSubscriptionId in @($WorkspaceParts.SubscriptionId, $NativeVmParts.SubscriptionId) | Select-Object -Unique) {
            $ReferencedAccount = Invoke-AzureCliJson `
                -Arguments @('account', 'show', '--subscription', $ReferencedSubscriptionId, '--output', 'json') `
                -FailureMessage "Unable to access referenced subscription '$ReferencedSubscriptionId'."
            if ($ReferencedAccount.tenantId -ne $TenantId) {
                throw "Referenced subscription '$ReferencedSubscriptionId' is not in tenant '$TenantId'."
            }
        }

        Invoke-AzureCliJson `
            -Arguments @('resource', 'show', '--ids', $LogAnalyticsWorkspaceResourceId, '--output', 'json') `
            -FailureMessage "Unable to resolve Log Analytics workspace '$LogAnalyticsWorkspaceResourceId'." | Out-Null
        Invoke-AzureCliJson `
            -Arguments @('resource', 'show', '--ids', $NativeVmResourceId, '--output', 'json') `
            -FailureMessage "Unable to resolve native Azure VM '$NativeVmResourceId'." | Out-Null

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
            $DashboardProviderState = (& $script:AzureCli provider show `
                    --subscription $SubscriptionId `
                    --namespace Microsoft.Dashboard `
                    --query registrationState `
                    --output tsv 2>$null).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to inspect Microsoft.Dashboard provider registration in '$SubscriptionId'."
            }
            if ($DashboardProviderState -ne 'Registered') {
                & $script:AzureCli provider register `
                    --subscription $SubscriptionId `
                    --namespace Microsoft.Dashboard `
                    --wait `
                    --output none
                if ($LASTEXITCODE -ne 0) {
                    throw "Unable to register the Microsoft.Dashboard resource provider in '$SubscriptionId'."
                }
            }
        }

        $Deployment = Invoke-AzureCliJson `
            -Arguments @(
                'deployment', 'group', 'create',
                '--subscription', $SubscriptionId,
                '--resource-group', $ResourceGroupName,
                '--name', 'vm-disk-observability',
                '--template-file', $TemplateFile,
                '--parameters',
                "location=$Location",
                "logAnalyticsWorkspaceResourceId=$LogAnalyticsWorkspaceResourceId",
                "nativeVmResourceId=$NativeVmResourceId",
                "workbookDisplayName=$WorkbookDisplayName",
                "shouldDeployGrafana=$($ShouldDeployGrafana.ToString().ToLowerInvariant())",
                "grafanaName=$GrafanaName",
                '--output', 'json'
            ) `
            -FailureMessage 'The Azure resource deployment failed.'

        if ($ShouldDeployGrafana) {
            $GrafanaResourceId = $Deployment.properties.outputs.grafanaResourceId.value
            $GrafanaResource = Invoke-AzureCliJson `
                -Arguments @('resource', 'show', '--ids', $GrafanaResourceId, '--api-version', '2024-10-01', '--output', 'json') `
                -FailureMessage "Unable to resolve newly created Azure Managed Grafana '$GrafanaName'."
        }
        else {
            $GrafanaResourceId = $GrafanaResource.id
        }

        if (-not $SkipRoleAssignments) {
            $ImportPrincipalId = $null
            $ImportPrincipalType = $null
            if (-not $SkipGrafanaImport -or ($ShouldDeployGrafana -and -not $ShouldGrantExplicitGrafanaAdmin)) {
                if ($DeploymentAccount.user.type -eq 'user') {
                    $ImportPrincipalId = (& $script:AzureCli ad signed-in-user show --query id --output tsv).Trim()
                    $ImportPrincipalType = 'User'
                }
                else {
                    $ImportPrincipalId = (& $script:AzureCli ad sp show --id $DeploymentAccount.user.name --query id --output tsv).Trim()
                    $ImportPrincipalType = 'ServicePrincipal'
                }
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ImportPrincipalId)) {
                    throw 'Unable to resolve the deploying principal object ID.'
                }
            }

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
        }

        if (-not $SkipGrafanaImport) {
            & $ImportScript `
                -TenantId $TenantId `
                -GrafanaResourceId $GrafanaResourceId `
                -WorkspaceResourceId $LogAnalyticsWorkspaceResourceId `
                -NativeVmResourceId $NativeVmResourceId
            if ($LASTEXITCODE -ne 0) {
                throw 'The Grafana dashboard import failed.'
            }
        }

        Write-Information "Workbook deployed: $($Deployment.properties.outputs.workbookResourceId.value)" -InformationAction Continue
        Write-Information "Azure Managed Grafana: $GrafanaResourceId" -InformationAction Continue
    }
    catch {
        Write-Error -ErrorAction Continue "Solution deployment failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution