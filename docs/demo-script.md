# Demo script: VM disk throttling observability

A follow-along script for demonstrating the three dashboards to a customer, with talking
points and the pros and cons of each option. Total run time is about 20-25 minutes.

## The story you are telling

> "When a VM has a disk performance problem, the hardest question to answer quickly is:
> *am I hitting the limit of a single disk, or the aggregate limit of the whole VM?*
> These dashboards answer that at a glance, and they show it three different ways so you
> can pick the one that fits your estate and your budget."

Everything is built on one core idea: **two different ceilings**.

* **Per-disk SKU ceiling** - each managed disk (for example a P30) has its own provisioned
  IOPS and MB/s limit.
* **VM SKU ceiling** - the VM series (for example Standard_B2ls_v2) has an aggregate IOPS and
  MB/s limit across *all* of its disks combined.

You can be throttled by either one. The dashboards compare the live consumed percentage
against both ceilings so the answer is obvious.

## Before the meeting (setup checklist)

* [ ] Open all three artifacts in separate browser tabs (links in the [Appendix](#appendix-links-and-references)).
* [ ] Pick a VM you know was busy. A good reference VM is one that runs nested
  virtualization (for example, a boot storm can drive its data disks to 100% while the VM SKU
  stays low) -
  the perfect "single disk is the bottleneck" example.
* [ ] Set the time range to **Last 2 days** so the throttling event is visible.
* [ ] Do a hard refresh (Ctrl+F5) on each tab so nothing is stale.
* [ ] Have this script and the [comparison table](#side-by-side-comparison) on a second screen.

## Framing (say this first, ~1 minute)

1. "Disk throttling shows up as latency, timeouts, or slow apps - but the metric that
   *proves* it is **consumed percentage**. At or above 95% for five minutes is throttling."
2. "There are two places you can hit a limit. We measure both, side by side."
3. "I'll show you three ways to surface this: an Azure Managed Grafana dashboard, an Azure
   Monitor Workbook that also pulls in-guest detail, and a second Workbook that uses only the
   free built-in platform metrics. Same core diagnosis, three different trade-offs."

---

## Part 1 - Grafana dashboard (~7 minutes)

**What it is:** An Azure Managed Grafana dashboard driven by free Azure platform metrics for
the diagnosis, with optional in-guest inventory from VM Insights at the bottom.

### Walkthrough

1. **Selectors (top).** "Grafana uses native cascading pickers: choose a **Subscription**,
   then **Resource group**, then the **Native Azure VM**. It works across every subscription
   you can see." Select your reference VM.
2. **Throttling diagnosis band (start here).** Point at the four colored tiles.
   * "DISK - IOPS and DISK - Bandwidth are both **red at 100%**. An individual data disk is
     pinned at its own SKU limit."
   * "VM SKU - IOPS and VM SKU - Bandwidth are **green (0-32%)**. The VM as a whole has plenty
     of headroom."
   * **Verdict:** "So this is a *single-disk* limit, not a VM limit. The fix is to resize or
     upgrade that disk, not the VM."
3. **How to read this.** Read the green/orange/red rule (80% / 95%) out loud once.
4. **Detailed throttling trends.** "The tiles show the worst moment; these per-LUN charts show
   *when* it happened and *which* LUN. They use Maximum, so the spikes reach 100% exactly when
   the disk was throttled." Hover a spike to show the LUN.
5. **Provisioned limits + used-by-LUN.** "Here are the provisioned ceilings per disk and the
   VM total, next to the actual peak used - so you can see how much headroom each disk has."
6. **Hybrid inventory (bottom).** "This section is powered by VM Insights and shows in-guest
   logical-disk detail - free space, guest latency, per-mount IOPS. It also covers **Azure Arc**
   machines, not just Azure VMs."

### Grafana talking points

* **Pro:** Best for NOC/wall-board use, real-time refresh, and teams already standardized on
  Grafana. Cascading pickers scale to a large fleet.
* **Pro:** One pane for **both** Azure VMs and **Arc-enabled** servers (hybrid / on-prem).
* **Con:** Requires an Azure Managed Grafana instance (a small hourly cost) and someone to run it.
* **Con:** The in-guest section depends on VM Insights (see cost note in Part 2).

---

## Part 2 - Azure Workbook with VM Insights (~6 minutes)

**What it is:** An Azure Monitor Workbook living inside the Azure portal. Same throttling
diagnosis as Grafana, plus a rich in-guest inventory from VM Insights (Log Analytics).

### Walkthrough

1. "This is the exact same diagnosis, but it lives **in the Azure portal** - no extra tooling
   to stand up." Open the workbook and select your reference VM in the **Native Azure VM**
   picker (it queries across all your subscriptions).
2. **Throttling diagnosis charts.** "Same story: DISK IOPS/Bandwidth ride up to **100%** (one
   line per LUN, so you see which disk), while VM SKU stays low. These use Maximum, so they
   match the numbers you would pull from the metrics API."
3. **Detailed trends, provisioned limits, used-by-LUN, read vs write.** Scroll through briefly -
   "same building blocks as Grafana."
4. **Hybrid inventory (VM Insights).** "This is the differentiator versus the free workbook:
   in-guest logical-disk data - filesystem free space, guest-measured latency and IOPS per
   mount - for both Azure and Arc machines. That comes from the VM Insights agent."

### VM Insights workbook talking points

* **Pro:** Nothing to deploy beyond the workbook itself - it is native to Azure Monitor and
  shareable by a portal link or pinned to a dashboard.
* **Pro:** Deepest visibility - platform limits **and** in-guest filesystem/latency detail,
  across Azure and Arc.
* **Con:** The in-guest detail needs **VM Insights** (the Azure Monitor Agent + a Log Analytics
  workspace). That means agent rollout and **ingestion/retention cost** per GB.
* **Con:** Portal workbooks are interactive one-VM-at-a-time views, not a live wall board.

---

## Part 3 - Azure Workbook with free built-in metrics only (~5 minutes)

**What it is:** A second Workbook that is **Azure-VM-only** and uses **only the free platform
metrics**. No VM Insights, no agent, no Log Analytics, no per-GB cost.

### Walkthrough

1. "Same throttling diagnosis - DISK vs VM SKU - with **zero additional cost and nothing to
   install**." Select your reference VM.
2. **Throttling diagnosis + trends + provisioned limits + used + read/write.** "Everything you
   need to answer *disk limit or VM limit* is here, straight from the platform metrics every
   Azure VM already emits for free."
3. **What is intentionally missing.** "There is no in-guest section - no filesystem free space,
   no guest latency, no Arc machines. If you do not need that, you do not pay for it."

### Free workbook talking points

* **Pro:** **$0 extra** - platform metrics are free and always on. No agent, no workspace.
* **Pro:** Fastest to adopt - deploy the workbook and you are done. Great default for most fleets.
* **Con:** Azure VMs only (no Arc / on-prem).
* **Con:** No in-guest detail - you see the disk is saturated, but not which file system or
  process inside the guest is driving it.

---

## Side-by-side comparison

| Capability | Grafana | Workbook + VM Insights | Workbook (free) |
|---|---|---|---|
| Disk vs VM SKU diagnosis | Yes | Yes | Yes |
| Per-LUN trends and provisioned limits | Yes | Yes | Yes |
| In-guest filesystem / latency detail | Yes (VM Insights) | Yes (VM Insights) | No |
| Azure Arc / on-prem servers | Yes | Yes | No (Azure VMs only) |
| Data source | Platform metrics + VM Insights | Platform metrics + VM Insights | Platform metrics only |
| Extra cost | Managed Grafana instance (+ VM Insights for guest) | VM Insights ingestion/retention | None |
| Agent required | For guest section only | For guest section only | No |
| Best for | NOC / wall boards, hybrid fleets | Deep portal-native investigation | Low-cost, broad, fast rollout |
| Real-time auto refresh | Yes | Manual refresh | Manual refresh |

## How to help them choose (closing, ~2 minutes)

* "**Just want the cheapest answer to *disk or VM limit* across your Azure fleet?** Start with
  the **free workbook** - $0 and nothing to install."
* "**Need in-guest detail - free space, guest latency - or you have Arc / on-prem servers?**
  Use the **VM Insights workbook** and accept the Log Analytics ingestion cost."
* "**Run a NOC, want a live wall board, or already standardized on Grafana?** Use the
  **Grafana dashboard**; add VM Insights if you want the guest section."

They are not mutually exclusive - many customers run the **free workbook** as the always-on
default and turn on **VM Insights** selectively for the VMs they are actively troubleshooting.

## Likely questions and quick answers

* **"Does the diagnosis itself cost anything?"** No. The disk-vs-VM consumed-percentage metrics
  are free Azure platform metrics on every VM. Cost only enters with VM Insights (guest detail)
  or the Grafana instance.
* **"Why does a tile say 100% but the trend line looked lower before?"** The tile is the peak
  (Maximum) over the whole window; a trend using Average smooths short spikes. Our trend charts
  are set to Maximum so they agree with the tiles.
* **"Why is the VM at 100% when it looked idle?"** The tiles show the *peak in the window* - the
  worst moment, not the current state. Narrow the time range to see current activity.
* **"Can I get alerted?"** Yes - create an Azure Monitor metric alert on the same
  Data Disk / VM Cached / VM Uncached Consumed Percentage metrics at your chosen threshold.
* **"NVMe vs SCSI?"** Data Disk Latency is a preview metric that requires SCSI-attached disks;
  it is unavailable for NVMe-attached disks. The IOPS/bandwidth diagnosis works for both.

## Appendix: links and references

Fill in your environment's values before the meeting (keep real URLs and resource names out
of source control).

* **Grafana dashboard:** `https://<your-grafana-instance>.grafana.azure.com/d/sku-limit-disk-capacity-dashboard`
* **Workbook (VM Insights):** Azure portal &rarr; Monitor &rarr; Workbooks &rarr;
  **SKU Limit Disk Capacity Dashboard** (in your monitoring resource group).
* **Workbook (free, Azure VM only):** Azure portal &rarr; Monitor &rarr; Workbooks &rarr;
  **Azure VM Disk SKU Limits (free)** (in your monitoring resource group).
* **Reference demo VM:** any VM you know was busy - ideally one with several data disks whose
  disk IOPS/bandwidth peaked near 100% while the VM SKU stayed low.
* **How to read the data:** see the project [README](../README.md).
