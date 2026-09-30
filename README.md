---
title: Azure VM Disk Observability
description: Azure Workbook and Managed Grafana demo for per-disk VM performance and capacity
ms.date: 2026-09-29
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

The deployment can also create six Azure Monitor metric alerts for the selected native
Azure VM. They notify an email Action Group when any data-disk IOPS/bandwidth or VM
cached/uncached IOPS/bandwidth consumed-percentage metric reaches 100%. Every notification
identifies the VM. Data-disk notifications also identify the affected LUN.

## Workbook editions

The deployment publishes two Azure Monitor Workbooks:

* **VM Disk Observability** (default display name `VM Disk Observability`) provides the full
  experience, including the VM Insights guest disk inventory (per-mount performance and
  filesystem capacity) and Azure Arc coverage. The guest section reads from Log Analytics,
  which incurs Azure Monitor Agent and ingestion cost.
* **Azure VM Disk SKU Limits (free)** provides an **Azure VM only** edition built from
  free Azure Monitor platform metrics, Azure Resource Graph, and the default no-charge
  OpenTelemetry guest metric set in an Azure Monitor workspace. It contains the
  throttling diagnosis, consumed-percentage trends, provisioned-limit reference, and
  guest filesystem capacity, IOPS, throughput, and latency. It does not use VM Insights
  or Log Analytics ingestion. Set
  `shouldDeployAzureVmOnlyWorkbook` to `false` to skip it, or change its name with
  `azureVmOnlyWorkbookDisplayName`.

The diagnosis, trend, and provisioned-limit sections use platform metrics and Resource
Graph in both editions. The full workbook uses VM Insights for guest inventory. The free
workbook uses the default OpenTelemetry guest metrics collected by Azure Monitor Agent.

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

In Grafana the DISK indicator rolls up the worst data disk into a single threshold-colored
value; in the Workbook the DISK charts plot **one line per LUN**, so you can already see which
disk is saturating. The VM SKU indicators show cached and uncached separately, since
they are distinct VM ceilings. **These indicators show the peak over the selected time range —
the worst moment, not the current state; narrow the time range to see current activity.**

### 2. Detailed throttling trends

Time-series charts to pinpoint *when* throttling happened and *which* LUN: Data Disk
IOPS/Bandwidth consumed by LUN, VM cached vs uncached IOPS/Bandwidth, and Data Disk
Latency. Series are split by Azure data-disk LUN, not by guest drive letter. Data Disk
Latency is a preview metric that requires SCSI-attached disks and is unavailable for
NVMe-attached disks.

### 3. Provisioned limits (reference)

A live Azure Resource Graph table reports each disk's maximum IOPS and MB/s from its disk
SKU, plus the totals summed across all attached disks, scoped to the selected VM. When the
summed disk limits exceed the VM SKU maximums, the disks are over-provisioned and the VM
throttles first.

The **VM SKU maximum limits** panel resolves the selected VM's SKU size dynamically as you
switch VMs in the picker, and directs you to the VM cached and uncached consumed % charts,
which measure the selected VM's live usage against its own SKU ceilings. To read the exact
published numbers for a SKU manually, run
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

### 5. Default OpenTelemetry native VM guest metrics

The free workbook and Grafana dashboard add Prometheus-backed guest disk views for native
Azure VMs. The capacity table uses `system.filesystem.usage`, rounds values to two decimal
places, and identifies capacity as GB and utilization as a percentage. Device-level
charts use `system.disk.operations`, `system.disk.io`, and
`system.disk.operation_time`. The charts exclude loop, optical, RAM, and floppy devices.

