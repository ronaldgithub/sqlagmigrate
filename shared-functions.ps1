# ---------- Logging ----------
function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('INF', 'WAR', 'ERR', 'VRB')]
        [string]$Level = 'INF',

        [Parameter(Position = 2)]
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine   = "[$timestamp] [$Level] $Message"

    Write-Host $logLine -ForegroundColor $ForegroundColor

    if ($script:LogFilePath) {
        $logLine | Out-File -FilePath $script:LogFilePath -Append -Encoding utf8
    }
}

# ---------- dbatools verbose wrapper ----------
function Invoke-DbaWithLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock
    )

    if (-not $Config.Defaults.VerboseLogging) {
        $null = & $ScriptBlock
        return
    }

    $previousPref = $VerbosePreference
    $VerbosePreference = 'Continue'
    try {
        & $ScriptBlock 4>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.VerboseRecord]) {
                Write-Log "  $($_.Message)" 'VRB' DarkGray
            } else {
                $line = $_ | Out-String -Width 200 | ForEach-Object { $_.Trim() }
                if ($line) {
                    Write-Log "  $line" 'VRB' DarkGray
                }
            }
        }
    }
    finally {
        $VerbosePreference = $previousPref
    }
}

# ---------- Voortgangshelper ----------
function Format-Elapsed {
    param ([System.Diagnostics.Stopwatch]$Stopwatch)
    $e = $Stopwatch.Elapsed
    '{0:00}:{1:00}:{2:00}' -f $e.Hours, $e.Minutes, $e.Seconds
}
