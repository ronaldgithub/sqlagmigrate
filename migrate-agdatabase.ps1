<#
.SYNOPSIS
    Migrate one or more databases from AG_Source to AG_Destination using dbatools with automatic seeding.
.NOTES
    Requires: dbatools module, sysadmin on all nodes, Windows authentication
.AUTHOR
    Ronald de Groot - Apeldoorn (NLD)
.LINK
    For questions or help, contact ronald.de.groot@opendata.nl
.LINK
    https://dbaronald.nl/sql-server-2016-ag-migration/
#>

<#
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

Of: alleen AG_Destination opschonen (geen backup/restore/join):
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
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string[]] $DatabaseName,       # One or more database names
    [Parameter(Mandatory)] [string]   $AG_Source,
    [Parameter(Mandatory)] [string]   $AG_Destination,
    [Parameter(Mandatory)] [string]   $Node1_source,       # Primary node of AG_Source
    [Parameter(Mandatory)] [string]   $Node2_source,       # Secondary node of AG_Source
    [Parameter(Mandatory)] [string]   $Node1_destination,  # Primary node of AG_Destination
    [Parameter(Mandatory)] [string]   $Node2_destination,  # Secondary node of AG_Destination
    [Parameter(Mandatory)] [string]   $BackupPath,         # UNC path accessible from all nodes
    [switch] $TakeSourceOffline,    # Na backup: database uit AG_Source verwijderen en offline zetten
    [switch] $CleanAGDestination,   # Alleen AG_Destination opschonen (stap 1-5), geen backup/restore/join
    [switch] $VerboseLogging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shared-functions.ps1')

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { $null = New-Item -ItemType Directory -Path $logDir }
$script:LogFilePath = Join-Path $logDir ("migrate-agdatabase_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$PID.log")

$Config = @{ Defaults = @{ VerboseLogging = $VerboseLogging.IsPresent } }

function Remove-OrphanedDbFiles {
    param([string[]]$Paths, [string]$ServerName)
    foreach ($localPath in $Paths) {
        $driveLetter = $localPath.Substring(0, 1)
        $restOfPath  = $localPath.Substring(2)
        $unc = "\\$ServerName\${driveLetter}`$$restOfPath"
        if (Test-Path $unc) {
            Remove-Item $unc -Force
            Write-Log "    OK: Bestand verwijderd: $unc" 'INF' Green
        } else {
            Write-Log "    WARN: Bestand niet gevonden (al weg?): $unc" 'WAR' Yellow
        }
    }
}

$DatabaseNames = $DatabaseName  # bewaar array; loop-variabele $DatabaseName (enkelvoud) wordt hergebruikt
$totalDbs      = $DatabaseNames.Count

Write-Log "=== Migrate-AgDatabase gestart ===" 'INF' Cyan
Write-Log "  Modus          : $(if ($CleanAGDestination) { 'CleanAGDestination (stap 1-5 only)' } else { 'Migratie (stap 1-10)' })" 'INF' White
Write-Log "  Databases      : $($DatabaseNames -join ', ') ($totalDbs)" 'INF' White
if (-not $CleanAGDestination) {
    Write-Log "  AG Source      : $AG_Source ($Node1_source / $Node2_source)" 'INF' White
}
Write-Log "  AG Destination : $AG_Destination ($Node1_destination / $Node2_destination)" 'INF' White
if (-not $CleanAGDestination) {
    Write-Log "  Backup path    : $BackupPath" 'INF' White
    Write-Log "  TakeSourceOffline : $($TakeSourceOffline.IsPresent)" 'INF' White
}
Write-Log "  Log            : $script:LogFilePath" 'INF' White
Write-Log "  VerboseLogging : $($Config.Defaults.VerboseLogging)" 'INF' White

$connSource  = @{ SqlInstance = $Node1_source }
$connSource2 = @{ SqlInstance = $Node2_source }
$connDest    = @{ SqlInstance = $Node1_destination }
$connDest2   = @{ SqlInstance = $Node2_destination }

# --- Preflight (eenmalig) ---

