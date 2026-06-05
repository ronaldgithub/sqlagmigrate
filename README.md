# sqlagmigrate

Migrate SQL Server databases between Always On Availability Groups using [dbatools](https://dbatools.io) with automatic seeding.

> Full walkthrough: [SQL Server 2016 AG Migration](https://dbaronald.nl/sql-server-2016-ag-migration/)

## Requirements

- PowerShell with the `dbatools` module installed
- Windows Authentication with sysadmin rights on all SQL Server nodes
- A UNC backup path accessible from all nodes

## Usage

### Sequential migration

```powershell
.\Migrate-AgDatabase.ps1 `
    -DatabaseName      "Migration01", "Migration02", "Migration03" `
    -AG_Source         "agsql" `
    -AG_Destination    "agsql2" `
    -Node1_source      "sql2" `
    -Node2_source      "sql3" `
    -Node1_destination "sql4" `
    -Node2_destination "sql5" `
    -BackupPath        "\\SQL4\temp" `
    -TakeSourceOffline
```

### Parallel migration

Run multiple databases simultaneously using background jobs — each database gets its own isolated process and log file.

```powershell
.\migrate-agdatabasesinparallel.ps1 `
    -DatabaseName      "Migration01", "Migration02", "Migration03" `
    -MaxParallel       2 `
    -AG_Source         "agsql" `
    -AG_Destination    "agsql2" `
    -Node1_source      "sql2" `
    -Node2_source      "sql3" `
    -Node1_destination "sql4" `
    -Node2_destination "sql5" `
    -BackupPath        "\\SQL4\temp"
```

`-MaxParallel 0` (default) runs all databases at once. Ensure the backup path has enough free space for N concurrent backups (N × average database size).

### Clean destination AG only (no backup/restore)

```powershell
.\Migrate-AgDatabase.ps1 `
    -DatabaseName      "Migration01", "Migration02", "Migration03" `
    -AG_Destination    "agsql2" `
    -Node1_destination "sql4" `
    -Node2_destination "sql5" `
    -AG_Source         "n.v.t." `
    -Node1_source      "n.v.t." `
    -Node2_source      "n.v.t." `
    -BackupPath        "n.v.t." `
    -CleanAGDestination
```

## Parameters

| Parameter | Script | Description |
|---|---|---|
| `-DatabaseName` | both | One or more database names to migrate |
| `-AG_Source` | both | Name of the source Availability Group |
| `-AG_Destination` | both | Name of the destination Availability Group |
| `-Node1_source` | both | Primary node of AG_Source |
| `-Node2_source` | both | Secondary node of AG_Source |
| `-Node1_destination` | both | Primary node of AG_Destination |
| `-Node2_destination` | both | Secondary node of AG_Destination |
| `-BackupPath` | both | UNC path accessible from all nodes |
| `-TakeSourceOffline` | both | After backup: remove database from AG_Source and set offline |
| `-CleanAGDestination` | both | Only clean AG_Destination (steps 1–5), skip backup/restore |
| `-VerboseLogging` | both | Capture and log dbatools verbose output |
| `-MaxParallel` | parallel only | Max concurrent databases (0 = all at once) |

## What it does

The script runs up to 10 steps per database:

1. Remove from AG_Destination
2. Take offline on destination primary
3. Recover, offline, and drop on destination secondary
4. Drop on destination primary
5. Verify both destination nodes are clean
6. Take a COPY_ONLY full + log backup from AG_Source primary
7. Restore to AG_Destination primary (WITH NORECOVERY, then WITH RECOVERY)
8. Set FULL recovery model
9. Add to AG_Destination with automatic seeding
10. Wait for synchronization (up to 10 minutes)

Logs are written to `.\logs\migrate-agdatabase_<timestamp>_<PID>.log`. In parallel mode each database job gets its own log file.

## Author

Ronald de Groot - Apeldoorn (NLD)
ronald.de.groot@opendata.nl
