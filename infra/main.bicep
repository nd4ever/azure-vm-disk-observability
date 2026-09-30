metadata name = 'VM Disk Observability'
metadata description = 'Deploys Azure Monitor Workbooks, guest metrics prerequisites, disk saturation alerts, and optionally Azure Managed Grafana.'

targetScope = 'resourceGroup'

@description('The Azure region used to store the workbook resource.')
param location string = resourceGroup().location

@description('The resource ID of the Log Analytics workspace containing VM Insights data.')
param logAnalyticsWorkspaceResourceId string

@description('The resource ID of the Azure Monitor workspace containing default OpenTelemetry guest metrics.')
param azureMonitorWorkspaceResourceId string

@description('Whether to create an Azure Monitor workspace for default OpenTelemetry guest metrics.')
param shouldDeployAzureMonitorWorkspace bool = false

@description('The name of the Azure Monitor workspace to create.')
param azureMonitorWorkspaceName string = 'amw-${uniqueString(resourceGroup().id)}'

@description('The region shared by the monitored VMs, Azure Monitor workspace, and guest metrics data collection rule.')
param guestMetricsLocation string = location

@description('Whether to create a data collection rule for default OpenTelemetry guest metrics.')
param shouldDeployFreeGuestMetricsDcr bool = false

@description('The name of the default OpenTelemetry guest metrics data collection rule to create.')
param freeGuestMetricsDcrName string = 'dcr-vm-guest-metrics-${uniqueString(resourceGroup().id, guestMetricsLocation)}'

@description('The resource ID of the native Azure VM used for per-LUN platform metric charts.')
param nativeVmResourceId string

@description('Whether to deploy metric alerts for disk and VM SKU saturation.')
param shouldDeployAlerts bool = false

@description('The email address that receives disk and VM SKU saturation notifications.')
param alertEmailAddress string = ''

@description('The consumed-percentage value that triggers disk and VM SKU alerts.')
@minValue(1)
@maxValue(100)
param alertThreshold int = 100

@description('The display name of the Azure Monitor Workbook.')
param workbookDisplayName string = 'VM Disk Observability'

@description('The deterministic resource name of the Azure Monitor Workbook.')
param workbookName string = guid(resourceGroup().id, workbookDisplayName)

@description('Whether to deploy the VM Insights Azure Monitor Workbook (platform metrics plus in-guest inventory).')
param shouldDeployWorkbook bool = true

@description('The display name of the no-additional-charge Azure VM-only Azure Monitor Workbook.')
param azureVmOnlyWorkbookDisplayName string = 'Azure VM Disk SKU Limits (free)'

@description('Whether to deploy the free, Azure VM-only workbook with platform and default OpenTelemetry guest metrics.')
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

resource azureMonitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = if (shouldDeployAzureMonitorWorkspace) {
  name: azureMonitorWorkspaceName
  location: guestMetricsLocation
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

var effectiveAzureMonitorWorkspaceResourceId = shouldDeployAzureMonitorWorkspace ? azureMonitorWorkspace.id : azureMonitorWorkspaceResourceId

resource freeGuestMetricsDcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = if (shouldDeployFreeGuestMetricsDcr) {
  name: freeGuestMetricsDcrName
  location: guestMetricsLocation
  properties: {
    dataSources: {
      performanceCountersOTel: [
        {
          counterSpecifiers: [
            'system.uptime'
            'system.cpu.time'
            'system.memory.usage'
            'system.network.io'
            'system.network.dropped'
            'system.network.errors'
            'system.disk.io'
            'system.disk.operations'
            'system.filesystem.usage'
            'system.disk.operation_time'
          ]
          name: 'defaultOtelPerformanceCounters'
          samplingFrequencyInSeconds: 60
          streams: [
            'Microsoft-OtelPerfMetrics'
          ]
        }
      ]
    }
    dataFlows: [
      {
        destinations: [
          'monitoringAccountDestination'
        ]
        streams: [
          'Microsoft-OtelPerfMetrics'
        ]
      }
    ]
    destinations: {
      monitoringAccounts: [
        {
          accountResourceId: effectiveAzureMonitorWorkspaceResourceId
          name: 'monitoringAccountDestination'
        }
      ]
    }
  }
}

var effectiveFreeGuestMetricsDcrResourceId = shouldDeployFreeGuestMetricsDcr ? freeGuestMetricsDcr.id : ''

var workbookTemplate = loadTextContent('../workbooks/vm-disk-observability.workbook.json')
var workbookWithWorkspace = replace(workbookTemplate, '__WORKSPACE_RESOURCE_ID__', logAnalyticsWorkspaceResourceId)
var workbookData = replace(workbookWithWorkspace, '__NATIVE_VM_RESOURCE_ID__', nativeVmResourceId)

var vmOnlyTemplate = loadTextContent('../workbooks/vm-disk-observability-vmonly.workbook.json')
var vmOnlyWithNativeVm = replace(vmOnlyTemplate, '__NATIVE_VM_RESOURCE_ID__', nativeVmResourceId)
var vmOnlyData = replace(vmOnlyWithNativeVm, '__AZURE_MONITOR_WORKSPACE_RESOURCE_ID__', effectiveAzureMonitorWorkspaceResourceId)

var nativeVmResourceIdParts = split(nativeVmResourceId, '/')
var nativeVmSubscriptionId = nativeVmResourceIdParts[2]
var nativeVmResourceGroupName = nativeVmResourceIdParts[4]
var nativeVmName = nativeVmResourceIdParts[8]

module alerts './alerts.bicep' = if (shouldDeployAlerts) {
  name: 'vm-disk-observability-alerts'
  scope: resourceGroup(nativeVmSubscriptionId, nativeVmResourceGroupName)
  params: {
    alertEmailAddress: alertEmailAddress
    alertThreshold: alertThreshold
    nativeVmName: nativeVmName
    nativeVmResourceId: nativeVmResourceId
  }
}

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
    sourceId: effectiveAzureMonitorWorkspaceResourceId
    version: '1.0'
  }
}

@description('The resource ID of the deployed Azure Monitor Workbook.')
output workbookResourceId string? = workbook.?id

@description('The resource ID of the free, Azure VM-only workbook when deployed.')
output azureVmOnlyWorkbookResourceId string? = workbookVmOnly.?id

@description('The resource ID of the alert notification Action Group when alerts are deployed.')
output alertActionGroupResourceId string? = alerts.?outputs.actionGroupResourceId

@description('The resource IDs of the disk and VM SKU metric alerts.')
output metricAlertResourceIds array = alerts.?outputs.metricAlertResourceIds ?? []

@description('The resource ID of the Azure Managed Grafana instance when created by this deployment.')
output grafanaResourceId string? = grafana.?id

@description('The principal ID of the Azure Managed Grafana identity when created by this deployment.')
output grafanaPrincipalId string? = grafana.?identity.?principalId

@description('The resource ID of the created or supplied Azure Monitor workspace.')
output effectiveAzureMonitorWorkspaceResourceId string = effectiveAzureMonitorWorkspaceResourceId

@description('The resource ID of the created guest metrics data collection rule.')
output freeGuestMetricsDcrResourceId string = effectiveFreeGuestMetricsDcrResourceId
