#!/usr/bin/env bash

# server_health_check.sh
# A DevOps capstone project script to check the health
# of multiple remote servers via SSH.

# --- Part 1: "Strict Mode" (from section 9) ---
# exit immediately if any command fails, exit if undefined var, pipeline fails -> fail
set -euo pipefail

# --- Global Constants ---
LOG_FILE=$(mktemp /tmp/server_health.XXXXXX)
readonly LOG_FILE

# --- Function Definitions ---

# This function will clean up after the script
cleanup() {
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

# Log an informational message to both screen and log file
log_info() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [INFO] $1" | tee -a "$LOG_FILE"
}

# Log an error message to stderr and to the log file
log_error() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [ERROR] $1" | tee -a "$LOG_FILE" >&2
}

usage() {
    echo "Usage: $0 -f <server_list_file> -u <remote_user> [-p <port>] [-t <timeout>]"
    echo "Arguments:"
    echo "  -f : Path to file containing server list (required)"
    echo "  -u : SSH username (required)"
    echo "  -p : SSH port (optional, default: 22)"
    echo "  -t : SSH timeout in seconds (optional, default: 5)"
    exit 2
}

parse_args() {
    SERVER_LIST_FILE=""
    REMOTE_USER=""
    SSH_PORT=22
    SSH_TIMEOUT=5

    while getopts "f:u:p:t:" opt; do
        case "$opt" in
            f) SERVER_LIST_FILE="$OPTARG" ;;
            u) REMOTE_USER="$OPTARG" ;;
            p) SSH_PORT="$OPTARG" ;;
            t) SSH_TIMEOUT="$OPTARG" ;;
            *) usage ;;
        esac
    done

    if [[ -z "$SERVER_LIST_FILE" ]] || [[ -z "$REMOTE_USER" ]]; then
        usage
    fi
}

