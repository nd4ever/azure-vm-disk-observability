metadata name = 'Default No-Charge Guest Metrics Policy'
metadata description = 'Creates and assigns a management-group initiative that installs Azure Monitor Agent and associates a regional data collection rule with supported Windows and Linux virtual machines.'

targetScope = 'managementGroup'

@description('The resource name of the custom policy initiative.')
@minLength(1)
@maxLength(64)
param initiativeName string = 'free-guest-metrics'

@description('The display name of the custom policy initiative.')
@minLength(1)
@maxLength(128)
param initiativeDisplayName string = 'Default no-charge Azure Monitor guest metrics'

@description('The resource name of the management-group policy assignment.')
@minLength(1)
@maxLength(24)
param assignmentName string = 'free-guest-metrics'

@description('The display name of the management-group policy assignment.')
@minLength(1)
@maxLength(128)
param assignmentDisplayName string = 'Default no-charge guest metrics'

@description('The resource ID of the regional data collection rule that collects default OpenTelemetry guest metrics.')
param dcrResourceId string

@description('The Azure region for the assignment identity, built-in policy parameters, and resource selector.')
param location string = 'centralus'

@description('Whether the built-in policies deploy resources or are disabled.')
@allowed([
  'DeployIfNotExists'
  'Disabled'
])
param effect string = 'DeployIfNotExists'

@description('Whether the built-in policies apply only to Azure Monitor Agent-supported operating system images.')
param scopeToSupportedImages bool = true

@description('Additional Windows virtual machine image resource IDs to include.')
param listOfWindowsImageIdToInclude array = []

@description('Additional Linux virtual machine image resource IDs to include.')
param listOfLinuxImageIdToInclude array = []

var normalizedLocation = toLower(replace(location, ' ', ''))
var windowsAmaPolicyDefinitionId = 'ca817e41-e85a-4783-bc7f-dc532d36235e'
var linuxAmaPolicyDefinitionId = 'a4034bc6-ae50-406d-bf76-50f4ee5a7811'
var windowsDcrAssociationPolicyDefinitionId = '244efd75-0d92-453c-b9a3-7d73ca36ed52'
var linuxDcrAssociationPolicyDefinitionId = '58e891b9-ce13-4ac3-86e4-ac3e1f20cb07'
var policyDefinitionReferenceIds = [
  'windowsAmaSystemIdentity'
  'linuxAmaSystemIdentity'
  'windowsDcrAssociation'
  'linuxDcrAssociation'
]
var requiredRoleDefinitionIds = [
  tenantResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
  tenantResourceId('Microsoft.Authorization/roleDefinitions', '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
  tenantResourceId('Microsoft.Authorization/roleDefinitions', '92aaf0da-9dab-42b6-94a3-d43ce8d16293')
]

resource initiative 'Microsoft.Authorization/policySetDefinitions@2026-06-01' = {
  name: initiativeName
  properties: {
    displayName: initiativeDisplayName
    description: 'Installs Azure Monitor Agent with system-assigned identity and associates the regional default OpenTelemetry guest-metrics data collection rule.'
    metadata: {
      category: 'Monitoring'
    }
    parameters: {
      dcrResourceId: {
        type: 'String'
        metadata: {
          assignPermissions: true
          description: 'Resource ID of the data collection rule to associate with supported virtual machines.'
          displayName: 'Data Collection Rule Resource ID'
          strongType: 'Microsoft.Insights/dataCollectionRules'
        }
      }
      effect: {
        type: 'String'
        allowedValues: [
          'DeployIfNotExists'
          'Disabled'
        ]
        defaultValue: 'DeployIfNotExists'
        metadata: {
          description: 'Enable or disable deployment by the initiative.'
          displayName: 'Effect'
        }
      }
      listOfApplicableLocations: {
        type: 'Array'
        metadata: {
          description: 'Locations where the built-in policies apply.'
          displayName: 'Applicable Locations'
          strongType: 'location'
        }
      }
      listOfWindowsImageIdToInclude: {
        type: 'Array'
        defaultValue: []
        metadata: {
          description: 'Additional Windows virtual machine image resource IDs to include.'
          displayName: 'Additional Windows Virtual Machine Images'
        }
      }
      listOfLinuxImageIdToInclude: {
        type: 'Array'
        defaultValue: []
        metadata: {
          description: 'Additional Linux virtual machine image resource IDs to include.'
          displayName: 'Additional Linux Virtual Machine Images'
        }
      }
      scopeToSupportedImages: {
        type: 'Boolean'
        defaultValue: true
        metadata: {
          description: 'Apply only to Azure Monitor Agent-supported operating system images.'
          displayName: 'Scope to Supported Images'
        }
      }
    }
    policyDefinitions: [
      {
        policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', windowsAmaPolicyDefinitionId)
        policyDefinitionReferenceId: policyDefinitionReferenceIds[0]
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
          listOfApplicableLocations: {
            value: '[parameters(\'listOfApplicableLocations\')]'
          }
          listOfWindowsImageIdToInclude: {
            value: '[parameters(\'listOfWindowsImageIdToInclude\')]'
          }
          scopeToSupportedImages: {
            value: '[parameters(\'scopeToSupportedImages\')]'
          }
        }
      }
      {
        policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', linuxAmaPolicyDefinitionId)
        policyDefinitionReferenceId: policyDefinitionReferenceIds[1]
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
          listOfLinuxImageIdToInclude: {
            value: '[parameters(\'listOfLinuxImageIdToInclude\')]'
          }
          scopeToSupportedImages: {
            value: '[parameters(\'scopeToSupportedImages\')]'
          }
        }
      }
      {
        policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', windowsDcrAssociationPolicyDefinitionId)
        policyDefinitionReferenceId: policyDefinitionReferenceIds[2]
        parameters: {
          dcrResourceId: {
            value: '[parameters(\'dcrResourceId\')]'
          }
          effect: {
            value: '[parameters(\'effect\')]'
          }
          listOfApplicableLocations: {
            value: '[parameters(\'listOfApplicableLocations\')]'
          }
          listOfWindowsImageIdToInclude: {
            value: '[parameters(\'listOfWindowsImageIdToInclude\')]'
          }
          resourceType: {
            value: 'Microsoft.Insights/dataCollectionRules'
          }
          scopeToSupportedImages: {
            value: '[parameters(\'scopeToSupportedImages\')]'
          }
        }
      }
      {
        policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', linuxDcrAssociationPolicyDefinitionId)
        policyDefinitionReferenceId: policyDefinitionReferenceIds[3]
        parameters: {
          dcrResourceId: {
            value: '[parameters(\'dcrResourceId\')]'
          }
          effect: {
            value: '[parameters(\'effect\')]'
          }
          listOfLinuxImageIdToInclude: {
            value: '[parameters(\'listOfLinuxImageIdToInclude\')]'
          }
          resourceType: {
            value: 'Microsoft.Insights/dataCollectionRules'
          }
          scopeToSupportedImages: {
            value: '[parameters(\'scopeToSupportedImages\')]'
          }
        }
      }
    ]
    policyType: 'Custom'
  }
}

