---
title: Copilot Workspace Instructions
description: Development and validation conventions for the VM Disk Observability demo
---

## Project status

* [x] Project requirements clarified
* [x] Project structure scaffolded
* [x] Azure Workbook and Grafana dashboard implemented
* [x] Required extensions reviewed; none are required
* [x] Bicep, JSON, and KQL validation implemented
* [x] Azure Workbook deployed
* [x] Grafana dashboard imported

## Engineering conventions

* Keep Azure resource IDs parameterized except for the explicit lab parameter file.
* Use `InsightsMetrics` and the `LogicalDisk` namespace for hybrid guest views.
* Keep native Azure VM LUN metrics separate from guest logical disk metrics.
* Run `npm run validate` after changing Bicep or dashboard JSON.
* Run `npm run validate:live` after changing KQL.
* Never commit tokens, credentials, or generated ARM templates.