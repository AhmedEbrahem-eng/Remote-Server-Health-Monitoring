# Remote Server Health Monitoring

A production-grade Bash script to perform remote health checks on multiple servers over SSH. This project is built with strong guarantees around fault tolerance, observability, and security.

## Features

- **Automated Health Checks**: Retrieves CPU usage, Memory usage, Disk usage, and System Uptime from remote servers.
- **Fault Tolerant**: A failure on one server does not terminate the script; it handles connection errors gracefully and continues.
- **Robust Error Handling**: Uses strict Bash mode (`set -euo pipefail`) to ensure predictable execution.
- **Security-First**: Enforces SSH key-based authentication, disables host key prompts, and prevents command injection.
- **Dual Logging**: Outputs real-time information to `stdout` while simultaneously writing to a temporary file, which is automatically cleaned up on exit.
- **Detailed Reporting**: Generates a consolidated report detailing the status and metrics of each server, along with a final success/failure summary.

## Prerequisites

- **SSH Keys**: Ensure SSH key-based authentication is configured (`ssh-copy-id`) between the machine running the script and all target servers. Password authentication is explicitly disabled.
- **Target OS**: The remote servers must be POSIX-compliant Linux/Unix systems with standard GNU tools installed (`uptime`, `free`, `df`, `top`, `awk`, `grep`).

## Installation

Make the script executable:

```bash
chmod +x server_health_check.sh
```

## Configuration

Create a text file containing the list of servers you want to monitor (e.g., `servers.txt`). 

- Place one server per line (IP address or hostname).
- You can override the default SSH user for specific servers by using the `user@host` format.
- Empty lines and comments starting with `#` are ignored.

**Example `servers.txt`:**
```text
# Standard hosts
192.168.1.10
web-server-01.internal.net

# User override example
admin@host2.example.com
```

## Usage

```bash
./server_health_check.sh -f <server_list_file> -u <remote_user> [-p <port>] [-t <timeout>]
```

### Arguments

| Argument | Status | Description | Default |
| :--- | :--- | :--- | :--- |
| **`-f`** | **Required** | Path to the text file containing the server list. | *None* |
| **`-u`** | **Required** | Default SSH username to use for connections. | *None* |
| **`-p`** | Optional | SSH port to use for connections. | `22` |
| **`-t`** | Optional | SSH connection timeout in seconds. | `5` |

### Examples

**Basic execution with default port and timeout:**
```bash
./server_health_check.sh -f servers.txt -u ahmed
```

**Custom SSH Port (e.g., 2222) and Timeout (e.g., 10 seconds):**
```bash
./server_health_check.sh -f servers.txt -u ahmed -p 2222 -t 10
```

## Output Example

```text
[2024-04-24 12:00:00] [INFO] Starting health check script
[2024-04-24 12:00:00] [INFO] Checking server: 192.168.1.10
[2024-04-24 12:00:02] [INFO] Checking server: admin@host2.example.com

========================================
         HEALTH CHECK REPORT
========================================

Server: 192.168.1.10
CPU: 12.5%
Memory: 45%
Disk: 68%
Uptime: up 10 days, 2 hours
Status: OK

Server: admin@host2.example.com
Status: FAILED

========================================
                 SUMMARY
========================================
Total: 2
Success: 1
Failed: 1
```

## Exit Codes

The script is designed for integration into CI/CD pipelines and monitoring tools, returning standard exit codes:

- `0`: **Success** - All servers were checked successfully.
- `1`: **Partial Failure** - Some servers were checked successfully, but one or more failed to connect.
- `2`: **Fatal Error** - Invalid arguments, missing files, or all servers failed to connect.
