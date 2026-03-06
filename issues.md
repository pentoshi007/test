# Current logical/code issues audit (`server.py`, `pdf2.ps1`)

## 1) Built-in server commands are hijacked during running commands (High)
- **Evidence:** `server.py:266-271` forwards any operator input to `pending_stdin` whenever `command_running` is true, before built-ins like `sessions`, `status`, `use`, `kill`, `remove`, `exit` are handled.
- **Impact:** During interactive sessions, local control commands are sent to remote stdin instead of being processed by the server (matches the behavior where `status`/`pwsh` appear to do nothing locally).
- **Suggested fix:** Handle core built-ins (`sessions`, `status`, `use`, `kill`, `remove`, `help`, `exit`) before stdin forwarding, and reserve forwarding for non-built-in input.

## 2) Final `/result` can still be dropped (High)
- **Evidence:** `server.py:186-188` uses `result_queue.put(..., timeout=2)` and still does `except queue.Full: pass`.
- **Impact:** Command completion output can disappear under queue pressure; operator may not see final state/output even though command ended.
- **Suggested fix:** Never drop `result` events; evict old stream chunks or block/retry until a result record is queued.

## 3) HTTP response `.Trim()` corrupts interactive stdin payloads (Medium)
- **Evidence:** `pdf2.ps1:173` does `$reader.ReadToEnd().Trim()` for all responses, including `/stdin`.
- **Impact:** Leading/trailing spaces and empty lines are stripped, which can alter commands sent into interactive shells/REPLs.
- **Suggested fix:** Avoid global `Trim()` in transport; only trim where protocol needs it (e.g., command fetch), not stdin payloads.

## 4) Interactive mode detection on server is marker-fragile (Medium)
- **Evidence:** `server.py:168-169` sets `client["interactive"] = True` when stream body contains `"[interactive]"`.
- **Impact:** Any normal command output containing that text can incorrectly switch prompt mode; conversely, missing marker keeps prompt mode wrong.
- **Suggested fix:** Send interactive state explicitly via dedicated endpoint/flag instead of parsing output text.

## 5) Interactive loop hides transport failures and can look "stuck" (Medium)
- **Evidence:** `Get-Stdin-From-Server`/`Get-Signal-From-Server` return `""` on exceptions (`pdf2.ps1:183-185`, `199-200`), and interactive loop keeps running (`pdf2.ps1:307-347`).
- **Impact:** When network/tunnel fails mid-interactive command, client can continue silently without check-ins, while server reports offline and no output arrives.
- **Suggested fix:** Track consecutive poll failures inside interactive loop; emit warning/result and abort interactive process after threshold so watchdog/main loop can recover cleanly.

## 6) Interactive executable fallback search is expensive (Low/Medium)
- **Evidence:** `pdf2.ps1:256-265` recursively scans multiple directories (`Get-ChildItem -Recurse -Depth 2`) when command resolution fails.
- **Impact:** Can add major startup latency to interactive commands, especially under SYSTEM context with broad paths.
- **Suggested fix:** Prefer deterministic lookup (`Get-Command`, known absolute paths, cached map) and avoid recursive scans per command.
