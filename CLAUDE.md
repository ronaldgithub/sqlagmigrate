# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

PowerShell tooling to migrate SQL Server databases between two Always On Availability Groups (AGs) using the **dbatools** module. It supports:

- **Full migration** (steps 1–10): removes from source AG, backs up, restores, joins destination AG, waits for sync.
- **Destination cleanup only** (`-CleanAGDestination`, steps 1–5): removes and drops databases from AG_Destination without touching the source.
- **Parallel migration**: `migrate-agdatabasesinparallel.ps1` runs one background job per database for concurrent migrations.

## Requirements

- PowerShell 5.1 (Windows PowerShell — no PS 7+ features like `ForEach-Object -Parallel` or null-coalescing `??`).
- The `dbatools` module installed.
- Windows Authentication with sysadmin rights on all SQL Server nodes.
- A UNC backup path accessible from all nodes with sufficient free disk space (at least N × average database size when running in parallel).

## Running the scripts

Sequential migration:

```powershell
.\Migrate-AgDatabase.ps1 `
    -DatabaseName      "DB1", "DB2" `
    -AG_Source         "agsql" `
    -AG_Destination    "agsql2" `
    -Node1_source      "sql2" `
    -Node2_source      "sql3" `
    -Node1_destination "sql4" `
    -Node2_destination "sql5" `
    -BackupPath        "\\SQL4\temp"
```

Parallel migration (one background job per database):

```powershell
.\migrate-agdatabasesinparallel.ps1 `
    -DatabaseName      "DB1", "DB2", "DB3" `
    -MaxParallel       2 `
    -AG_Source         "agsql" `
    -AG_Destination    "agsql2" `
    -Node1_source      "sql2" `
    -Node2_source      "sql3" `
    -Node1_destination "sql4" `
    -Node2_destination "sql5" `
    -BackupPath        "\\SQL4\temp"
```

Optional switches for both scripts: `-TakeSourceOffline`, `-CleanAGDestination`, `-VerboseLogging`.

Logs are written to `.\logs\migrate-agdatabase_<timestamp>_<PID>.log` (PID suffix prevents filename collisions when jobs start within the same second).

## Code architecture

### Entry points

- **`migrate-agdatabase.ps1`** — sequential migration; processes all databases in a foreach loop.
- **`migrate-agdatabasesinparallel.ps1`** — parallel wrapper; spawns one `Start-Job` per database, each calling `migrate-agdatabase.ps1` with a single `-DatabaseName`. Accepts the same parameters plus `-MaxParallel [int]` (0 = all databases at once).

`migrate-agdatabase.ps1` dot-sources `shared-functions.ps1` at startup, initialises the log file, then:

1. Runs a one-time preflight (AG existence, backup path reachability).
2. Loops over each database name, executing steps 1–10 (or 1–5 if `-CleanAGDestination`).

### Shared functions (`shared-functions.ps1`)

Dot-sourced at the top of the main script. Provides:

- **`Write-Log`** — writes `[timestamp] [LEVEL] message` to console (coloured) and to `$script:LogFilePath`. Levels: `INF`, `WAR`, `ERR`, `VRB`. Uses `Write-Host` (stream 6) so output is captured by `$job.ChildJobs[0].Information` in background jobs.
- **`Invoke-DbaWithLog`** — wraps a scriptblock; when `$Config.Defaults.VerboseLogging` is true it captures dbatools verbose output and pipes it through `Write-Log`.
- **`Format-Elapsed`** — formats a `Stopwatch` as `HH:mm:ss`.

### Parallel wrapper details (`migrate-agdatabasesinparallel.ps1`)

- Uses `[System.Collections.Generic.Queue[string]]` to throttle job start when `-MaxParallel` is set.
- Streams job output live to console by polling `$job.ChildJobs[0].Information` with an index tracker (`$infoIndex`) — `Receive-Job` is not used because it drains the stream and prevents re-reading.
- `@()` forces arrays on `Where-Object` results before `.Count` to avoid `Set-StrictMode -Version Latest` throwing on `$null.Count`.
- Wraps each job's script call in try/catch so fatal exceptions are written via `Write-Host` (visible via `Flush-JobOutput`) before re-throwing.
- In the summary, checks both `$job.JobStateInfo.Reason` and `$job.ChildJobs[0].Error` to surface the terminating exception.

### Key design decisions

- **Step 7 uses raw T-SQL instead of `Restore-DbaDatabase`**: `Restore-DbaDatabase` calls `Test-DbaBackupInformation`, which refuses to restore when leftover physical files exist even with `-WithReplace`. Direct `Invoke-DbaQuery` bypasses this check.
- **`WITH MOVE` in restore**: handles differences in default data/log paths between source and destination SQL Server versions (e.g. MSSQL16 → MSSQL17). Target paths are read via `Get-DbaDefaultPath`; file names come from `Read-DbaBackupHeader`.
- **Orphaned file cleanup**: after DROP, physical files are removed over the admin share (`\\server\C$\...`) because DROP DATABASE leaves files on disk when the database was in RESTORING state or had been taken offline. `Remove-OrphanedDbFiles` retries up to 5 times with a 3-second sleep because SQL Server may briefly hold file handles after DROP returns. The call sites are wrapped in try/catch — on failure a WARN is logged with the paths for manual cleanup and the migration continues (the DROP itself succeeded).
- **Background jobs don't inherit network tokens**: `Start-Job` processes cannot access admin shares (`\\server\C$\...`) with the interactive user's credentials. The non-fatal try/catch on file cleanup handles this; manual deletion is the fallback.
- **`$PID` in log filename**: prevents log file collisions when multiple jobs start within the same second.
- **`$Config` hashtable**: passed implicitly through script scope; currently only holds `Defaults.VerboseLogging`. `Invoke-DbaWithLog` reads it from the caller's scope.
- **`Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`**: all unhandled errors terminate immediately; no silent failures.
