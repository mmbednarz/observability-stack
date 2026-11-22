# “SQL Server – WEBCON” dashboard

**Folder:** `sql` · **Default time range:** last 1 h · **Refresh:** every 30 s

**Purpose:** whether the database is the cause of slow WEBCON – load, what SQL Server is waiting for, locks, disk, memory, database size – plus a list of slow queries sent by WEBCON.

**Filter:** *Databases* (per-database charts). Requires SQL metrics (`-SqlServer` during installation).

> The dashboard describes the **entire SQL Server instance**. If other systems also run on the instance, their load is visible here as well.

---

## Overview

| Tile | What it shows | Thresholds / when to react |
|---|---|---|
| **Batches /s** | Batch Requests/sec – general measure of load | reference point |
| **Connections** | active connections to the selected databases | sudden increase = connection leak or traffic spike |
| **Page life expectancy** | how many seconds a data page stays in memory | 🔴 < 300 s · 🟠 300–1000 s · 🟢 > 1000 s; low = not enough memory, many reads from disk |
| **SQL Server memory** | memory used by SQL Server | |
| **Blocked sessions** | requests currently waiting for a lock held by another session | 🟢 0 · 🟠 ≥ 1 · 🔴 ≥ 5 |
| **Deadlocks (range)** | deadlocks in the time range | each deadlock = one WEBCON transaction was rolled back (an error for the user) |

---

## Load

| Panel | How to read it |
|---|---|
| **Batches and compilations /s** | compilations > 10 % of batches = plans are not reused (ad hoc queries, e.g. from SQL rules without parameters) |
| **Transactions /s by database** | which database (content, configuration, attachments) is the most loaded |
| **Active requests** | `running` / `runnable` / `suspended` requests; many `suspended` = waiting for a resource (locks, disk) |

---

## Waits – what SQL Server is waiting for

The best way to determine **what** is limiting the database:

| Panel | How to read it |
|---|---|
| **Wait time by category** | wait seconds per second (sum across all threads); **the dominant category = the bottleneck** |
| **Average time per wait** | long individual waits with few events = sporadic but severe problems |
| **CPU pressure (signal wait %)** | consistently > 20–25 % = not enough CPU for SQL Server |

| Category | Meaning | What to check |
|---|---|---|
| `Locks` | waiting for locks held by other transactions | *Locks* row, long path transitions / actions |
| `Data I/O`, `Log I/O`, `Other I/O` | waiting for the disk (data files / transaction log) | *Database I/O* row, disk latency on the [host](06-windows-host.md) |
| `CPU` | CPU shortage (waiting for a scheduler / worker thread) | CPU pressure, heavy reports |
| `Parallelism` | parallel query execution (threads of one query waiting for each other) | heavy reports / queries without indexes; MAXDOP and cost threshold for parallelism |
| `Memory` | waiting for a memory grant | *Memory* row |
| `Latch`, `Buffer latch` | contention for internal structures / pages in memory | often tempdb or “hot” tables (e.g. bulk inserts) |
| `Network / client` | the client (WEBCON) receives results slowly | large query results, e.g. reports without paging |
| `OS calls`, `Other` | remaining waits | usually background; relevant only when they dominate |

---

## Locks

| Panel | How to read it |
|---|---|
| **Blocked sessions** | number of blocked requests and the longest current wait (right axis); sampled every 30 s – short blocking may not be visible |
| **Lock waits /s** | lock requests that had to wait / timed out |
| **Deadlocks /min** | deadlock details: Extended Events session `system_health` in SSMS |

Locks in WEBCON usually result from long transactions: path transitions with a slow action (an API call within the transaction), bulk operations, heavy reports.

---

## Database I/O

| Panel | How to read it |
|---|---|
| **Average I/O latency by database** | good values: data files < 20 ms, log < 5 ms |
| **I/O operations /s by database**, **I/O throughput by database** | which database puts the most load on the disk |

---

## Memory

| Panel | How to read it |
|---|---|
| **SQL Server memory** | committed consistently below target = SQL has headroom; committed = target and low PLE = not enough memory |
| **Page life expectancy** | sharp drops = the buffer pool is being flushed by large scans (e.g. a report without an index) |
| **Memory grants and buffer cache** | *Memory Grants Pending* > 0 = queries are waiting for memory; buffer cache hits should be close to 100 % |

---

## Database size

| Panel | How to read it |
|---|---|
| **Data size**, **Log size** | size of database files |
| **Log usage** | 🟠 > 70 % · 🔴 > 90 %; consistently high with the FULL recovery model = no transaction log backups |
| **Database growth** | growth rate – space planning, effect of archiving |
| **Log growths** | frequent autogrow slows down writes – larger growth increment / initial size |

---

## Slow SQL queries (WEBCON traces)

A table of SQL queries longer than the threshold (1 s by default) sent by WEBCON: database, **full query text**, Trace ID. Click the Trace ID → you will see in which WEBCON operation (form opening, report, data source, action) the query was executed and who triggered it.

This combines the DBA and application developer views: the DBA sees the query, the application developer sees which form / data source generates it.
