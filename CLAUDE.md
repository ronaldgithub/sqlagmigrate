# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

PowerShell tooling to migrate SQL Server databases between two Always On Availability Groups (AGs) using the **dbatools** module. It supports:

- **Full migration** (steps 1–10): removes from source AG, backs up, restores, joins destination AG, waits for sync.
- **Destination cleanup only** (`-CleanAGDestination`, steps 1–5): removes and drops databases from AG_Destination without touching the source.

## Requirements

- PowerShell with the `dbatools` module installed.
- Windows Authentication with sysadmin rights on all SQL Server nodes.
- A UNC backup path accessible from all nodes.

## Running the script

Full migration example:

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

Optional switches: `-TakeSourceOffline`, `-CleanAGDestination`, `-VerboseLogging`.

Logs are written to `.\logs\migrate-agdatabase_<timestamp>.log`.

## Code architecture

### Entry point

`migrate-agdatabase.ps1` is the only script to run directly. At startup it dot-sources `shared-functions.ps1`, initialises the log file, then:

1. Runs a one-time preflight (AG existence, backup path reachability).
2. Loops over each database name, executing steps 1–10 (or 1–5 if `-CleanAGDestination`).

### Shared functions (`shared-functions.ps1`)

Dot-sourced at the top of the main script. Provides:

- **`Write-Log`** — writes `[timestamp] [LEVEL] message` to console (coloured) and to `$script:LogFilePath`. Levels: `INF`, `WAR`, `ERR`, `VRB`.
- **`Invoke-DbaWithLog`** — wraps a scriptblock; when `$Config.Defaults.VerboseLogging` is true it captures dbatools verbose output and pipes it through `Write-Log`.
- **`Format-Elapsed`** — formats a `Stopwatch` as `HH:mm:ss`.

### Key design decisions

- **Step 7 uses raw T-SQL instead of `Restore-DbaDatabase`**: `Restore-DbaDatabase` calls `Test-DbaBackupInformation`, which refuses to restore when leftover physical files exist even with `-WithReplace`. Direct `Invoke-DbaQuery` bypasses this check.
- **`WITH MOVE` in restore**: handles differences in default data/log paths between source and destination SQL Server versions (e.g. MSSQL16 → MSSQL17). Target paths are read via `Get-DbaDefaultPath`; file names come from `Read-DbaBackupHeader`.
- **Orphaned file cleanup**: after DROP, physical files are removed over the admin share (`\\server\C$\...`) because DROP DATABASE leaves files on disk when the database was in RESTORING state or had been taken offline.
- **`$Config` hashtable**: passed implicitly through script scope; currently only holds `Defaults.VerboseLogging`. `Invoke-DbaWithLog` reads it from the caller's scope.
- **`Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`**: all unhandled errors terminate immediately; no silent failures.
