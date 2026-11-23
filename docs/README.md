# Documentation – Observability Stack (WEBCON)

A stack for analyzing WEBCON 2026.2+ performance: metrics, traces, and logs from the WEBCON Portal and WEBCON WorkFlow Service, SQL Server and Windows metrics, dashboards and alerts in Grafana. Everything runs as Windows services installed by a single PowerShell script.

> **Disclaimer.** A private project shared as a demonstration of monitoring capabilities. It is not a WEBCON product and is not developed, supported, or endorsed by WEBCON. No support and no warranty – use at your own risk; test the solution before using it in a production environment. Details: MIT license ([LICENSE](https://github.com/mmbednarz/observability-stack/blob/main/LICENSE)). WEBCON, Grafana, and other names are trademarks of their respective owners.

Online: <https://mmbednarz.github.io/observability-stack/> (one copy per release – version selector in the header). The same pages are in the `docs` folder of the release package for offline reading.

## Start here

| I want to… | Read |
|---|---|
| install the stack on a machine with WEBCON (dev / test) | [Quick start](installation/01-quick-start.md) |
| install the stack on a separate VM | [Remote mode](installation/04-remote-mode.md) |
| upgrade the stack or change parameters | [Upgrade](installation/05-upgrade.md) |
| remove the stack | [Uninstall](installation/06-uninstall.md) |
| something does not work | [Troubleshooting](installation/07-troubleshooting.md) |
| start using the dashboards | [Grafana in 10 minutes](user-guide/01-grafana-in-10-minutes.md), then [Scenarios](user-guide/08-scenarios.md) |
| understand an alert | [Alerts](user-guide/07-alerts.md) |

## Installation and maintenance

For the administrator / consultant installing the stack.

1. [Quick start – all-in-one](installation/01-quick-start.md)
2. [Requirements and preparation (SQL Server, ports)](installation/02-requirements-and-preparation.md)
3. [WEBCON configuration (`Set-WebconTelemetry.ps1`)](installation/03-webcon-configuration.md)
4. [Remote mode – stack on a separate machine](installation/04-remote-mode.md)
5. [Upgrade and parameter changes](installation/05-upgrade.md)
6. [Uninstall](installation/06-uninstall.md)
7. [Troubleshooting](installation/07-troubleshooting.md)
8. [Installer parameters](installation/08-installer-parameters.md)

## User guide

For people building WEBCON applications who want to understand where an application loses time and what breaks in it. No knowledge of Grafana is required.

1. [Grafana in 10 minutes](user-guide/01-grafana-in-10-minutes.md) – navigation, time range, filters, drilling down from a chart to a trace
2. [Concepts](user-guide/02-concepts.md) – metric, trace, p95; how WEBCON maps to telemetry
3. [WEBCON – Performance dashboard](user-guide/03-webcon-performance.md)
4. [WEBCON – Operations dashboard](user-guide/04-webcon-operations.md)
5. [SQL Server – WEBCON dashboard](user-guide/05-sql-server.md)
6. [Windows – Host load dashboard](user-guide/06-windows-host.md)
7. [Alerts](user-guide/07-alerts.md)
8. [Scenarios – from symptom to cause](user-guide/08-scenarios.md)
9. [WEBCON – Availability and backlog dashboard](user-guide/09-availability-and-backlog.md)
