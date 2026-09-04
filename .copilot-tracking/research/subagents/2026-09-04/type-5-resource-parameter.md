---
title: Azure Workbook Type 5 Resource Parameter Research
description: Evidence for single-select resource parameters with default resource IDs
author: GitHub Copilot
ms.date: 2026-09-04
ms.topic: reference
---

## Research questions

* Find authoritative, shipped Microsoft Azure Monitor Workbook examples for a type 5 resource parameter with `multiSelect: false` and a default resource ID.
* Determine whether a literal Azure Resource Graph scope in `crossComponentResources` must be a raw subscription GUID or `/subscriptions/<guid>`.
* Determine whether a type 6 Subscription parameter is required or only a dynamic way to supply the same scope value.
* Verify that query-backed type 5 resource parameters support `multiSelect: false`.
* Prefer examples targeting `microsoft.compute/virtualmachines`, including cross-subscription behavior where available.
* Determine whether `value` must be a string or an array for single-select resource parameters.
* Determine whether `typeSettings.resourceTypeFilter` is sufficient.
* Identify required subscription and allowed-resource settings.
* Explain why a deployed string resource ID can appear unset in the Azure portal.

## Local comparison point

The local workbook defines `VirtualMachines` as a required, single-select type 5
parameter. Its deployed `value` is a scalar VM ARM ID, and its only value-source
setting is this filter:

```json
{
  "name": "VirtualMachines",
  "type": 5,
  "isRequired": true,
  "multiSelect": false,
  "typeSettings": {
    "resourceTypeFilter": {
      "microsoft.compute/virtualmachines": true
    }
  },
  "value": "__NATIVE_VM_RESOURCE_ID__"
}
```

The deployment replaces the placeholder with a full ARM ID. The picker has no
Azure Resource Graph query, static JSON data, or concrete VM workbook context.
The workbook-level `fallbackResourceIds` contains only `Azure Monitor`.

## Authoritative evidence

The [Microsoft Learn resource parameter documentation](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-resources)
defines type 5 as the resource picker. It documents three ways to populate the
picker: resources in the workbook context, static JSON, and Azure Resource Graph.
The resource type filter restricts resources from the applicable source; the
documentation does not state that the filter discovers arbitrary resources.

The [Microsoft Learn parameter documentation](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-parameters)
documents query-backed dropdown parameters. A query supplies `value`, `label`,
and optional `selected` fields. The `selected` field identifies default rows in
the query result.

The [Microsoft Learn data source documentation](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-data-sources)
describes Azure Resource Graph as a workbook data source for querying resources
across subscriptions.

