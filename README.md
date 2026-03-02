# Shell C2

A resilient, remote command and control (C2) shell consisting of an operator server (`server.py`) and a Windows client script (`pdf2.ps1`). The connection is routed securely using Cloudflare Tunnels, allowing full remote access and PowerShell command execution across NATs and firewalls.

## Features

- **Multi-Client Support**: Seamlessly track and interact with multiple running Windows targets. Identify them by hostname, check their status, and switch between sessions.
- **Adaptive Execution & Streaming**: Output is streamed adaptively back to the operator in real-time. Output chunks are capped to cleanly display long output.
- **Resilience & Persistence**:
  - The client (`pdf2.ps1`) installs itself as a Windows Scheduled Task (`SystemManagementUpdate`) to persist across reboots.
  - Recovers from crashes directly with automatic restart logic.
  - Automatically retries connection with exponential backoff if the Cloudflare Tunnel drops or is unready.
- **Granular Command Control**: Abort long-running or stuck commands immediately using the `cancel` command or `Ctrl+\`. Commands legitimately meant to run forever without timeout can be run via the `notimeout:` prefix.

## Architecture

```text
[Mac] server.py  ←—Cloudflare Tunnel—→  [Windows] pdf2.ps1
  operator types commands                 executes & streams output back
```

- **Operator (Server)**: A Python 3 multi-threaded HTTP server (`server.py`) acting as the command center on a macOS or Linux machine.
- **Target (Client)**: A robust PowerShell script (`pdf2.ps1`) executed on the compromised/managed Windows machine.

## Getting Started

Start the components in the correct order to ensure seamless connection:

1. **Start the C2 Server**:
   ```bash
   python3 server.py
   ```
2. **Start the Cloudflare tunnel** (in a separate terminal):
   ```bash
   cloudflared tunnel run <your-tunnel-name>
   ```
3. **Execute the Payload** on the Windows machine:
   Run `pdf2.ps1`. It will establish persistence and continuously beacon securely back to the operator server through the tunnel.

## Documentation

For an in-depth guide on operator commands (like `sessions`, `use`, `kill`), handling truncated output, troubleshooting tunnel errors, and detailed cleanup instructions, please refer to the comprehensive [Usage Guide](usage.md).
