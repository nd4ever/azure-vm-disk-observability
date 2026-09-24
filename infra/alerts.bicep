metadata name = 'VM Disk Saturation Alerts'
metadata description = 'Deploys metric alerts and an email Action Group for disk and VM SKU saturation.'

targetScope = 'resourceGroup'

@description('The resource ID of the Azure VM monitored by the metric alerts.')
param nativeVmResourceId string

@description('The name of the Azure VM monitored by the metric alerts.')
param nativeVmName string

@description('The email address that receives disk and VM SKU saturation notifications.')
@minLength(3)
param alertEmailAddress string

@description('The consumed-percentage value that triggers the alerts.')
@minValue(1)
@maxValue(100)
param alertThreshold int = 100

@description('The severity assigned to the metric alerts.')
@minValue(0)
@maxValue(4)
param alertSeverity int = 2

@description('The name of the Action Group used by the metric alerts.')
param actionGroupName string = 'vm-disk-observability-alerts'

var metricNamespace = 'Microsoft.Compute/virtualMachines'
var alertNamePrefix = 'vm-disk-${nativeVmName}'
var alertDefinitions = [
  {
    suffix: 'data-disk-iops-100pct'
    metricName: 'Data Disk IOPS Consumed Percentage'
    description: 'A data disk reached 100% of its provisioned IOPS limit during the fifteen-minute evaluation window.'
  }
  {
    suffix: 'data-disk-bandwidth-100pct'
    metricName: 'Data Disk Bandwidth Consumed Percentage'
    description: 'A data disk reached 100% of its provisioned bandwidth limit during the fifteen-minute evaluation window.'
  }
  {
    suffix: 'vm-cached-iops-100pct'
    metricName: 'VM Cached IOPS Consumed Percentage'
    description: 'The VM reached 100% of its cached IOPS SKU limit during the fifteen-minute evaluation window.'
  }
  {
    suffix: 'vm-uncached-iops-100pct'
    metricName: 'VM Uncached IOPS Consumed Percentage'
    description: 'The VM reached 100% of its uncached IOPS SKU limit during the fifteen-minute evaluation window.'
  }
  {
    suffix: 'vm-cached-bandwidth-100pct'
    metricName: 'VM Cached Bandwidth Consumed Percentage'
    description: 'The VM reached 100% of its cached bandwidth SKU limit during the fifteen-minute evaluation window.'
  }
  {
    suffix: 'vm-uncached-bandwidth-100pct'
    metricName: 'VM Uncached Bandwidth Consumed Percentage'
    description: 'The VM reached 100% of its uncached bandwidth SKU limit during the fifteen-minute evaluation window.'
  }
]

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    enabled: true
    groupShortName: 'vmdiskalert'
    emailReceivers: [
      {
        name: 'DiskOperations'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

resource metricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for definition in alertDefinitions: {
  name: '${alertNamePrefix}-${definition.suffix}'
  location: 'global'
  properties: {
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: replace(definition.suffix, '-', '_')
          criterionType: 'StaticThresholdCriterion'
          dimensions: []
          metricName: definition.metricName
          metricNamespace: metricNamespace
          operator: 'GreaterThanOrEqual'
          skipMetricValidation: false
          threshold: alertThreshold
          timeAggregation: 'Maximum'
        }
      ]
    }
    description: definition.description
    enabled: true
    evaluationFrequency: 'PT15M'
    scopes: [
      nativeVmResourceId
    ]
    severity: alertSeverity
    windowSize: 'PT15M'
  }
}]

@description('The resource ID of the email Action Group.')
output actionGroupResourceId string = actionGroup.id

@description('The resource IDs of the disk and VM SKU metric alerts.')
output metricAlertResourceIds array = [for index in range(0, length(alertDefinitions)): metricAlerts[index].id]
