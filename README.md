---
title: Azure VM Disk Observability
description: Azure Workbook and Managed Grafana demo for per-disk VM performance and capacity
ms.date: 2026-09-04
ms.topic: tutorial
---

## Overview

This project demonstrates per-disk observability in two Azure-native experiences:

* Azure Monitor Workbook in the Azure portal
* Azure Managed Grafana

Both experiences show a sortable per-disk table plus filtered time-series charts for
total IOPS, total throughput, latency, and filesystem capacity. Hybrid views work for
Azure Arc connected servers and native Azure VMs monitored by VM Insights.

Native Azure VM panels use platform metrics split by LUN for:

* Data Disk IOPS Consumed Percentage
* Data Disk Bandwidth Consumed Percentage
* Data Disk Latency

The consumed-percentage panels compare total activity with provisioned disk limits,
so operators do not need to combine read and write charts manually.

## Deployment model

The repository contains no tenant, subscription, resource group, workspace, VM, or
Grafana identifiers. The deployment command prompts for environment-specific values
and uses the current Azure CLI context as the default tenant and subscription.

The command searches the selected subscription for Azure Managed Grafana instances.
You can select an existing instance or create a new Standard instance in the deployment
resource group. A new instance uses a system-assigned managed identity and public
network access.

## Prerequisites

* PowerShell 7
* Azure CLI with an authenticated session
* Azure Managed Grafana CLI extension (`az extension add --name amg`)
* Contributor access to the deployment resource group
* User Access Administrator or Owner access at each role-assignment scope
* Grafana Admin or Grafana Editor access when importing into an existing instance

Creating the resource group or registering the `Microsoft.Dashboard` resource provider
also requires the corresponding subscription-level permissions. Pre-create the resource
group and register the provider when the deploying principal has resource-group-only
Contributor access.

VM Insights must send `LogicalDisk` records to `InsightsMetrics`. The live validation
command verifies that the project queries execute against the selected workspace.

## Validate

Run structural validation:

```powershell
npm run validate
```

Run structural validation and execute every KQL file against a prompted Log Analytics
workspace customer ID:

```powershell
npm run validate:live
```

## Deploy the solution

Deploy the workbook and Grafana dashboard:

```powershell
npm run deploy
```

The command prompts for:

* Microsoft Entra tenant and deployment subscription
* Deployment resource group and its Azure region when the group does not exist
* Log Analytics workspace resource ID
* Native Azure VM resource ID for LUN platform metrics
* An existing Managed Grafana instance or a name for a new instance

Unless role assignments are skipped, the command grants the new Grafana instance's
managed identity Monitoring Reader over the workspace and native VM. It grants the
importing user or service principal Grafana Editor on the selected instance. When it
creates an instance, it grants Grafana Admin to that principal by default. The
role-assignment steps require User Access Administrator or Owner permissions.

Open Azure Monitor, select **Workbooks**, and open **VM Disk Observability**. Use the
machine and mount parameters to reduce visual noise. Use the native VM picker to
change the resource shown in the LUN charts.

To deploy only the workbook, run the following command and enter the mandatory values
when PowerShell prompts for them:

```powershell
npm run deploy:workbook
```

## Import the Grafana dashboard

The unified deployment imports the dashboard automatically. To import it separately,
run the following command and enter the Grafana, workspace, and VM resource IDs when
PowerShell prompts for them:

```powershell
npm run import:grafana
```

The import command discovers the configured Azure Monitor datasource and derives
subscription, resource group, VM name, and region values from the supplied resource
IDs. The current CLI principal must have Grafana Admin or Grafana Editor access.

You can also import
[grafana/vm-disk-observability.dashboard.json](grafana/vm-disk-observability.dashboard.json)
from the Grafana portal after replacing the placeholder values.

## Data interpretation

Guest and platform metrics describe different layers:

| View | Scope | Disk key | Arc support |
|---|---|---|---|
| VM Insights guest metrics | Filesystem and operating system | Mount or drive letter | Yes |
| Azure VM platform metrics | Managed disk attachment and host path | LUN | No |

The workbook and Grafana dashboard keep those sections separate. A guest mount cannot
always be mapped reliably to an Azure LUN, especially for Arc servers, striped volumes,
LVM, storage spaces, and multipath configurations.

`Data Disk Latency` is a preview platform metric. It is available for SCSI-attached
disks and is not available for NVMe-attached disks. Guest latency is also absent on
some machines in the current workspace; empty latency values indicate missing source
telemetry rather than zero latency.

## Customer demo flow

1. Start with the numeric inventory table and sort by peak IOPS or peak latency.
2. Select one machine and mount to show readable IOPS, throughput, and latency trends.
3. Show filesystem used percentage for capacity planning.
4. Select a native Azure VM and compare IOPS consumed percentage across LUNs.
5. Repeat the workflow in Grafana and ask which interaction model the customer prefers.

## Project layout

| Path         | Purpose                                           |
|--------------|---------------------------------------------------|
| `infra/`     | Workbook and optional Managed Grafana Bicep       |
| `workbooks/` | Azure Workbook serialized definition              |
| `grafana/`   | Parameterized Grafana dashboard                   |
| `queries/`   | Reusable KQL validated against VM Insights        |
| `scripts/`   | Validation, deployment, and import automation     |

## References

* [Azure VM disk metrics](https://learn.microsoft.com/azure/virtual-machines/disks-metrics)
* [Azure Monitor Workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview)
* [Azure Managed Grafana](https://learn.microsoft.com/azure/managed-grafana/overview)
* [VM Insights performance](https://learn.microsoft.com/azure/azure-monitor/vm/vminsights-performance)