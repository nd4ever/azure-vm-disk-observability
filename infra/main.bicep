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

@description('The deterministic resource name of the Azure Monitor Workbook.')
param workbookName string = guid(resourceGroup().id, workbookDisplayName)

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
var workbookData = replace(workbookWithWorkspace, '__NATIVE_VM_RESOURCE_ID__', nativeVmResourceId)

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

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
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

@description('The resource ID of the deployed Azure Monitor Workbook.')
output workbookResourceId string = workbook.id

@description('The resource ID of the Azure Managed Grafana instance when created by this deployment.')
output grafanaResourceId string? = grafana.?id

@description('The principal ID of the Azure Managed Grafana identity when created by this deployment.')
output grafanaPrincipalId string? = grafana.?identity.?principalId
