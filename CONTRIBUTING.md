---
title: Contributing to Azure VM Disk Observability
description: Guidelines for proposing and validating changes to the project
ms.date: 2026-09-30
ms.topic: overview
---

## Ways to contribute

Contributions that improve deployment reliability, dashboard usability, documentation,
and Azure VM disk diagnostics are welcome.

Before starting a substantial change, open an issue to describe the problem and proposed
approach. This gives maintainers and other contributors a chance to align on scope.

## Development workflow

1. Fork the repository and create a focused branch.
2. Keep Azure resource IDs and environment-specific values parameterized.
3. Follow the existing Bicep, PowerShell, JSON, and KQL patterns.
4. Add or update documentation for user-visible behavior.
5. Run the validation appropriate to the change.
6. Open a pull request with a clear description and validation results.

Run structural validation after changing Bicep, PowerShell deployment logic, or dashboard
JSON:

```powershell
npm run validate
```

Run live validation after changing KQL:

```powershell
npm run validate:live
```

Live validation prompts for a Log Analytics workspace customer ID and executes every KQL
file against that workspace.

## Pull request expectations

Pull requests should:

* Address one cohesive problem
* Explain any user-visible behavior change
* Describe Azure permission, scope, or cost implications
* Include the commands used for validation
* Avoid generated ARM templates, tokens, credentials, and environment-specific identifiers

Documentation-only changes do not require project validation unless they change a command
or configuration example.

## Reporting problems

Use the repository issue templates for bugs and feature requests. Do not include tenant,
subscription, resource, customer, or credential information in an issue.

Report security vulnerabilities privately by following the
[security policy](SECURITY.md).
