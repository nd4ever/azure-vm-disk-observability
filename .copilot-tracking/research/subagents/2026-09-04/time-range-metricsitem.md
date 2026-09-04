---
title: Workbook TimeRange and MetricsItem Research
description: Authoritative evidence for Azure Monitor Workbook TimeRange parameters consumed by MetricsItem 2.0
ms.date: 2026-09-04
ms.topic: reference
---

## Research questions

* What Microsoft-authored examples or schema documentation show a `TimeRange` parameter consumed by `MetricsItem/2.0`?
* What is the expected `typeSettings.selectableValues` shape?
* May `selectableValues` entries contain only `durationMs`, or are display labels required?

## Findings

* Microsoft Learn documents that a time-range picker is named `TimeRange` and
	can be bound to workbook controls through their Time Range picker.
* The Microsoft gallery's Storage Performance workbook defines `TimeRange` as
	parameter type `4`. Its `typeSettings.selectableValues` is an array of
	objects whose only property is `durationMs`. The same workbook passes the
	parameter to several `MetricsItem/2.0` controls with
	`timeContextFromParameter: "TimeRange"` and a zero-duration placeholder in
	`timeContext`.
* The Microsoft Application Gateway workbook independently uses the same
	duration-only entries and the same `MetricsItem/2.0` binding. Display labels
	are therefore not required in each `selectableValues` entry for standard
	duration choices. Azure Workbooks derives labels such as `Last 24 hours`
	from `durationMs`; `label` on the parameter labels the picker itself.
* The public Microsoft gallery schema confirms `MetricsItem/2.0` as the metric
	control version but does not define `selectableValues`. It also names the
	metric binding property `timeRangeFromParameter`, while the checked-in
	Microsoft gallery workbooks consistently use `timeContextFromParameter`.
	The concrete gallery templates are stronger evidence for serialized runtime
	shape than this incomplete schema property.

## Sources

* [Microsoft Learn: Azure Monitor workbook time parameters](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-time)
* [Microsoft Storage Performance workbook: parameter and first metric binding](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Individual%20Storage/Performance/Performance.workbook#L57-L126)
* [Microsoft Application Gateway workbook: parameter](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Network%20Insights/ApplicationGatewayWorkbooks/Network%20Insights%20ApplicationGateways%20Detailed/NetworkInsights-ApplicationGatewayMetrics.workbook#L45-L101)
* [Microsoft Application Gateway workbook: MetricsItem binding](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Network%20Insights/ApplicationGatewayWorkbooks/Network%20Insights%20ApplicationGateways%20Detailed/NetworkInsights-ApplicationGatewayMetrics.workbook#L199-L209)
* [Microsoft workbook gallery schema: metric control](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json#L107-L144)

## Minimal valid JSON

The resource ID is structurally valid but illustrative. Replace it with a real
storage account resource ID before loading the workbook.

```json
{
	"$schema": "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json",
	"version": "Notebook/1.0",
	"items": [
		{
			"type": 9,
			"content": {
				"version": "KqlParameterItem/1.0",
				"parameters": [
					{
						"id": "00000000-0000-0000-0000-000000000001",
						"version": "KqlParameterItem/1.0",
						"name": "TimeRange",
						"label": "Time range",
						"type": 4,
						"isRequired": true,
						"value": {
							"durationMs": 86400000
						},
						"typeSettings": {
							"selectableValues": [
								{
									"durationMs": 3600000
								},
								{
									"durationMs": 86400000
								}
							],
							"allowCustom": true
						}
					}
				],
				"style": "pills",
				"queryType": 0
			},
			"name": "parameters"
		},
		{
			"type": 10,
			"content": {
				"chartId": "workbook00000000-0000-0000-0000-000000000002",
				"version": "MetricsItem/2.0",
				"size": 0,
				"chartType": 2,
				"resourceIds": [
					"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example/providers/Microsoft.Storage/storageAccounts/example"
				],
				"timeContext": {
					"durationMs": 0
				},
				"timeContextFromParameter": "TimeRange",
				"resourceType": "microsoft.storage/storageaccounts",
				"metrics": [
					{
						"namespace": "microsoft.storage/storageaccounts",
						"metric": "microsoft.storage/storageaccounts-Transaction-SuccessE2ELatency",
						"aggregation": 4
					}
				]
			},
			"name": "metric"
		}
	]
}
```

## Clarifying questions

None.