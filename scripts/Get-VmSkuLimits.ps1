#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Resolves the absolute disk performance limits of a native Azure VM SKU.
.DESCRIPTION
    Reads the VM size and region, then queries the Compute resource SKUs catalog to
    return the maximum uncached and cached IOPS and throughput published for the SKU.
    Capabilities that a VM series does not publish are returned as 'N/A'.
.PARAMETER NativeVmResourceId
    Resource ID of the native Azure VM.
.PARAMETER AzureCli
    Full path to the Azure CLI executable.
.OUTPUTS
    [hashtable] Size, MaxUncachedIops, MaxUncachedMBps, MaxCachedIops, MaxCachedMBps.
#>
function Get-VmSkuLimits {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$NativeVmResourceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AzureCli
    )

    $ResourceIdParts = $NativeVmResourceId.Trim('/') -split '/'
    $SubscriptionId = $ResourceIdParts[1]

    $Vm = & $AzureCli resource show `
        --ids $NativeVmResourceId `
        --query '{location:location, size:properties.hardwareProfile.vmSize}' `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Vm.size)) {
        throw "Unable to resolve the size of native Azure VM '$NativeVmResourceId'."
    }

    $SkuUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=location eq '$($Vm.location)'"
    $Capabilities = & $AzureCli rest `
        --method get `
        --url $SkuUrl `
        --query "value[?name=='$($Vm.size)'].capabilities | [0]" `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query the Compute resource SKUs for size '$($Vm.size)'."
    }

    function Get-CapabilityValue {
        param([object]$Items, [string]$Name)
        $Match = @($Items | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
        if ($null -eq $Match) {
            return $null
        }
        return $Match.value
    }

    function Format-Iops {
        param([object]$Value)
        if ($null -eq $Value) {
            return 'N/A'
        }
        return [string][int64]$Value
    }

    function Format-MBps {
        param([object]$Value)
        if ($null -eq $Value) {
            return 'N/A'
        }
        return [string][math]::Round([int64]$Value / 1000000.0, 0)
    }

    return @{
        Size = $Vm.size
        MaxUncachedIops = Format-Iops (Get-CapabilityValue -Items $Capabilities -Name 'UncachedDiskIOPS')
        MaxUncachedMBps = Format-MBps (Get-CapabilityValue -Items $Capabilities -Name 'UncachedDiskBytesPerSecond')
        MaxCachedIops = Format-Iops (Get-CapabilityValue -Items $Capabilities -Name 'CombinedTempDiskAndCachedIOPS')
        MaxCachedMBps = Format-MBps (Get-CapabilityValue -Items $Capabilities -Name 'CombinedTempDiskAndCachedReadBytesPerSecond')
    }
}
