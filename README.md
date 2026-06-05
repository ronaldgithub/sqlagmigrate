# sqlagmigrate

Migrate SQL Server databases between Always On Availability Groups using [dbatools](https://dbatools.io) with automatic seeding.

> Full walkthrough: [SQL Server 2016 AG Migration](https://dbaronald.nl/sql-server-2016-ag-migration/)

## Requirements

- PowerShell with the `dbatools` module installed
- Windows Authentication with sysadmin rights on all SQL Server nodes
- A UNC backup path accessible from all nodes

## Usage

### Full migration

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

| Parameter | Description |
|---|---|
| `-DatabaseName` | One or more database names to migrate |
| `-AG_Source` | Name of the source Availability Group |
| `-AG_Destination` | Name of the destination Availability Group |
| `-Node1_source` | Primary node of AG_Source |
| `-Node2_source` | Secondary node of AG_Source |
| `-Node1_destination` | Primary node of AG_Destination |
| `-Node2_destination` | Secondary node of AG_Destination |
| `-BackupPath` | UNC path accessible from all nodes |
| `-TakeSourceOffline` | After backup: remove database from AG_Source and set offline |
| `-CleanAGDestination` | Only clean AG_Destination (steps 1–5), skip backup/restore |
| `-VerboseLogging` | Capture and log dbatools verbose output |

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

Logs are written to `.\logs\migrate-agdatabase_<timestamp>.log`.

## Author

Ronald de Groot - Apeldoorn (NLD)
ronald.de.groot@opendata.nl