The [Microsoft Application Insights Workbooks repository](https://github.com/microsoft/Application-Insights-Workbooks)
states that it contains workbook templates shown in the Azure Monitor gallery.
The examples below are pinned to gallery commit `13dd934`.

The repository's [workbook schema](https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/master/schema/workbook.json)
defines top-level `defaultResourceIds` and `fallbackResourceIds` as arrays. It
describes them as workbook resource context restored or used when no explicit
context is passed. These fields are distinct from a parameter's `value`.

## Shipped examples

### Explicit single-select resource parameter

The shipped [App Failures workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/13dd934/Workbooks/App%20Services%20-%20App%20Metrics/App%20Failures/App%20Failures.workbook)
uses explicit `multiSelect: false` and a scalar `value`. `value::1` is a special
workbook-context resource option, not a concrete ARM ID.

```json
{
  "name": "Apps",
  "type": 5,
  "isRequired": true,
  "multiSelect": false,
  "typeSettings": {
    "resourceTypeFilter": {
      "microsoft.insights/components": true
    },
    "additionalResourceOptions": [
      "value::1"
    ]
  },
  "value": "value::1"
}
```

### Single-select virtual machine parameter

The shipped [Virtual machine details workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/13dd934/Workbooks/Virtual%20Machines/Virtual%20machine%20details/Virtual%20machine%20details.workbook)
uses a scalar value for a type 5 VM picker. It omits `multiSelect`, which makes
the picker single-select, and binds to the first workbook-context resource.

```json
{
  "name": "SelectedVM",
  "type": 5,
  "value": "value::1",
  "isHiddenWhenLocked": true,
  "typeSettings": {
    "resourceTypeFilter": {
      "microsoft.compute/virtualmachines": true
    },
    "additionalResourceOptions": [
      "value::1"
    ]
  }
}
```

The shipped [Performance Analysis for a Single VM workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/13dd934/Workbooks/Virtual%20Machines%20-%20Performance%20Analysis/Performance%20Analysis%20for%20a%20Single%20VM/Performance%20Analysis%20for%20a%20Single%20VM.workbook)
uses the same scalar `value::1` pattern while allowing either an Azure VM or an
Azure Arc-enabled server:

```json
{
  "name": "Computer",
  "type": 5,
  "isRequired": true,
  "value": "value::1",
  "typeSettings": {
    "resourceTypeFilter": {
      "microsoft.compute/virtualmachines": true,
      "microsoft.hybridcompute/machines": true
    },
    "additionalResourceOptions": [
      "value::1"
    ]
  }
}
```

### Multi-select virtual machine parameter

The shipped [Virtual Machines Key Metrics workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/13dd934/Workbooks/Virtual%20Machines/Key%20Metrics/Key%20Metrics.workbook)
uses an array when `multiSelect` is true:

```json
{
  "name": "VirtualMachines",
  "type": 5,
  "multiSelect": true,
  "value": [
    "value::all"
  ],
  "typeSettings": {
    "resourceTypeFilter": {
      "microsoft.compute/virtualmachines": true
    },
    "additionalResourceOptions": [
      "value::all"
    ]
  }
}
```

### Cross-subscription virtual machine parameter

The shipped [At-scale Key Metrics workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/13dd934/Workbooks/Virtual%20Machines/At-scale%20Metrics/Key%20Metrics.workbook)
uses Azure Resource Graph to enumerate VMs. A type 6 subscription parameter
queries available subscription IDs. The VM parameter scopes its ARG query with
`crossComponentResources: ["{Subscription}"]` and returns explicit resource
picker rows.

```json
{
  "name": "Subscription",
  "type": 6,
  "isRequired": true,
  "multiSelect": true,
  "query": "where type =~ 'microsoft.compute/virtualmachines' | summarize Count = count() by subscriptionId | project value = subscriptionId, label = subscriptionId",
  "crossComponentResources": [
    "value::all"
  ],
  "queryType": 1,
  "resourceType": "microsoft.resourcegraph/resources"
}
```

```json
{
  "name": "VirtualMachines",
  "type": 5,
  "isRequired": true,
  "multiSelect": true,
  "query": "where type =~ 'microsoft.compute/virtualmachines' | project value = id, label = id, selected = true",
  "crossComponentResources": [
    "{Subscription}"
  ],
  "typeSettings": {
    "resourceTypeFilter": {
      "microsoft.compute/virtualmachines": true
    },
    "additionalResourceOptions": [
      "value::all"
    ],
    "showDefault": false
  },
  "queryType": 1,
  "resourceType": "microsoft.resourcegraph/resources"
}
```

The queries above are shortened to show the contract. In the shipped source,
the subscription query marks its highest-count row selected, and the VM query
marks its first 25 rows selected.

### Literal subscription scope and query-backed single-select picker

The shipped [Traffic Analytics Your Environment workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Traffic%20Analytics/VNet/YourEnvUnifiedTest)
passes a fixed subscription scope directly to an ARG-backed type 5 resource
parameter. The literal is a subscription ARM ID, not a bare GUID:

```json
{
  "type": 5,
  "queryType": 1,
  "resourceType": "microsoft.resourcegraph/resources",
  "crossComponentResources": [
    "/subscriptions/00000000-0000-0000-0000-000000000000"
  ]
}
```

The shipped [Workspace Usage workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Monitor%20-%20Workspaces/Workspace%20Usage/Workspace%20Usage.workbook)
shows the equivalent dynamic form. Its type 6 parameter explicitly projects
`value = strcat("/subscriptions/", subscriptionId)` and the query-backed type 5
parameter consumes `crossComponentResources: ["{Subscription}"]`. The type 5
parameter omits `multiSelect`, so it is single-select and its `value` is scalar.

Together, these examples distinguish serialization from parameter expansion:
`{Subscription}` can be used when a type 6 parameter produces the scope, but a
literal scope must already be the full `/subscriptions/<guid>` ARM ID.

## Findings

* A single-select type 5 parameter uses a scalar string. An array is the shipped
  representation for a multi-select value. Changing the local ARM ID to a
  one-element array would conflict with the single-select pattern.
* `resourceTypeFilter` is a filter, not a value enumerator. It is sufficient when
  the intended resource already exists in the workbook's resource context. It
  does not make a separately injected ARM ID an available picker item.
* The closest shipped single-VM pattern uses `value: "value::1"`, adds
  `value::1` to `additionalResourceOptions`, and relies on the workbook being
  opened with the VM as its resource context.
* A query-backed picker needs an Azure Resource Graph query, `queryType: 1`,
  `resourceType: "microsoft.resourcegraph/resources"`, and an ARG scope in
  `crossComponentResources`.
* Cross-subscription enumeration normally adds a type 6 subscription parameter
  and passes its value to the resource query through `crossComponentResources`.
  No subscription parameter is required for a context-bound `value::1` picker.
* A type 6 parameter is also optional for an ARG-backed picker fixed to one
  subscription. In that case, use the literal ARM ID
  `/subscriptions/<subscription-guid>` in `crossComponentResources`.
* A bare subscription GUID is not the shipped literal scope representation.
  The local parent parameter block and its child VM parameter both carry the
  failing placeholder, so both arrays must receive the full subscription ARM
  ID.
* Query-backed type 5 parameters support single selection. The shipped
  Workspace Usage example uses the default single-select behavior, while the
  parameter documentation describes multi-select as an optional setting.
* `additionalResourceOptions` exposes sentinels such as `value::1` and
  `value::all`. It is not an allowlist for ordinary ARM IDs.
* Searches of the shipped gallery found no `allowedResources` or
  `allowedResourceTypes` setting. Neither appears in the official resource
  picker documentation or gallery schema. No such setting should be added.
* No shipped gallery example was found that sets a single-select type 5
  parameter directly to a concrete VM ARM ID without also supplying that VM
  through workbook context, static JSON, or a query result.

The portal symptom is therefore most consistent with picker hydration, not a
scalar-versus-array error. The serialized string exists, but it is not present
in the picker's available item set. When the portal cannot resolve the value to
an item, the control renders it as unset. A missing resource, wrong tenant or
subscription, or insufficient read access can produce the same result because
the resource will not be returned or resolved.

## Recommendation

For a workbook deployed for one known VM, use the shipped context-bound pattern:

1. Put the concrete VM ARM ID in the workbook's `defaultResourceIds` or
   `fallbackResourceIds` array.
2. Set the single-select parameter to scalar `value: "value::1"`.
3. Include `value::1` in `typeSettings.additionalResourceOptions`.
4. Keep the `microsoft.compute/virtualmachines` resource type filter.

```json
{
  "defaultResourceIds": [
    "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Compute/virtualMachines/<vm-name>"
  ],
  "fallbackResourceIds": [
    "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Compute/virtualMachines/<vm-name>"
  ]
}
```

```json
{
  "name": "VirtualMachines",
  "type": 5,
  "isRequired": true,
  "multiSelect": false,
  "value": "value::1",
  "typeSettings": {
    "resourceTypeFilter": {
      "microsoft.compute/virtualmachines": true
    },
    "additionalResourceOptions": [
      "value::1"
    ]
  }
}
```

For a reusable or cross-subscription workbook, use an ARG-backed picker. Add a
type 6 subscription parameter, scope the VM parameter with
`crossComponentResources`, and return the desired default VM as a query row
whose `selected` value is true. Keep `multiSelect: false`; the resulting
parameter value remains a scalar ARM ID.

```kusto
where type =~ 'microsoft.compute/virtualmachines'
| project
    value = id,
    label = name,
    selected = id =~ '<default-vm-resource-id>'
```

A static `jsonData` row containing the VM ARM ID is also supported for a fixed
choice, but the context-bound pattern better matches Microsoft's shipped
single-VM workbooks. The ARG-backed pattern is preferable when users must choose
among VMs or work across subscriptions.

For the current fixed-subscription ARG design, the minimal correction is to
replace both literal scope entries with the full subscription ARM ID:

```json
"crossComponentResources": [
  "/subscriptions/<subscription-guid>"
]
```

Do not add a type 6 parameter unless the user needs to select or discover the
subscription dynamically.

## Clarifying questions

None.