validate_inputs() {
    if [[ ! -f "$SERVER_LIST_FILE" ]]; then
        log_error "Server list file '$SERVER_LIST_FILE' not found."
        exit 2
    fi

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        log_error "Invalid SSH port: $SSH_PORT"
        exit 2
    fi

    if ! [[ "$SSH_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SSH_TIMEOUT" -lt 1 ]; then
        log_error "Invalid SSH timeout: $SSH_TIMEOUT"
        exit 2
    fi
}

read_server_list() {
    SERVERS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim leading and trailing whitespace
        line=$(echo "$line" | xargs)
        
        # Ignore empty lines and comments
        if [[ -n "$line" ]] && [[ ! "$line" =~ ^# ]]; then
            # Basic validation: ensure it doesn't contain spaces inside
            if [[ "$line" =~ \  ]]; then
                log_error "Invalid host format in line: '$line'. Ignoring."
                continue
            fi
            SERVERS+=("$line")
        fi
    done < "$SERVER_LIST_FILE"

    if [[ ${#SERVERS[@]} -eq 0 ]]; then
        log_error "No valid servers found in $SERVER_LIST_FILE."
        exit 2
    fi
}

# Shared variables for tracking summary
TOTAL_SERVERS=0
SUCCESS_SERVERS=0
FAILED_SERVERS=0
REPORT=""

run_health_checks() {
    local target="$1"
    local user="$2"
    
    # Combined command block to run over SSH
    # We use echo separators to easily parse the output
    local cmd="
        echo '---UPTIME---';
        uptime -p || uptime;
        echo '---FREE---';
        free -m;
        echo '---DF---';
        df -h /;
        echo '---TOP---';
        top -bn1 | grep 'Cpu(s)' || echo 'N/A'
    "
    
    ssh -q -o StrictHostKeyChecking=no -o PasswordAuthentication=no \
        -o ConnectTimeout="$SSH_TIMEOUT" -p "$SSH_PORT" \
        "$user@$target" "$cmd" 2>/dev/null
}

parse_metrics() {
    local target="$1"
    local raw_output="$2"
    
    local uptime_val="N/A"
    local mem_usage="N/A"
    local disk_usage="N/A"
    local cpu_usage="N/A"

    # Extract uptime
    if echo "$raw_output" | grep -q '---UPTIME---'; then
        uptime_val=$(echo "$raw_output" | awk '/---UPTIME---/{getline; print $0}')
    fi

    # Extract memory usage
    if echo "$raw_output" | grep -q '---FREE---'; then
        local mem_line=$(echo "$raw_output" | awk '/---FREE---/{getline; getline; print $0}')
        if [[ -n "$mem_line" ]]; then
            local total=$(echo "$mem_line" | awk '{print $2}')
            local used=$(echo "$mem_line" | awk '{print $3}')
            if [[ "$total" -gt 0 ]]; then
                mem_usage=$(( used * 100 / total ))"%"
            fi
        fi
    fi

    # Extract disk usage
    if echo "$raw_output" | grep -q '---DF---'; then
        local disk_line=$(echo "$raw_output" | awk '/---DF---/{getline; getline; print $0}')
        if [[ -n "$disk_line" ]]; then
            disk_usage=$(echo "$disk_line" | awk '{print $5}')
        fi
    fi

    # Extract CPU usage
    if echo "$raw_output" | grep -q '---TOP---'; then
        local cpu_line=$(echo "$raw_output" | awk '/---TOP---/{getline; print $0}')
        if [[ -n "$cpu_line" ]] && [[ "$cpu_line" != "N/A" ]]; then
            # Extract idle percentage and subtract from 100 to get used percentage
            # top command format: %Cpu(s):  1.0 us,  0.5 sy, ... 98.0 id, ...
            local idle=$(echo "$cpu_line" | awk -F',' '{for(i=1;i<=NF;i++) if($i~/id/) print $i}' | awk '{print $1}')
            if [[ -n "$idle" ]]; then
                cpu_usage=$(awk "BEGIN {print 100 - $idle}")"%"
            else
                cpu_usage="N/A"
            fi
        fi
    fi

    # Append to report
    REPORT+="Server: $target\n"
    REPORT+="CPU: $cpu_usage\n"
    REPORT+="Memory: $mem_usage\n"
    REPORT+="Disk: $disk_usage\n"
    REPORT+="Uptime: $uptime_val\n"
    REPORT+="Status: OK\n\n"
}

check_server() {
    local host_entry="$1"
    
    TOTAL_SERVERS=$((TOTAL_SERVERS + 1))
    log_info "Checking server: $host_entry"

    # Support optional user override in the list file (user@host)
    local target="$host_entry"
    local user="$REMOTE_USER"

    if [[ "$host_entry" == *"@"* ]]; then
        user="${host_entry%%@*}"
        target="${host_entry##*@}"
    fi

    local output
    if ! output=$(run_health_checks "$target" "$user"); then
        log_error "Connection or check failed: $host_entry"
        FAILED_SERVERS=$((FAILED_SERVERS + 1))
        
        REPORT+="Server: $host_entry\n"
        REPORT+="Status: FAILED\n\n"
        return 0 # Continuing despite failure
    fi

    SUCCESS_SERVERS=$((SUCCESS_SERVERS + 1))
    parse_metrics "$host_entry" "$output"
}

generate_report() {
    echo -e "\n========================================"
    echo -e "         HEALTH CHECK REPORT"
    echo -e "========================================\n"
    
    echo -e "$REPORT"
    
    echo "========================================"
    echo "                 SUMMARY"
    echo "========================================"
    echo "Total: $TOTAL_SERVERS"
    echo "Success: $SUCCESS_SERVERS"
    echo "Failed: $FAILED_SERVERS"
    
    log_info "Report generation complete."
    
    if [[ "$FAILED_SERVERS" -gt 0 ]]; then
        if [[ "$SUCCESS_SERVERS" -gt 0 ]]; then
            exit 1 # Partial failure
        else
            exit 2 # Fatal error (all failed)
        fi
    else
        exit 0 # Success
    fi
}

main() {
    parse_args "$@"
    validate_inputs
    
    log_info "Starting health check script"
    read_server_list
    
    for server in "${SERVERS[@]}"; do
        check_server "$server"
    done
    
    generate_report
}

# Run the script
main "$@"
