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

Both experiences lead with a **Throttling diagnosis** band that answers one question at a
glance — *is throttling coming from a single disk's SKU limit or from the VM SKU
aggregate?* — and then provide detailed trends, provisioned-limit references, and a guest
disk inventory for context. Hybrid views work for Azure Arc connected servers and native
Azure VMs monitored by VM Insights.

## Workbook editions

The deployment publishes two Azure Monitor Workbooks:

* **VM Disk Observability** (default display name `VM Disk Observability`) — the full
  experience, including the VM Insights guest disk inventory (per-mount performance and
  filesystem capacity) and Azure Arc coverage. The guest section reads from Log Analytics,
  which incurs Azure Monitor Agent and ingestion cost.
* **Azure VM Disk SKU Limits (free)** — a cost-free, **Azure VM only** edition built
  entirely on free Azure Monitor platform metrics and Azure Resource Graph. It contains
  the throttling diagnosis, consumed-% trends, and provisioned-limit reference, but omits
  the VM Insights guest inventory and Azure Arc machines. Set
  `shouldDeployAzureVmOnlyWorkbook` to `false` to skip it, or change its name with
  `azureVmOnlyWorkbookDisplayName`.

The diagnosis, trend, and provisioned-limit sections use only free platform metrics and
Resource Graph in both editions; only the guest inventory in the full workbook uses
VM Insights.

## How to read the dashboards

Both experiences are organized top-to-bottom in the order you troubleshoot: **diagnosis
first**, then detail, then reference, then guest inventory.

### 1. Throttling diagnosis (start here)

Four indicators show the **peak consumed percentage** over the selected time range. In
Grafana they are threshold-colored tiles; in the Workbook they are peak-aggregated charts.
Read them against the **95%** line (Azure treats a metric at or above 95% for five
consecutive minutes as throttling):

| Indicator | Source metric | Meaning when high |
|-----------|---------------|-------------------|
| **DISK — IOPS** | Data Disk IOPS Consumed Percentage (worst disk) | An individual data disk is hitting its own provisioned IOPS limit |
| **DISK — Bandwidth** | Data Disk Bandwidth Consumed Percentage (worst disk) | An individual data disk is hitting its own provisioned bandwidth limit |
| **VM SKU — IOPS** | VM Cached/Uncached IOPS Consumed Percentage | The VM is hitting its aggregate IOPS limit across all disks |
| **VM SKU — Bandwidth** | VM Cached/Uncached Bandwidth Consumed Percentage | The VM is hitting its aggregate bandwidth limit across all disks |

* Grafana tiles are **green below 80%, orange at 80%, red at 95%**.
* **A DISK indicator is red/near 100%** &rarr; resize or upgrade that disk.
* **A VM SKU indicator is red/near 100%** &rarr; resize the VM.
* **Both high** &rarr; the disk is saturating and rolling up to the VM limit too.

The DISK indicators roll up the worst data disk into one value; the trend charts below
break it out per LUN. The VM SKU indicators show cached and uncached separately, since
they are distinct VM ceilings. **The tiles show the peak over the selected time range —
the worst moment, not the current state; narrow the time range to see current activity.**

### 2. Detailed throttling trends

Time-series charts to pinpoint *when* throttling happened and *which* LUN: Data Disk
IOPS/Bandwidth consumed by LUN, VM cached vs uncached IOPS/Bandwidth, and Data Disk
Latency. Series are split by Azure data-disk LUN, not by guest drive letter. Data Disk
Latency is a preview metric that requires SCSI-attached disks and is unavailable for
NVMe-attached disks.

### 3. Provisioned limits (reference)

A live Azure Resource Graph table reports each disk's maximum IOPS and MB/s from its disk
SKU, plus the totals summed across all attached disks. When the summed disk limits exceed
the VM SKU maximums, the disks are over-provisioned and the VM throttles first.

The absolute VM SKU maximums (max uncached and cached IOPS and MB/s) are resolved at
deployment time from the Compute resource SKUs catalog and shown in a **VM SKU maximum
limits** panel. Capabilities a VM series does not publish appear as `N/A`. To read the same
values manually, run
`az vm list-skus --location <region> --size <vmSize> --query "[].capabilities"`.

