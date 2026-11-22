# “Windows – Host load” dashboard

**Folder:** `host` · **Default time range:** last 1 h · **Refresh:** every 30 s

**Purpose:** whether the server (WEBCON, IIS, SQL Server) is short of resources – CPU, memory, disk, network – and which process consumes them.

**Filters:** *Host* (server; in remote mode several hosts), *Processes* (processes on the charts in the *Processes* row: WEBCON, w3wp, sqlservr, stack components).

---

## Overview

| Tile | What it shows | Thresholds |
|---|---|---|
| **CPU** | average utilization of all cores | 🟢 < 70 % · 🟠 70–90 % · 🔴 > 90 % |
| **Memory used** | physical memory in use (excluding cache the system can reclaim) | 🟢 < 80 % · 🟠 80–92 % · 🔴 > 92 % |
| **Commit** | committed memory (RAM + page file) relative to the limit | 🔴 > 95 % = risk of running out of memory (OutOfMemory) |
| **Processor queue** | threads waiting for CPU | consistently > 2 × number of cores = CPU shortage |
| **Lowest free space** | lowest free space % across volumes | 🔴 < 10 % · 🟠 10–20 % · 🟢 > 20 % |
| **Uptime** | time since system start | unexpectedly short = server restart |

---

## CPU

| Panel | How to read it |
|---|---|
| **CPU utilization by mode** | `user` = applications; `privileged` = kernel, drivers, antivirus; high `interrupt` / `dpc` = hardware drivers / network |
| **Utilization per core** | one core at 100 %, the rest idle = single-threaded operation |
| **Processor queue** | like the tile, over time |
| **Context switches /s** | sharp increase under steady load = too many threads / lock contention |
| **Processes and threads** | steady growth of threads = thread leak in some application |

---

## Memory

| Panel | How to read it |
|---|---|
| **Physical memory** | *available* = free + cache (standby) that the system releases on demand |
| **Commit vs limit** | commit close to the limit = out of virtual memory – more RAM or a larger page file |
| **Paging from disk (hard faults)** | **the best signal of a RAM shortage**: sustained page reads from disk |
| **Page faults / s** | all page faults (most are “soft” and harmless) |
| **Kernel pools** | steady growth of the *nonpaged* pool = driver leak |

SQL Server by default takes almost all free memory – a high *Memory used* value on a server with SQL is normal, as long as there are no *hard faults* and SQL is limited by `max server memory`.

---

## Disks

| Panel | How to read it |
|---|---|
| **Disk usage** | % of time the volume was servicing requests; consistently ~100 % = disk saturated |
| **Read / write latency** | SSD: < 5 ms good, > 20 ms problem – **critical for SQL Server** |
| **Disk queue** | requests waiting for the disk |
| **IOPS**, **Throughput** | operations and bytes per second |
| **Free space** | free space % per volume |

---

## Network

| Panel | How to read it |
|---|---|
| **Network traffic** | bits / s received and sent; dashed line (right axis) = adapter bandwidth utilization % |
| **Errors and discarded packets** | should be 0 |
| **TCP** | established connections, resets, retransmissions (right axis, %) – > 1 % retransmissions = network problems |

---

## Processes (WEBCON, IIS, SQL Server, stack)

| Panel | How to read it |
|---|---|
| **CPU per process** | process share of total CPU (100 % = all cores) – which process loads the server |
| **Private memory (working set)** | steady growth without drops = memory leak |
| **I/O per process** | disk and network operations |
| **Handles**, **Threads** | steady growth = leak |

| Process | What it is |
|---|---|
| `w3wp` | IIS application pool (the process hosting Portal) |
| `WebCon.WorkFlow.Bootstrapper` | Portal (under IIS) and WEBCON WorkFlow Service |
| `WebCon.WorkFlow.Service`, `WebCon.WorkFlow.Module.ServiceModuleRunner` | WEBCON WorkFlow Service and its modules |
| `sqlservr` | SQL Server |
| `alloy`, `prometheus`, `loki`, `tempo`, `grafana` | observability stack – usually a few % CPU and 1–3 GB RAM in total |

---

## IIS

| Panel | How to read it |
|---|---|
| **Requests /s** | requests to IIS sites (all applications, not only Portal) |
| **Current connections** | active connections to the site |
| **Rejected async I/O requests /s** | should be 0 |

IIS panels are empty on a server without IIS (e.g. a SQL host in remote mode).