resource policyAssignment 'Microsoft.Authorization/policyAssignments@2026-06-01' = {
  name: assignmentName
  location: normalizedLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Onboards supported virtual machines to default no-charge Azure Monitor OpenTelemetry guest metrics.'
    displayName: assignmentDisplayName
    enforcementMode: 'Default'
    metadata: {
      category: 'Monitoring'
    }
    parameters: {
      dcrResourceId: {
        value: dcrResourceId
      }
      effect: {
        value: effect
      }
      listOfApplicableLocations: {
        value: [
          normalizedLocation
        ]
      }
      listOfWindowsImageIdToInclude: {
        value: listOfWindowsImageIdToInclude
      }
      listOfLinuxImageIdToInclude: {
        value: listOfLinuxImageIdToInclude
      }
      scopeToSupportedImages: {
        value: scopeToSupportedImages
      }
    }
    policyDefinitionId: initiative.id
    resourceSelectors: [
      {
        name: 'guestMetricsLocationSelector'
        selectors: [
          {
            in: [
              normalizedLocation
            ]
            kind: 'resourceLocation'
          }
        ]
      }
    ]
  }
}

resource policyRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleDefinitionId in requiredRoleDefinitionIds: {
    name: guid(managementGroup().id, policyAssignment.name, roleDefinitionId)
    properties: {
      principalId: policyAssignment.identity.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: roleDefinitionId
    }
  }
]

@description('The resource ID of the custom policy initiative.')
output initiativeResourceId string = initiative.id

@description('The resource ID of the management-group policy assignment.')
output assignmentResourceId string = policyAssignment.id

@description('The principal ID of the policy assignment system-assigned identity.')
output assignmentPrincipalId string = policyAssignment.identity.principalId

@description('The policy definition reference IDs that require remediation tasks.')
output policyDefinitionReferenceIds array = policyDefinitionReferenceIds

@description('The role definition IDs granted to the policy assignment identity at management-group scope.')
output requiredRoleDefinitionIds array = requiredRoleDefinitionIds
