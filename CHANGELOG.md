---
title: Changelog
description: Notable changes to Azure VM Disk Observability
ms.date: 2026-10-22
ms.topic: reference
---

## 2026-10-22

### Added

* OS Disk IOPS Consumed Percentage and OS Disk Bandwidth Consumed Percentage in the
  diagnosis panels and detailed trends for both Azure Workbook editions and Managed
  Grafana.
* Separate OS-disk and data-disk values in Grafana diagnosis tiles, with an OS-disk
  series alongside the existing per-LUN data-disk trends.
* Validation checks for OS-disk metrics, data-disk LUN splits, peak aggregation, and
  selected-VM bindings across all three dashboard templates.

### Changed

* Added a neutral null-value mapping and `No data` text to Grafana disk diagnosis tiles.
  Missing metrics do not indicate zero utilization.
* Clarified metric coverage and OS-only VM behavior in the dashboard guidance and
  [README](README.md).

### Scope

* OS-only VMs can populate the OS-disk diagnosis and trend series without attaching
  a data disk or enabling guest monitoring.
* Absolute IOPS/throughput charts, data-disk total tiles, and native disk latency
  remain data-disk-only.
* The six optional metric alerts remain data-disk and VM-SKU alerts. No OS-disk
  alerts or VM configuration changes are included.

### Verification

* `npm run validate` passed.
* Verified the saved definitions of both live Azure Workbooks and Managed Grafana.
* Confirmed OS-disk IOPS and bandwidth values through Grafana's Azure Monitor data
  source for an OS-only VM and a VM with eight data disks, preserving all eight
  data-disk LUN series.

Earlier changes are available in the
[Git history](https://github.com/nd4ever/azure-vm-disk-observability/commits/main/).