Write-Log "==> Preflight checks" 'INF' Cyan

if (-not $CleanAGDestination) {
    $agSourceInfo = Get-DbaAvailabilityGroup @connSource -AvailabilityGroup $AG_Source
    if (-not $agSourceInfo) { throw "AG '$AG_Source' not found on $Node1_source" }
}

$agDestinationInfo = Get-DbaAvailabilityGroup @connDest -AvailabilityGroup $AG_Destination
if (-not $agDestinationInfo) { throw "AG '$AG_Destination' not found on $Node1_destination" }

if (-not $CleanAGDestination) {
    if (-not (Test-Path $BackupPath)) { throw "Backup path '$BackupPath' is not accessible from this host" }
}
Write-Log "    OK: Preflight geslaagd" 'INF' Green

# --- Database loop ---

$i = 0
foreach ($DatabaseName in $DatabaseNames) {
    $i++
    Write-Host ""
    Write-Log ('=' * 60) 'INF' Cyan
    Write-Log "==> Database [$i/$totalDbs]: $DatabaseName" 'INF' Cyan
    Write-Log ('=' * 60) 'INF' Cyan

    if (-not $CleanAGDestination) {
        $sourceDb = Get-DbaAgDatabase @connSource -AvailabilityGroup $AG_Source -Database $DatabaseName
        if (-not $sourceDb) { throw "Database '$DatabaseName' is not a member of '$AG_Source' on $Node1_source" }
        Write-Log "    OK: Source database found in $AG_Source" 'INF' Green
    }

    # --- Step 1: Remove from AG_Destination (primary only) ---

    Write-Log "==> [1] Removing '$DatabaseName' from AG '$AG_Destination' on $Node1_destination" 'INF' Cyan

    $destinationAgDb = Get-DbaAgDatabase @connDest -AvailabilityGroup $AG_Destination -Database $DatabaseName
    if ($destinationAgDb) {
        $q = "ALTER AVAILABILITY GROUP [$AG_Destination] REMOVE DATABASE [$DatabaseName];"
        Write-Log "  T-SQL ($Node1_destination): $q" 'VRB' DarkGray
        Invoke-DbaQuery @connDest -Query $q
        Write-Log "    OK: Database removed from AG_Destination" 'INF' Green
    } else {
        Write-Log "    WARN: Database not found in AG_Destination - skipping REMOVE" 'WAR' Yellow
    }

    Start-Sleep -Seconds 5

    # --- Step 2: Take offline on Node1_destination (primary) ---

    Write-Log "==> [2] Taking '$DatabaseName' offline on primary $Node1_destination" 'INF' Cyan

    $dbOnPrimary = Get-DbaDatabase @connDest -Database $DatabaseName
    if ($dbOnPrimary -and $dbOnPrimary.Status -ne 'Offline') {
        $q = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE;"
        Write-Log "  T-SQL ($Node1_destination): $q" 'VRB' DarkGray
        Invoke-DbaQuery @connDest -Query $q
        Write-Log "    OK: Database set offline on $Node1_destination" 'INF' Green
    } elseif ($dbOnPrimary) {
        Write-Log "    WARN: Database already offline on $Node1_destination" 'WAR' Yellow
    } else {
        Write-Log "    WARN: Database not present on $Node1_destination - nothing to offline" 'WAR' Yellow
    }

    # --- Step 3: Recover + offline + drop on Node2_destination (secondary) ---

    Write-Log "==> [3] Cleaning up '$DatabaseName' on secondary $Node2_destination" 'INF' Cyan

    $dbOnSecondary = Get-DbaDatabase @connDest2 -Database $DatabaseName

    if ($dbOnSecondary) {
        $node2Files = @(Invoke-DbaQuery @connDest2 -Database master `
            -Query "SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID(N'$DatabaseName')" |
            Select-Object -ExpandProperty physical_name)
        $status = $dbOnSecondary.Status

        if ($status -match 'Restoring') {
            Write-Log "    Recovering database on $Node2_destination (was in RESTORING state)" 'INF' Cyan
            $q = "RESTORE DATABASE [$DatabaseName] WITH RECOVERY;"
            Write-Log "  T-SQL ($Node2_destination): $q" 'VRB' DarkGray
            Invoke-DbaQuery @connDest2 -Query $q
            Write-Log "    OK: RECOVERY applied on $Node2_destination" 'INF' Green
            Start-Sleep -Seconds 3
        }

        $dbOnSecondary = Get-DbaDatabase @connDest2 -Database $DatabaseName
        if ($dbOnSecondary -and $dbOnSecondary.Status -ne 'Offline') {
            $q = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE;"
            Write-Log "  T-SQL ($Node2_destination): $q" 'VRB' DarkGray
            Invoke-DbaQuery @connDest2 -Query $q
            Write-Log "    OK: Database set offline on $Node2_destination" 'INF' Green
        }

        $q = "DROP DATABASE [$DatabaseName];"
        Write-Log "  T-SQL ($Node2_destination): $q" 'VRB' DarkGray
        Invoke-DbaQuery @connDest2 -Query $q
        Write-Log "    OK: Database dropped on $Node2_destination" 'INF' Green

        if ($node2Files) {
            Write-Log "    Orphaned bestanden verwijderen op $Node2_destination..." 'INF' White
            Remove-OrphanedDbFiles -Paths $node2Files -ServerName $Node2_destination
        }
    } else {
        Write-Log "    WARN: Database not present on $Node2_destination - skipping" 'WAR' Yellow
    }

    # --- Step 4: Drop on Node1_destination (primary) ---

    Write-Log "==> [4] Dropping '$DatabaseName' on primary $Node1_destination" 'INF' Cyan

    $dbOnPrimary = Get-DbaDatabase @connDest -Database $DatabaseName
    if ($dbOnPrimary) {
        $node1Files = @(Invoke-DbaQuery @connDest -Database master `
            -Query "SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID(N'$DatabaseName')" |
            Select-Object -ExpandProperty physical_name)
        Invoke-DbaWithLog {
            Remove-DbaDatabase @connDest -Database $DatabaseName -Confirm:$false
        }
        Write-Log "    OK: Database dropped on $Node1_destination" 'INF' Green

        if ($node1Files) {
            Write-Log "    Orphaned bestanden verwijderen op $Node1_destination..." 'INF' White
            Remove-OrphanedDbFiles -Paths $node1Files -ServerName $Node1_destination
        }
    } else {
        Write-Log "    WARN: Database not present on $Node1_destination - skipping drop" 'WAR' Yellow
    }

    # --- Step 5: Verify both destination nodes are clean ---

    Write-Log "==> [5] Verifying clean state on AG_Destination nodes" 'INF' Cyan

    foreach ($node in @($Node1_destination, $Node2_destination)) {
        $conn = if ($node -eq $Node1_destination) { $connDest } else { $connDest2 }
        $remaining = Get-DbaDatabase @conn -Database $DatabaseName
        if ($remaining) {
            throw "Database '$DatabaseName' still exists on $node (status: $($remaining.Status)). Manual cleanup required."
        }
        Write-Log "    OK: $node is clean" 'INF' Green
    }

    if ($CleanAGDestination) {
        Write-Log "--- Cleanup klaar: $DatabaseName [$i/$totalDbs] ---" 'INF' Green
        continue
    }

    # --- Step 6: Backup from AG_Source primary ---

    Write-Log "==> [6] Backing up '$DatabaseName' from AG_Source primary $Node1_source" 'INF' Cyan

    $timestamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupFile    = Join-Path $BackupPath "$DatabaseName`_migrate_$timestamp.bak"
    $logBackupFile = Join-Path $BackupPath "$DatabaseName`_migrate_$timestamp`_log.bak"

    Write-Log "  Full backup naar: $backupFile" 'VRB' DarkGray
    $backup = Backup-DbaDatabase @connSource `
        -Database       $DatabaseName `
        -FilePath       $backupFile `
        -Type           Full `
        -CopyOnly `
        -CompressBackup

    if (-not $backup) { throw "Full backup failed" }
    Write-Log "    OK: Full backup: $([math]::Round($backup.TotalSize.Megabyte, 1)) MB in $($backup.Duration)" 'INF' Green

    Write-Log "  Log backup naar: $logBackupFile" 'VRB' DarkGray
    $logBackup = Backup-DbaDatabase @connSource `
        -Database       $DatabaseName `
        -FilePath       $logBackupFile `
        -Type           Log `
        -CopyOnly

    if (-not $logBackup) { throw "Log backup failed" }
    Write-Log "    OK: Log backup: $([math]::Round($logBackup.TotalSize.Megabyte, 1)) MB in $($logBackup.Duration)" 'INF' Green

    # --- Step 6b: Brondatabase offline zetten na backup (optioneel) ---

    if ($TakeSourceOffline) {
        Write-Log "==> [6b] '$DatabaseName' offline zetten op AG_Source $AG_Source na backup" 'INF' Cyan

        $q = "ALTER AVAILABILITY GROUP [$AG_Source] REMOVE DATABASE [$DatabaseName];"
        Write-Log "  T-SQL ($Node1_source): $q" 'VRB' DarkGray
        Invoke-DbaQuery @connSource -Query $q -EnableException
        Write-Log "    OK: Database verwijderd uit $AG_Source op $Node1_source" 'INF' Green

        Start-Sleep -Seconds 3

        $q = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE;"
        Write-Log "  T-SQL ($Node1_source): $q" 'VRB' DarkGray
        Invoke-DbaQuery @connSource -Query $q -EnableException
        Write-Log "    OK: Database offline gezet op $Node1_source" 'INF' Green

        $sourceScriptContent = @"
-- Handmatig uitvoeren op secondary $Node2_source
-- Na offline zetten van primary $Node1_source
ALTER AVAILABILITY GROUP [$AG_Source] REMOVE DATABASE [$DatabaseName];
GO
ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE;
GO
"@
        $sourceScriptFile = Join-Path $logDir ("migrate-agdatabase_$(Get-Date -Format 'yyyyMMdd_HHmmss')_source_offline.sql")
        $sourceScriptContent | Out-File -FilePath $sourceScriptFile -Encoding utf8

        Write-Log "    WAR: Voer onderstaand script handmatig uit op secondary $Node2_source" 'WAR' Yellow
        foreach ($line in ($sourceScriptContent -split "`n")) {
            $trimmed = $line.TrimEnd()
            if ($trimmed) { Write-Log "    $trimmed" 'WAR' Yellow }
        }
        Write-Log "    Script opgeslagen als: $sourceScriptFile" 'WAR' Yellow
    }

    # --- Step 7: Restore to AG_Destination primary (NORECOVERY) ---

    Write-Log "==> [7] Restoring '$DatabaseName' to AG_Destination primary $Node1_destination" 'INF' Cyan

    # Restore via T-SQL om de dbatools pre-flight bestandscheck te omzeilen.
    # Restore-DbaDatabase gebruikt Test-DbaBackupInformation die weigert te restoren als bestanden
    # bestaan maar niet gekoppeld zijn aan een database — ook met -WithReplace.
    # WITH MOVE is nodig als bron en doel verschillende SQL Server versies hebben
    # (bv. MSSQL16 op bron vs MSSQL17 op doel).

    $defaultPaths = Get-DbaDefaultPath @connDest
    $header = Read-DbaBackupHeader @connDest -Path $backupFile | Select-Object -First 1
    if (-not $header -or -not $header.FileList) { throw "Kon backup header niet lezen van: $backupFile" }
    $moveClauses = ($header.FileList | ForEach-Object {
        $fileName  = Split-Path $_.PhysicalName -Leaf
        $targetDir = if ($_.Type -eq 'L') { $defaultPaths.Log } else { $defaultPaths.Data }
        "MOVE N'$($_.LogicalName)' TO N'$($targetDir.TrimEnd('\'))\$fileName'"
    }) -join ', '
    Write-Log "  MOVE: $moveClauses" 'VRB' DarkGray

    $q = "RESTORE DATABASE [$DatabaseName] FROM DISK = N'$backupFile' WITH NORECOVERY, REPLACE, $moveClauses"
    Write-Log "  T-SQL ($Node1_destination): RESTORE DATABASE [$DatabaseName] ... WITH NORECOVERY, REPLACE, MOVE ..." 'VRB' DarkGray
    Invoke-DbaQuery @connDest -Database master -Query $q -QueryTimeout 7200 -EnableException
    Write-Log "    OK: Full backup restored (NORECOVERY) on $Node1_destination" 'INF' Green

    $q = "RESTORE LOG [$DatabaseName] FROM DISK = N'$logBackupFile' WITH NORECOVERY"
    Write-Log "  T-SQL ($Node1_destination): $q" 'VRB' DarkGray
    Invoke-DbaQuery @connDest -Database master -Query $q -QueryTimeout 3600 -EnableException
    Write-Log "    OK: Log backup restored (NORECOVERY) on $Node1_destination" 'INF' Green

    $q = "RESTORE DATABASE [$DatabaseName] WITH RECOVERY"
    Write-Log "  T-SQL ($Node1_destination): $q" 'VRB' DarkGray
    Invoke-DbaQuery @connDest -Database master -Query $q -QueryTimeout 300 -EnableException
    Write-Log "    OK: Database recovered on $Node1_destination" 'INF' Green

    # --- Step 8: Set FULL recovery model ---

    Write-Log "==> [8] Setting FULL recovery model on $Node1_destination" 'INF' Cyan

    Invoke-DbaWithLog {
        Set-DbaDbRecoveryModel @connDest -Database $DatabaseName -RecoveryModel Full -Confirm:$false
    }
    Write-Log "    OK: Recovery model set to FULL" 'INF' Green

    # --- Step 9: Add to AG_Destination (auto seeding) ---

    Write-Log "==> [9] Adding '$DatabaseName' to AG '$AG_Destination' with automatic seeding" 'INF' Cyan

    Invoke-DbaWithLog {
        Add-DbaAgDatabase @connDest `
            -AvailabilityGroup  $AG_Destination `
            -Database           $DatabaseName `
            -SeedingMode        Automatic
    }
    Write-Log "    OK: Database added to $AG_Destination - automatic seeding to $Node2_destination initiated" 'INF' Green

    # --- Step 10: Wait for synchronization ---

    Write-Log "==> [10] Waiting for AG synchronization (up to 10 minutes)" 'INF' Cyan

    $deadline  = (Get-Date).AddMinutes(10)
    $syncState = ''
    do {
        Start-Sleep -Seconds 15
        $agDb      = Get-DbaAgDatabase @connDest -AvailabilityGroup $AG_Destination -Database $DatabaseName
        $syncState = $agDb.SynchronizationState
        Write-Log "    Sync state: $syncState ($(Get-Date -Format 'HH:mm:ss'))" 'INF' White

        if ((Get-Date) -gt $deadline) {
            Write-Log "    WARN: Timeout waiting for synchronization. Check AG health manually." 'WAR' Yellow
            break
        }
    } while ($syncState -ne 'Synchronized')

    if ($syncState -eq 'Synchronized') {
        Write-Log "    OK: Database '$DatabaseName' is SYNCHRONIZED in $AG_Destination" 'INF' Green
    }

    Write-Log "--- Klaar: $DatabaseName [$i/$totalDbs] ---" 'INF' Green
}

# --- Summary ---

Write-Host ""
if ($CleanAGDestination) {
    Write-Log "=== Cleanup voltooid: $totalDbs database(s) verwijderd uit $AG_Destination ===" 'INF' Green
} else {
    Write-Log "=== Migratie voltooid: $totalDbs database(s) ===" 'INF' Green
    Write-Log "  Source AG  : $AG_Source ($Node1_source)" 'INF' White
}
Write-Log "  Target AG  : $AG_Destination ($Node1_destination / $Node2_destination)" 'INF' White
Write-Log "  Databases  : $($DatabaseNames -join ', ')" 'INF' White
Write-Log "  Log        : $script:LogFilePath" 'INF' White