Next to the provisioned limits, **Data disk IOPS/throughput used by LUN (peak)** charts show
the absolute per-LUN usage (read + write) from free platform metrics, so you can compare
actual peak usage against the provisioned maximums. In Grafana, **Peak total used IOPS/throughput
(all disks)** tiles sum the read + write across every LUN at each moment and show the peak, for a
single used-vs-allowed number. Usage is per Azure data-disk LUN; because these metrics are only
emitted per LUN, the charts split by LUN rather than showing a single VM total.

A **Disk read vs write activity** section then breaks the same free metrics into separate
read and write throughput and IOPS charts per LUN, to reveal the workload's read/write mix
(averaged over the selected time range).

### 4. Hybrid disk inventory (guest)

A sortable per-disk table plus guest time-series for total IOPS, total throughput, latency,
and filesystem capacity, sourced from VM Insights `InsightsMetrics` (`LogicalDisk`). These
work for Azure Arc connected servers and native Azure VMs. Guest-side
`vm-total-iops-timeseries.kql` and `vm-total-throughput-timeseries.kql` chart the aggregate
demand across all logical disks per machine.

### Selecting a VM

* The **Grafana** dashboard uses cascading **Subscription &rarr; Resource group &rarr;
  Native Azure VM** dropdowns. Its metric panels show one VM at a time (Azure Monitor
  cannot aggregate metrics across subscriptions in a single query).
* The **Workbook** VM picker is **single-select** across all subscriptions. The metric
  charts show one VM at a time because a workbook averages a metric across multiple
  selected resources, which would dilute the per-VM peaks. The provisioned-limit tables
  still list every attached VM disk, so the fleet reference is preserved.

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

### Deployment inputs

Run `npm run deploy` for interactive prompts, or pass the same values directly to
`scripts/Deploy-Solution.ps1`. All referenced subscriptions must belong to the
specified Microsoft Entra tenant. Resource IDs must be complete Azure Resource
Manager IDs.

| Parameter                       | Expected value                                                                        | Requirement and default                                                    |
|---------------------------------|---------------------------------------------------------------------------------------|----------------------------------------------------------------------------|
| `TenantId`                      | Microsoft Entra tenant GUID                                                           | Prompted; defaults to the current Azure CLI tenant                          |
| `SubscriptionId`                | Deployment subscription GUID                                                          | Prompted; defaults to the current CLI subscription when the tenant matches  |
| `ResourceGroupName`             | Resource group name                                                                   | Prompted; defaults to `vm-disk-observability-rg`                            |
| `Location`                      | Azure region name, such as `eastus`                                                    | Required only when the resource group must be created                       |
| `LogAnalyticsWorkspaceResourceId` | `/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.OperationalInsights/workspaces/<workspace>` | Required                                                                   |
| `NativeVmResourceId`            | `/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.Compute/virtualMachines/<vm>` | Required                                                                   |
| `GrafanaResourceId`             | Full resource ID of an existing `Microsoft.Dashboard/grafana` resource                | Optional; selects an existing instance directly                            |
| `GrafanaName`                   | Existing or new Managed Grafana resource name                                          | Optional; used to find or create an instance                               |
| `WorkbookDisplayName`           | Azure Monitor Workbook display name                                                   | Optional; defaults to `VM Disk Observability`                               |
| `GrafanaAdminPrincipalId`       | Microsoft Entra object ID for a user or service principal                             | Optional; defaults to the deploying principal for a new Grafana instance   |
| `GrafanaAdminPrincipalType`     | `User` or `ServicePrincipal`                                                           | Required when `GrafanaAdminPrincipalId` is supplied                         |
| `SkipRoleAssignments`           | PowerShell switch                                                                     | Optional; skips Grafana and Monitoring Reader role assignments              |
| `SkipGrafanaImport`             | PowerShell switch                                                                     | Optional; deploys Azure resources without importing the Grafana dashboard   |

If neither Grafana parameter is supplied, the script displays instances in the
deployment subscription and prompts you to select one or create a new instance. If
multiple instances match `GrafanaName`, supply `GrafanaResourceId` to disambiguate.

The workbook-only command uses `TenantId`, `SubscriptionId`, `ResourceGroupName`,
`LogAnalyticsWorkspaceResourceId`, and `NativeVmResourceId`. Its optional
`DeploymentName` defaults to `vm-disk-observability` and its optional
`WorkbookDisplayName` defaults to `VM Disk Observability`; pass the same display name used
at deployment to update an existing workbook in place. The standalone Grafana import
uses `TenantId`, `GrafanaResourceId`, `WorkspaceResourceId`, and `NativeVmResourceId`;
`DashboardFile` and `DashboardTitle` are optional.

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