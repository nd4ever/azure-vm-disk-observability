---
title: Azure Workbook queryType Research
description: Microsoft-shipped evidence for workspace-backed parameter and KqlItem queries
ms.date: 2026-09-04
ms.topic: reference
---

## Research questions

* Which Microsoft-shipped workbook definitions show KQL parameter queries that
  target `Microsoft.OperationalInsights/workspaces` through
  `crossComponentResources`?
* Which Microsoft-shipped definitions show workspace-backed `KqlItem/1.0`
  queries through `crossComponentResources`?
* What do `queryType` values `0` and `1` mean, and why can omitting the property
  route a query to `Microsoft.Insights/components`?
* What are the smallest supported JSON shapes for each query form?

## Findings

* `queryType: 0` selects the Azure Monitor Logs (Analytics) provider. It does
  not identify a Log Analytics workspace by itself. Microsoft ships this value
  with both `microsoft.operationalinsights/workspaces` and
  `microsoft.insights/components`.
* `queryType: 1` selects Azure Resource Graph. Microsoft-shipped resource
  discovery parameters pair it with
  `resourceType: "microsoft.resourcegraph/resources"`.
* A query that must execute against a Log Analytics workspace should therefore
  specify all three routing fields on the query-bearing object:
  `queryType: 0`,
  `resourceType: "microsoft.operationalinsights/workspaces"`, and
  `crossComponentResources` containing one or more workspace resource IDs.
* Microsoft ships this combination on both query-backed
  `KqlParameterItem/1.0` children and `KqlItem/1.0` controls. The shipped
  `Target version` workbook also repeats `queryType` and `resourceType` on the
  containing parameter control.
* The public workbook schema describes `queryType` only as an optional integer.
  It does not publish an enum, default, inheritance rule, or requirement.
  Consequently, the numeric meanings above are established by consistent
  Microsoft-shipped serialization and the documented provider categories, not
  by a formal schema enum.
* Omitting `queryType` does not contractually mean
  `microsoft.insights/components`. More precisely, omitting explicit routing
  leaves the workbook runtime to resolve the provider and resource type from
  the containing control or workbook resource context. Logs (Analytics)
  supports both Application Insights components and Log Analytics workspaces,
  so a component-backed context can resolve to
  `microsoft.insights/components`. This fallback explanation is inferred from
  shipped definitions because Microsoft does not document the omission rule.
* For portable authored JSON, do not rely on that fallback. Set `queryType` and
  `resourceType` on every query-bearing parameter child, even when the outer
  parameter control already declares them.

## Sources

* [Azure Workbooks data sources](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-data-sources)
  documents Logs (Analytics) as covering both Application Insights resources
  and Log Analytics workspace analytics tables, and lists Azure Resource Graph
  as a separate provider.
* [Target version workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/UpdateCompliance/Target%20version/Target%20version.workbook)
  is the clearest shipped parameter example. Its `_SnapshotTime` and filter
  parameters use `queryType: 0`, the workspace resource type, and
  `crossComponentResources` targeting `{mappedWorkspace}`. Its query control
  uses the same routing combination.
* [Workspace Usage workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Monitor%20-%20Workspaces/Workspace%20Usage/Workspace%20Usage.workbook)
  uses `queryType: 1` for Resource Graph workspace discovery and
  `queryType: 0` for workspace log query controls.
* [Usage Analysis workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Monitor%20-%20Applications/Usage%20Analysis/Usage%20Analysis.workbook)
  provides the comparison case: its Application Insights log controls also use
  `queryType: 0`, but pair it with
  `resourceType: "microsoft.insights/components"`.
* [Microsoft workbook schema](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json)
  types `queryType` as an integer without an enum or documented default.

## Minimal JSON

The smallest safe parameter-query pattern puts the routing fields on the child
that owns the query. Repeating them on the outer control follows the strongest
Microsoft-shipped pattern.

```json
{
  "type": 9,
  "content": {
    "version": "KqlParameterItem/1.0",
    "queryType": 0,
    "resourceType": "microsoft.operationalinsights/workspaces",
    "parameters": [
      {
        "version": "KqlParameterItem/1.0",
        "name": "LatestHeartbeat",
        "type": 1,
        "query": "Heartbeat | summarize value=max(TimeGenerated)",
        "crossComponentResources": ["{Workspace}"],
        "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces"
      }
    ]
  }
}
```

The corresponding workspace-backed query control uses the same routing tuple.

```json
{
  "type": 3,
  "content": {
    "version": "KqlItem/1.0",
    "query": "Heartbeat | take 10",
    "queryType": 0,
    "resourceType": "microsoft.operationalinsights/workspaces",
    "crossComponentResources": ["{Workspace}"]
  }
}
```

For comparison, a Resource Graph parameter query changes both provider fields.

```json
{
  "query": "resources | where type =~ 'microsoft.operationalinsights/workspaces' | project id",
  "queryType": 1,
  "resourceType": "microsoft.resourcegraph/resources",
  "crossComponentResources": ["{Subscription}"]
}
```

## Clarifying questions

None.