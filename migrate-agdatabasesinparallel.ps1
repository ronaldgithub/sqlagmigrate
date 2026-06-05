<#
.SYNOPSIS
    Migrate multiple databases in parallel by running migrate-agdatabase.ps1 as background jobs.
.NOTES
    Requires: dbatools module, sysadmin on all nodes, Windows authentication
    Each database runs in an isolated background job with its own log file in .\logs\.
    Use -MaxParallel to cap concurrency; default is all databases at once.
.AUTHOR
    Ronald de Groot - Apeldoorn (NLD)
.LINK
    For questions or help, contact ronald.de.groot@opendata.nl
.LINK
    https://dbaronald.nl/sql-server-2016-ag-migration/
#>

<#
.\migrate-agdatabasesinparallel.ps1 `
    -DatabaseName      "Migration01", "Migration02", "Migration03" `
    -AG_Source         "agsql" `
    -AG_Destination    "agsql2" `
    -Node1_source      "sql2" `
    -Node2_source      "sql3" `
    -Node1_destination "sql4" `
    -Node2_destination "sql5" `
    -BackupPath        "\\SQL4\temp" `
    -MaxParallel       2
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string[]] $DatabaseName,
    [Parameter(Mandatory)] [string]   $AG_Source,
    [Parameter(Mandatory)] [string]   $AG_Destination,
    [Parameter(Mandatory)] [string]   $Node1_source,
    [Parameter(Mandatory)] [string]   $Node2_source,
    [Parameter(Mandatory)] [string]   $Node1_destination,
    [Parameter(Mandatory)] [string]   $Node2_destination,
    [Parameter(Mandatory)] [string]   $BackupPath,
    [int]    $MaxParallel = 0,            # 0 = all databases at once
    [switch] $TakeSourceOffline,
    [switch] $CleanAGDestination,
    [switch] $VerboseLogging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'migrate-agdatabase.ps1'
if (-not (Test-Path $scriptPath)) { throw "migrate-agdatabase.ps1 not found at: $scriptPath" }

$effectiveMax = if ($MaxParallel -gt 0) { $MaxParallel } else { $DatabaseName.Count }

# Tracks the last-read index into each job's Information stream (Write-Host output)
$infoIndex = @{}

function Flush-JobOutput {
    param([System.Collections.Generic.List[object]]$JobList)
    foreach ($job in $JobList) {
        $child = $job.ChildJobs[0]
        $count = $child.Information.Count
        if ($count -gt $infoIndex[$job.Name]) {
            foreach ($item in @($child.Information)[$infoIndex[$job.Name]..($count - 1)]) {
                Write-Host "[$($job.Name)] $($item.MessageData)"
            }
            $infoIndex[$job.Name] = $count
        }
    }
}

$jobs       = [System.Collections.Generic.List[object]]::new()
$startTimes = @{}
$pending    = [System.Collections.Generic.Queue[string]]::new($DatabaseName)

Write-Host ""
Write-Host "=== Migrate-AgDatabasesInParallel ===" -ForegroundColor Cyan
Write-Host "  Databases  : $($DatabaseName -join ', ') ($($DatabaseName.Count))" -ForegroundColor White
Write-Host "  MaxParallel: $effectiveMax" -ForegroundColor White
Write-Host ""

# Phase 1: Start jobs, throttling to MaxParallel concurrent
while ($pending.Count -gt 0) {
    while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $effectiveMax) {
        Flush-JobOutput -JobList $jobs
        Start-Sleep -Milliseconds 500
    }

    $db = $pending.Dequeue()

    $params = @{
        DatabaseName      = $db
        AG_Source         = $AG_Source
        AG_Destination    = $AG_Destination
        Node1_source      = $Node1_source
        Node2_source      = $Node2_source
        Node1_destination = $Node1_destination
        Node2_destination = $Node2_destination
        BackupPath        = $BackupPath
    }
    if ($TakeSourceOffline)  { $params['TakeSourceOffline']  = $true }
    if ($CleanAGDestination) { $params['CleanAGDestination'] = $true }
    if ($VerboseLogging)     { $params['VerboseLogging']     = $true }

    Write-Host ">>> Starting job: $db" -ForegroundColor Cyan
    $job = Start-Job -Name $db -ScriptBlock {
        param($ScriptPath, $Params)
        & $ScriptPath @Params
    } -ArgumentList $scriptPath, $params

    $jobs.Add($job)
    $startTimes[$db]  = Get-Date
    $infoIndex[$db]   = 0
}

# Phase 2: Wait for remaining jobs to finish
while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
    Flush-JobOutput -JobList $jobs
    Start-Sleep -Milliseconds 500
}
Flush-JobOutput -JobList $jobs

# Summary
Write-Host ""
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan

$failed = 0
foreach ($job in $jobs) {
    $elapsed = (Get-Date) - $startTimes[$job.Name]
    $time    = '{0:00}:{1:00}:{2:00}' -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds
    if ($job.State -eq 'Completed') {
        Write-Host ("  {0,-8} [{1}]  {2}" -f 'OK', $time, $job.Name) -ForegroundColor Green
    } else {
        Write-Host ("  {0,-8} [{1}]  {2}  (state: {3})" -f 'FAILED', $time, $job.Name, $job.State) -ForegroundColor Red
        $failed++
    }
    Remove-Job -Job $job -Force
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "  $failed of $($jobs.Count) database(s) FAILED. Check .\logs\ for details." -ForegroundColor Red
    exit 1
} else {
    Write-Host "  All $($jobs.Count) database(s) completed successfully." -ForegroundColor Green
}
