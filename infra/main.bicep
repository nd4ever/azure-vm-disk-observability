metadata name = 'VM Disk Observability'
metadata description = 'Deploys a shared Azure Monitor Workbook and optionally creates an Azure Managed Grafana instance.'

targetScope = 'resourceGroup'

@description('The Azure region used to store the workbook resource.')
param location string = resourceGroup().location

@description('The resource ID of the Log Analytics workspace containing VM Insights data.')
param logAnalyticsWorkspaceResourceId string

@description('The resource ID of the native Azure VM used for per-LUN platform metric charts.')
param nativeVmResourceId string

@description('The display name of the Azure Monitor Workbook.')
param workbookDisplayName string = 'VM Disk Observability'

@description('The native Azure VM SKU size shown in the VM SKU limits panel.')
param vmSkuSize string = 'N/A'

@description('The maximum uncached IOPS published for the native Azure VM SKU.')
param vmSkuMaxUncachedIops string = 'N/A'

@description('The maximum uncached throughput in MB/s published for the native Azure VM SKU.')
param vmSkuMaxUncachedMBps string = 'N/A'

@description('The maximum cached IOPS published for the native Azure VM SKU.')
param vmSkuMaxCachedIops string = 'N/A'

@description('The maximum cached throughput in MB/s published for the native Azure VM SKU.')
param vmSkuMaxCachedMBps string = 'N/A'

@description('The deterministic resource name of the Azure Monitor Workbook.')
param workbookName string = guid(resourceGroup().id, workbookDisplayName)

@description('Whether to deploy the VM Insights Azure Monitor Workbook (platform metrics plus in-guest inventory).')
param shouldDeployWorkbook bool = true

@description('The display name of the free, Azure VM-only Azure Monitor Workbook.')
param azureVmOnlyWorkbookDisplayName string = 'Azure VM Disk SKU Limits (free)'

@description('Whether to deploy the free, Azure VM-only workbook (platform metrics only, no VM Insights).')
param shouldDeployAzureVmOnlyWorkbook bool = true

@description('The deterministic resource name of the free, Azure VM-only Azure Monitor Workbook.')
param azureVmOnlyWorkbookName string = guid(resourceGroup().id, azureVmOnlyWorkbookDisplayName)

@description('Whether to create an Azure Managed Grafana instance in the target resource group.')
param shouldDeployGrafana bool = false

@description('The name of the Azure Managed Grafana instance to create.')
@minLength(2)
@maxLength(30)
param grafanaName string = 'amg-${uniqueString(resourceGroup().id)}'

@description('Whether the Azure Managed Grafana instance is zone redundant.')
@allowed([
  'Disabled'
  'Enabled'
])
param grafanaZoneRedundancy string = 'Disabled'

var workbookTemplate = loadTextContent('../workbooks/vm-disk-observability.workbook.json')
var workbookWithWorkspace = replace(workbookTemplate, '__WORKSPACE_RESOURCE_ID__', logAnalyticsWorkspaceResourceId)
var workbookWithVm = replace(workbookWithWorkspace, '__NATIVE_VM_RESOURCE_ID__', nativeVmResourceId)
var workbookWithSize = replace(workbookWithVm, '__VM_SKU_SIZE__', vmSkuSize)
var workbookWithUncachedIops = replace(workbookWithSize, '__VM_SKU_MAX_UNCACHED_IOPS__', vmSkuMaxUncachedIops)
var workbookWithUncachedMBps = replace(workbookWithUncachedIops, '__VM_SKU_MAX_UNCACHED_MBPS__', vmSkuMaxUncachedMBps)
var workbookWithCachedIops = replace(workbookWithUncachedMBps, '__VM_SKU_MAX_CACHED_IOPS__', vmSkuMaxCachedIops)
var workbookData = replace(workbookWithCachedIops, '__VM_SKU_MAX_CACHED_MBPS__', vmSkuMaxCachedMBps)

var vmOnlyTemplate = loadTextContent('../workbooks/vm-disk-observability-vmonly.workbook.json')
var vmOnlyWithVm = replace(vmOnlyTemplate, '__NATIVE_VM_RESOURCE_ID__', nativeVmResourceId)
var vmOnlyWithSize = replace(vmOnlyWithVm, '__VM_SKU_SIZE__', vmSkuSize)
var vmOnlyWithUncachedIops = replace(vmOnlyWithSize, '__VM_SKU_MAX_UNCACHED_IOPS__', vmSkuMaxUncachedIops)
var vmOnlyWithUncachedMBps = replace(vmOnlyWithUncachedIops, '__VM_SKU_MAX_UNCACHED_MBPS__', vmSkuMaxUncachedMBps)
var vmOnlyWithCachedIops = replace(vmOnlyWithUncachedMBps, '__VM_SKU_MAX_CACHED_IOPS__', vmSkuMaxCachedIops)
var vmOnlyData = replace(vmOnlyWithCachedIops, '__VM_SKU_MAX_CACHED_MBPS__', vmSkuMaxCachedMBps)

resource grafana 'Microsoft.Dashboard/grafana@2024-10-01' = if (shouldDeployGrafana) {
  name: grafanaName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: grafanaZoneRedundancy
    grafanaConfigurations: {
      users: {
        viewersCanEdit: false
      }
    }
  }
  sku: {
    name: 'Standard'
  }
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = if (shouldDeployWorkbook) {
  name: workbookName
  location: location
  kind: 'shared'
  properties: {
    category: 'workbook'
    displayName: workbookDisplayName
    serializedData: workbookData
    sourceId: logAnalyticsWorkspaceResourceId
    version: '1.0'
  }
}

resource workbookVmOnly 'Microsoft.Insights/workbooks@2023-06-01' = if (shouldDeployAzureVmOnlyWorkbook) {
  name: azureVmOnlyWorkbookName
  location: location
  kind: 'shared'
  properties: {
    category: 'workbook'
    displayName: azureVmOnlyWorkbookDisplayName
    serializedData: vmOnlyData
    sourceId: 'Azure Monitor'
    version: '1.0'
  }
}

@description('The resource ID of the deployed Azure Monitor Workbook.')
output workbookResourceId string? = workbook.?id

@description('The resource ID of the free, Azure VM-only workbook when deployed.')
output azureVmOnlyWorkbookResourceId string? = workbookVmOnly.?id

@description('The resource ID of the Azure Managed Grafana instance when created by this deployment.')
output grafanaResourceId string? = grafana.?id

@description('The principal ID of the Azure Managed Grafana identity when created by this deployment.')
output grafanaPrincipalId string? = grafana.?identity.?principalId