Microsoft documents these four metrics as part of the
[default OpenTelemetry VM metric set](https://learn.microsoft.com/azure/azure-monitor/vm/metrics-opentelemetry-guest-modify#metrics-reference),
which is collected at no additional cost. Azure Monitor Agent and a regional metrics DCR
send the `Microsoft-OtelPerfMetrics` stream to an Azure Monitor workspace. This path does
not require logs-based VM Insights.

Azure Monitor Agent is also used by the separate logs-based VM Insights path. If that path
is enabled, data sent to the `InsightsMetrics` or `Perf` tables has normal Log Analytics
ingestion and retention charges. VM compute, Azure Managed Grafana, alerts, and additional
or per-process OpenTelemetry metrics can also incur separate charges. See Microsoft's
[metrics-based and logs-based comparison](https://learn.microsoft.com/azure/azure-monitor/vm/metrics-opentelemetry-guest)
for the billing distinction.

Guest device names and mount points are separate from Azure data-disk LUNs, so the
workbook keeps the two views distinct.

Guest panels only show samples collected after onboarding while the VM is running and the
agent is publishing. In Grafana, select a time range that includes those samples. The
workbook capacity table requires a current sample, so it returns no results for a
deallocated VM. Start the VM or select a running VM to restore that live capacity view.

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

The free guest metrics policy is assigned at a management group selected during
deployment. Its resource selector uses the metrics DCR region, so only supported VMs in
that region are onboarded. Existing supported VMs are remediated, and future supported
VMs under the management group are onboarded automatically.

The OpenTelemetry path uses a create-or-reuse model. Supply existing Azure Monitor
workspace and DCR resource IDs to preserve shared resources. When either ID is omitted,
the deployment creates the missing resource in the solution resource group. The Azure
Monitor workspace and DCR use the selected native VM's region, even if the solution
resource group uses another region. A supplied DCR can provide the workspace ID through
its monitoring-account destination.

Each deployment covers one guest-metrics region. Run the deployment again with a VM from
each additional region and use region-specific workspace, DCR, and policy-assignment
names. The current Workbook selects one Azure Monitor workspace, while Grafana can link
more than one workspace through separate Prometheus datasources.

## Prerequisites

* PowerShell 7
* Azure CLI with an authenticated session
* Contributor access to the deployment resource group
* Permission to register `Microsoft.Monitor`, `Microsoft.Insights`, and
  `Microsoft.Dashboard` in the deployment subscription
* Monitoring Contributor access to the monitored VM's resource group when deploying alerts
* User Access Administrator or Owner access at each role-assignment scope
* Resource Policy Contributor and User Access Administrator, or Owner, at the selected
  management group when deploying free guest metrics policy
* Grafana Admin or Grafana Editor access when importing into an existing instance

The unified deployment installs the Azure CLI `amg` and `resource-graph` extensions when
they are missing. It registers the required resource providers, creates or reuses the
regional Azure Monitor workspace and DCR, links the workspace to Grafana, and grants the
Grafana identity `Monitoring Data Reader`. Preinstall the extensions and preregister the
providers when the deploying principal cannot modify the local CLI or subscription.

Policy remediation enables a system-assigned identity, installs the Windows or Linux
Azure Monitor Agent, and creates the DCR association on
[supported operating systems](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-supported-operating-systems).
The DCR subscription must be a descendant of the selected management group. Unsupported
images are excluded by the Microsoft-maintained built-in policies.

The selected VM, workspace, and DCR must use the same Azure region. VMs must run before
AMA can install, configure, and publish samples. Remediation does not start deallocated
VMs. Their control-plane associations can exist while data remains unavailable until the
VM runs.

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
* Email address for disk and VM SKU saturation alerts
* An existing Managed Grafana instance or a name for a new instance

The management group name is prompted only when `-FreeGuestMetrics` is supplied. Azure
Monitor workspace and DCR IDs are optional reuse inputs. When omitted, both resources are
created with deterministic names in the deployment resource group and the selected VM's
region.

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
| `LogAnalyticsWorkspaceResourceId` | `/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.OperationalInsights/workspaces/<workspace>` | Required for `VMInsights` and `Grafana`                                     |
| `AzureMonitorWorkspaceResourceId` | `/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.Monitor/accounts/<workspace>` | Optional reuse input; created when omitted                                  |
| `AzureMonitorWorkspaceName`     | Azure Monitor workspace name                                                          | Optional; defaults to `amw-vm-disk-observability` when created              |
| `FreeGuestMetricsDcrResourceId` | `/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.Insights/dataCollectionRules/<dcr>` | Optional reuse input; created when omitted                                  |
| `FreeGuestMetricsDcrName`       | Data collection rule name                                                             | Optional; defaults to `dcr-vm-disk-observability` when created              |
| `GuestMetricsLocation`          | Azure region name, such as `centralus`                                                 | Optional; defaults to the selected native VM region                         |
| `ManagementGroupName`           | Management group name, such as `contoso-platform`                                      | Prompted when deploying `FreeGuestMetrics`                                  |
| `FreeGuestMetricsAssignmentName` | Management-group policy assignment name                                               | Optional; defaults to `free-guest-metrics`; use a unique name per region    |
| `FreeGuestMetricsAssignmentDisplayName` | Management-group policy assignment display name                               | Optional; use a region-specific display name for additional regions         |
| `NativeVmResourceId`            | `/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.Compute/virtualMachines/<vm>` | Required                                                                   |
| `AlertEmailAddress`             | Email address                                                                         | Required when deploying the `Alerts` artifact                              |
| `GrafanaResourceId`             | Full resource ID of an existing `Microsoft.Dashboard/grafana` resource                | Optional; selects an existing instance directly                            |
| `GrafanaName`                   | Existing or new Managed Grafana resource name                                          | Optional; used to find or create an instance                               |
| `WorkbookDisplayName`           | Azure Monitor Workbook display name                                                   | Optional; defaults to `VM Disk Observability`                               |
| `GrafanaAdminPrincipalId`       | Microsoft Entra object ID for a user or service principal                             | Optional; defaults to the deploying principal for a new Grafana instance   |
| `GrafanaAdminPrincipalType`     | `User` or `ServicePrincipal`                                                           | Required when `GrafanaAdminPrincipalId` is supplied                         |
| `SkipRoleAssignments`           | PowerShell switch                                                                     | Optional; skips deploying-principal and Grafana RBAC grants                 |
| `SkipGrafanaImport`             | PowerShell switch                                                                     | Optional; deploys Azure resources without importing the Grafana dashboard   |
| `Grafana`                       | PowerShell switch                                                                     | Optional; artifact selector for the Grafana dashboard                       |
| `VMInsights`                    | PowerShell switch                                                                     | Optional; artifact selector for the VM Insights workbook                    |
| `Free`                          | PowerShell switch                                                                     | Optional; artifact selector for the free, Azure VM-only workbook            |
| `Alerts`                        | PowerShell switch                                                                     | Optional; artifact selector for the email Action Group and metric alerts    |
| `FreeGuestMetrics`              | PowerShell switch                                                                     | Optional; artifact selector for management-group policy onboarding          |
| `SkipPolicyRemediation`         | PowerShell switch                                                                     | Optional; deploys policy without starting remediation tasks                 |

Use `-Grafana`, `-VMInsights`, `-Free`, `-Alerts`, and `-FreeGuestMetrics` to choose which
artifacts deploy. When none are supplied, Grafana, both workbooks, and alerts deploy.
Management-group policy deployment is always opt-in through `-FreeGuestMetrics`. Supply
any combination to deploy only those artifacts, for example
`./scripts/Deploy-Solution.ps1 -Alerts -AlertEmailAddress ops@example.com` or
`-Free -FreeGuestMetrics`. `-Free`, `-Alerts`, and `-FreeGuestMetrics` do not require a
Log Analytics workspace.

Selecting `Grafana`, `Free`, or `FreeGuestMetrics` activates the regional
OpenTelemetry prerequisite path. The deployment creates any missing Azure Monitor
workspace or DCR, validates the four disk counters and monitoring-account destination,
and reads both resources back after deployment. `FreeGuestMetrics` additionally deploys
the management-group policy and remediation tasks. Policy deployment remains opt-in
because its identity receives roles across the selected management group.

If neither Grafana parameter is supplied, the script displays instances in the
deployment subscription and prompts you to select one or create a new instance. If
multiple instances match `GrafanaName`, supply `GrafanaResourceId` to disambiguate.

The workbook-only command uses `TenantId`, `SubscriptionId`, `ResourceGroupName`,
`LogAnalyticsWorkspaceResourceId`, `AzureMonitorWorkspaceResourceId`, and
`NativeVmResourceId`. Its optional `DeploymentName` defaults to
`vm-disk-observability`, its optional `WorkbookDisplayName` defaults to
`VM Disk Observability`, and supplying `AlertEmailAddress` also deploys the alerts. Pass
the same display name used at deployment to update an existing workbook in place. The
standalone Grafana import uses `TenantId`, `GrafanaResourceId`, `WorkspaceResourceId`,
`AzureMonitorWorkspaceResourceId`, and `NativeVmResourceId`; `DashboardFile` and
`DashboardTitle` are optional.

Unless role assignments are skipped, the command grants the deploying principal Log
Analytics Reader on the Log Analytics workspace, Monitoring Reader on the native VM, and
Monitoring Data Reader on the Azure Monitor workspace. These roles provide Workbook query
access for the selected resources. The principal still needs Reader access to any other
subscriptions that should appear through Azure Resource Graph.

The Grafana managed identity receives Monitoring Reader over the Log Analytics workspace
and native VM, plus Monitoring Data Reader over the Azure Monitor workspace. The command
links that workspace to Grafana and verifies the workspace-specific Prometheus datasource
before importing. The importing user or service principal receives Grafana Editor on the
selected instance. When the command creates an instance, it grants Grafana Admin to that
principal by default. The role-assignment steps require User Access Administrator or Owner
permissions.

### Free guest metrics policy

Deploy only the management-group policy with:

```powershell
npm run deploy:free-policy
```

The command prompts for the management group name when it is not supplied as a parameter.
The unified deployment creates the regional Azure Monitor workspace and DCR when reuse
IDs are omitted, then passes the effective DCR to the policy script. The standalone
`deploy:free-policy` command still requires an existing DCR ID. It validates and displays
the management group and child subscriptions before deployment. The policy assignment
uses a system-assigned identity and a resource selector derived from the DCR region. An
explicit `Location` override must match the DCR.

The custom initiative references Microsoft-maintained built-in policies to install Azure
Monitor Agent on supported Windows and Linux VMs and associate the regional metrics DCR.
The script verifies that the DCR supports both operating systems and includes the four
guest disk metrics used by the dashboards. When the free workbook and policy are deployed
together, it also verifies that the DCR sends metrics to the selected Azure Monitor
workspace.

The generated DCR collects the complete default VM metric set at a 60-second interval:
uptime, CPU, memory, network, disk, and filesystem metrics. The dashboards use only the
four disk and filesystem counters listed earlier. Additional regions require another
deployment with a VM in that region and distinct resource and policy-assignment names.

Each run creates uniquely named remediation tasks in every descendant subscription. This
allows later reruns to discover newly noncompliant VMs without deleting successful or
failed historical tasks. Remediation does not start deallocated VMs. A deallocated VM
becomes associated and starts publishing only after it runs again.

> [!WARNING]
> The policy identity receives Virtual Machine Contributor, Monitoring Contributor, and
> Log Analytics Contributor at the management-group scope. These roles inherit to every
> child subscription. Review the selected management group before approving deployment.

The policy assignment and collection of the default OpenTelemetry guest metric set have
no direct additional charge. AMA is installed automatically where required. VM compute,
Azure Managed Grafana, alerts, additional or per-process OpenTelemetry metrics, and
logs-based VM Insights data sent to Log Analytics retain their normal charges.

#### Remove the free guest metrics policy

Capture the policy identity before deleting the assignment:

```powershell
$ManagementGroupName = '<management-group>'
$ManagementGroupScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"
$AssignmentName = 'free-guest-metrics'
$PrincipalId = az policy assignment show `
  --name $AssignmentName `
  --scope $ManagementGroupScope `
  --query identity.principalId `
  --output tsv
```

Delete remediations whose names start with `free-guest-metrics-` in each descendant
subscription. Then remove the three management-group role assignments before deleting
the assignment and initiative:

```powershell
foreach ($RoleName in @(
    'Virtual Machine Contributor'
    'Monitoring Contributor'
    'Log Analytics Contributor'
  )) {
  az role assignment delete `
    --assignee-object-id $PrincipalId `
    --role $RoleName `
    --scope $ManagementGroupScope
}

az policy assignment delete `
  --name $AssignmentName `
  --scope $ManagementGroupScope

az policy set-definition delete `
  --name free-guest-metrics `
  --management-group $ManagementGroupName
```

Delete only DCR associations created by this policy if telemetry must be removed. Preserve
pre-existing AMA extensions, paid VM Insights associations, and unrelated DCR
associations.

If the unified deployment created dedicated prerequisite resources, remove the Grafana
workspace integration before deleting them:

```powershell
az grafana integration monitor delete `
  --resource-group <grafana-resource-group> `
  --name <grafana-name> `
  --monitor-resource-group-name <monitor-resource-group> `
  --monitor-name <monitor-workspace-name> `
  --monitor-subscription-id <monitor-subscription-id>
```

Delete `dcr-vm-disk-observability` and `amw-vm-disk-observability` only after confirming
that no other VM associations, dashboards, or recording rules use them. Preserve any
workspace or DCR supplied through reuse parameters.

### Disk and VM SKU alerts

The deployment creates these six metric alert rules:

| Scope | Azure Monitor metric | Condition |
|-------|----------------------|-----------|
| Data disks | Data Disk IOPS Consumed Percentage | Any attached data disk reaches 100% of its provisioned IOPS limit |
| Data disks | Data Disk Bandwidth Consumed Percentage | Any attached data disk reaches 100% of its provisioned bandwidth limit |
| VM SKU | VM Cached IOPS Consumed Percentage | The VM reaches 100% of its cached IOPS limit |
| VM SKU | VM Uncached IOPS Consumed Percentage | The VM reaches 100% of its uncached IOPS limit |
| VM SKU | VM Cached Bandwidth Consumed Percentage | The VM reaches 100% of its cached bandwidth limit |
| VM SKU | VM Uncached Bandwidth Consumed Percentage | The VM reaches 100% of its uncached bandwidth limit |

The alerts evaluate every 15 minutes over a 15-minute window and use the **Maximum**
aggregation with a static `GreaterThanOrEqual 100` threshold. Each data-disk rule selects
every value of the `LUN` metric dimension and maintains a separate alert time series for
each LUN. The common alert schema identifies the VM in the target resource fields and the
affected LUN in `alertContext.condition.allOf[].dimensions`. If multiple disks saturate,
Azure can send one notification per affected LUN.

Platform metrics do not expose the guest drive letter. The notification can identify LUN
`0`, for example, but it cannot reliably add `D:` without a separate guest inventory and
mapping step. Use the Workbook or Grafana guest inventory for drive-letter context. The
mapping is not always one-to-one for striped volumes, LVM, storage spaces, or multipath
configurations.

Cached and uncached VM SKU ceilings use separate alerts so either ceiling can trigger
without requiring both to be saturated. Alerts are stateful and have automatic mitigation
enabled. Azure sends one fired notification for an alert time series, keeps it active
while the condition remains true. Azure resolves a stateful metric alert after the
condition is clear for three consecutive evaluations, so a resolved notification normally
arrives 45 to 60 minutes after the final 100% sample. The Action Group uses the Azure
Monitor common alert schema.

The Action Group and six metric alerts are deployed to the monitored VM's resource group,
including when that VM is in a different subscription from the workbook. Azure Monitor
metric alert pricing applies.

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

The import command discovers the configured Azure Monitor datasource, requires the
Prometheus datasource for the supplied Azure Monitor workspace, and derives subscription,
resource group, VM name, and region values from the supplied resource IDs. The current
CLI principal must have Grafana Admin or Grafana Editor access. The import fails when the
workspace-specific Prometheus datasource is unavailable instead of publishing a dashboard
with an empty guest filesystem panel. Use the unified deployment to create the workspace
link and required `Monitoring Data Reader` assignment before import.

You can also import
[grafana/vm-disk-observability.dashboard.json](grafana/vm-disk-observability.dashboard.json)
from the Grafana portal after replacing the placeholder values.

## Data interpretation

Guest and platform metrics describe different layers:

| View | Scope | Disk key | Arc support |
|---|---|---|---|
| VM Insights guest metrics | Filesystem and operating system | Mount or drive letter | Yes |
| Default OpenTelemetry guest metrics | Filesystem and operating system | Device and mount point | No |
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
| `infra/`     | Workbook, Grafana, alerts, and policy Bicep       |
| `workbooks/` | Azure Workbook serialized definition              |
| `grafana/`   | Parameterized Grafana dashboard                   |
| `queries/`   | Reusable KQL validated against VM Insights        |
| `scripts/`   | Validation, deployment, and import automation     |

## References

* [Azure VM disk metrics](https://learn.microsoft.com/azure/virtual-machines/disks-metrics)
* [Azure Monitor Workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview)
* [Query Prometheus metrics from Azure Workbooks](https://learn.microsoft.com/azure/azure-monitor/essentials/prometheus-workbooks)
* [Azure Managed Grafana](https://learn.microsoft.com/azure/managed-grafana/overview)
* [Azure Policy remediation](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources)
* [VM Insights performance](https://learn.microsoft.com/azure/azure-monitor/vm/vminsights-performance)