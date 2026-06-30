#!/bin/bash

# BGP Session Test Script for SR Linux Containerlab Topologies
# Derives expected peer count directly from each device's running config:
#   - configured static neighbors  (running datastore)
#   - dynamic-neighbor interfaces  (running datastore)
# No manual baseline required — works for static, dynamic, or mixed topologies.
# M. McCoy 5.12.26 Nokia

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

DEFAULT_TIMEOUT=120
POLL_INTERVAL=5
TOPOLOGY_FILE=""
CONTAINER_PREFIX=""
DEVICES=()

show_usage() {
    echo "Usage: $0 [OPTIONS] <topology-file>"
    echo "Validates BGP sessions for all SR Linux nodes in a containerlab topology."
    echo "Expected peer count is derived from each device's config (static + dynamic)."
    echo
    echo "Arguments:"
    echo "  <topology-file>          Path to the containerlab topology YAML file (required)"
    echo
    echo "Options:"
    echo "  -t, --timeout SECONDS    Timeout in seconds (default: ${DEFAULT_TIMEOUT})"
    echo "  -i, --interval SECONDS   Poll interval in seconds (default: ${POLL_INTERVAL})"
    echo "  -v, --verbose           Show per-device detail each poll cycle"
    echo "  -h, --help              Show this help message"
    echo
    echo "Examples:"
    echo "  $0 aifab.clab.yaml"
    echo "  $0 -t 300 -v aifab.clab.yaml"
}

# Derive container prefix from the topology YAML using containerlab naming rules:
#   no prefix field    →  clab-<name>-
#   prefix: ""         →  (empty)
#   prefix: __lab-name →  <name>-
#   prefix: "foo"      →  foo-
derive_container_prefix() {
    local yaml_file="$1"
    local topo_name
    topo_name=$(grep -E '^name:' "$yaml_file" | awk '{print $2}' | tr -d '"'"'")

    if grep -qE '^prefix:' "$yaml_file"; then
        local prefix_val
        prefix_val=$(grep -E '^prefix:' "$yaml_file" | awk '{print $2}' | tr -d '"'"'")
        if [[ -z "$prefix_val" ]]; then
            echo ""
        elif [[ "$prefix_val" == "__lab-name" ]]; then
            echo "${topo_name}-"
        else
            echo "${prefix_val}-"
        fi
    else
        echo "clab-${topo_name}-"
    fi
}

check_lab_deployed() {
    if ! containerlab inspect > /dev/null 2>&1; then
        echo -e "${RED}Error: No lab topology is deployed${NC}"
        exit 1
    fi

    local running
    running=$(containerlab inspect --format json 2>/dev/null \
        | jq -r 'to_entries[].value[] | select(.kind == "nokia_srlinux") | .name' \
        | sed "s/^${CONTAINER_PREFIX}//")

    if [[ -z "$running" ]]; then
        echo -e "${RED}Error: No SR Linux devices found in the running topology${NC}"
        exit 1
    fi

    readarray -t DEVICES <<< "$running"
    echo -e "${CYAN}Discovered ${#DEVICES[@]} SR Linux devices${NC}"
}

# Query a device for expected and established peer counts in a single JSON-RPC call:
#   command 0: static neighbors        (running) → expected static count
#   command 1: dynamic-neighbors       (running) → expected dynamic count
#   command 2: all neighbor states     (state)   → established count
# Returns "expected:established" or "ERROR".
get_bgp_info() {
    local device="$1"
    local url="http://${CONTAINER_PREFIX}${device}/jsonrpc"

    local response
    response=$(curl -s -u admin:NokiaSrl1! "$url" \
        -H "Content-Type: application/json" \
        -d '{
            "jsonrpc": "2.0",
            "id": 0,
            "method": "get",
            "params": {
                "commands": [
                    {
                        "path": "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]",
                        "datastore": "running"
                    },
                    {
                        "path": "/network-instance[name=default]/protocols/bgp/dynamic-neighbors",
                        "datastore": "running"
                    },
                    {
                        "path": "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]",
                        "datastore": "state"
                    }
                ]
            }
        }' 2>/dev/null)

    [[ -z "$response" ]] && { echo "ERROR"; return 1; }

    echo "$response" | jq -r '
        if .result then
            (if .result[0].neighbor then .result[0].neighbor | length else 0 end) as $static |
            (if .result[1].interface then .result[1].interface | length else 0 end) as $dynamic |
            (if .result[2].neighbor then
                [.result[2].neighbor[] | select(."session-state" == "established")] | length
            else 0 end) as $established |
            ($static | tostring) + ":" + ($dynamic | tostring) + ":" + ($established | tostring)
        else "0:0:0" end
    ' 2>/dev/null || echo "ERROR"
}

# Fetch per-peer state detail for a device (used in the final summary for failing nodes).
# Returns lines of: state|peer-address|description
# Uses | as separator to safely handle IPv6 peer addresses containing colons.
get_bgp_peer_details() {
    local device="$1"
    local url="http://${CONTAINER_PREFIX}${device}/jsonrpc"

    local response
    response=$(curl -s -u admin:NokiaSrl1! "$url" \
        -H "Content-Type: application/json" \
        -d '{
            "jsonrpc": "2.0",
            "id": 0,
            "method": "get",
            "params": {
                "commands": [
                    {
                        "path": "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]",
                        "datastore": "state"
                    }
                ]
            }
        }' 2>/dev/null)

    [[ -z "$response" ]] && return 1

    echo "$response" | jq -r '
        if .result and .result[0] and .result[0].neighbor then
            .result[0].neighbor[] |
            (."session-state") + "|" + (."peer-address") + "|" + (.description // "")
        else empty end
    ' 2>/dev/null
}

# Check all discovered devices.
# Returns "established:static:dynamic:device_results~..."
# Each device result: "device:status:established:static:dynamic"
check_all_bgp_sessions() {
    local verbose="$1"
    local total_established=0 total_static=0 total_dynamic=0
    local device_results=()

    for device in "${DEVICES[@]}"; do
        local info dev_static=0 dev_dynamic=0 dev_established=0
        info=$(get_bgp_info "$device")

        if [[ "$info" == "ERROR" ]]; then
            device_results+=("$device:ERROR:0:0:0")
        else
            IFS=':' read -r dev_static dev_dynamic dev_established <<< "$info"
            local dev_expected=$(( dev_static + dev_dynamic ))
            total_static=$(( total_static + dev_static ))
            total_dynamic=$(( total_dynamic + dev_dynamic ))
            total_established=$(( total_established + dev_established ))
            device_results+=("$device:OK:$dev_established:$dev_static:$dev_dynamic")
        fi

        if [[ "$verbose" == "true" ]]; then
            local dev_expected=$(( dev_static + dev_dynamic ))
            if [[ "$info" == "ERROR" ]]; then
                echo -e "${RED}  $device: connection failed${NC}" >&2
            elif [[ $dev_expected -eq 0 ]]; then
                echo -e "${CYAN}  $device: no BGP peers configured${NC}" >&2
            elif [[ $dev_established -eq $dev_expected ]]; then
                echo -e "${GREEN}  $device: ${dev_established}/${dev_expected} established${NC}" >&2
            else
                echo -e "${YELLOW}  $device: ${dev_established}/${dev_expected} established${NC}" >&2
            fi
        fi
    done

    echo "${total_established}:${total_static}:${total_dynamic}:$(IFS='~'; echo "${device_results[*]}")"
}

show_final_summary() {
    local session_data="$1"
    local established total_static total_dynamic details
    IFS=':' read -r established total_static total_dynamic details <<< "$session_data"
    local expected=$(( total_static + total_dynamic ))

    echo -e "${PURPLE}=== BGP Session Summary ===${NC}"
    echo -e "Expected: ${BLUE}${expected}${NC} (${total_static} static / ${total_dynamic} dynamic)  |  Established: ${GREEN}${established}${NC}  |  Not established: ${YELLOW}$(( expected - established ))${NC}"
    echo

    local failures=() successes=() device_results=()
    IFS='~' read -r -a device_results <<< "$details"

    for entry in "${device_results[@]}"; do
        [[ -z "$entry" ]] && continue
        local device status dev_est dev_static dev_dynamic
        IFS=':' read -r device status dev_est dev_static dev_dynamic <<< "$entry"
        local dev_exp=$(( dev_static + dev_dynamic ))
        if [[ "$status" == "ERROR" ]] || [[ $dev_est -lt $dev_exp ]]; then
            failures+=("$entry")
        elif [[ $dev_exp -gt 0 ]]; then
            successes+=("$entry")
        fi
    done

    for entry in "${failures[@]}" "${successes[@]}"; do
        [[ -z "$entry" ]] && continue
        local device status dev_est dev_static dev_dynamic
        IFS=':' read -r device status dev_est dev_static dev_dynamic <<< "$entry"
        local dev_exp=$(( dev_static + dev_dynamic ))

        if [[ "$status" == "ERROR" ]]; then
            echo -e "  ${RED}${device}: connection failed${NC}"
        elif [[ $dev_est -eq $dev_exp ]]; then
            echo -e "  ${GREEN}${device}: ${dev_est}/${dev_exp} established (${dev_static} static / ${dev_dynamic} dynamic)${NC}"
        else
            echo -e "  ${YELLOW}${device}: ${dev_est}/${dev_exp} established (${dev_static} static / ${dev_dynamic} dynamic)${NC}"
            while IFS='|' read -r state peer desc; do
                local label="${peer}${desc:+ (${desc})}"
                if [[ "$state" == "established" ]]; then
                    echo -e "    ${GREEN}✓ ${label}${NC}"
                else
                    echo -e "    ${RED}✗ ${label}: ${state}${NC}"
                fi
            done <<< "$(get_bgp_peer_details "$device")"
        fi
    done
    echo
}

wait_for_bgp_sessions() {
    local timeout="$1"
    local poll_interval="$2"
    local verbose="$3"

    local start_time end_time
    start_time=$(date +%s)
    end_time=$(( start_time + timeout ))

    echo -e "${BLUE}Waiting for all BGP sessions to become established...${NC}"
    echo -e "${YELLOW}Timeout: ${timeout}s  |  Poll interval: ${poll_interval}s${NC}"
    echo

    while true; do
        local current_time elapsed remaining
        current_time=$(date +%s)
        elapsed=$(( current_time - start_time ))
        remaining=$(( end_time - current_time ))

        if [[ $current_time -gt $end_time ]]; then
            echo -e "${RED}Timeout reached after ${elapsed}s${NC}"
            echo
            local final_data
            final_data=$(check_all_bgp_sessions false)
            show_final_summary "$final_data"
            return 1
        fi

        [[ "$verbose" == "true" ]] && echo -e "${CYAN}[${elapsed}s] Per-device status:${NC}" >&2

        local session_data established total_static total_dynamic expected
        session_data=$(check_all_bgp_sessions "$verbose")
        IFS=':' read -r established total_static total_dynamic _ <<< "$session_data"
        expected=$(( total_static + total_dynamic ))

        echo -e "${BLUE}[${elapsed}s/${timeout}s]${NC} BGP sessions: ${GREEN}${established}${NC}/${BLUE}${expected}${NC} established  (${remaining}s remaining)"

        if [[ $expected -gt 0 ]] && [[ $established -eq $expected ]]; then
            echo -e "${GREEN}All BGP sessions are established!${NC}"
            echo
            show_final_summary "$session_data"
            return 0
        fi

        sleep "$poll_interval"
    done
}

# --- Argument parsing ---
TIMEOUT="$DEFAULT_TIMEOUT"
INTERVAL="$POLL_INTERVAL"
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--timeout)  TIMEOUT="$2";  shift 2 ;;
        -i|--interval) INTERVAL="$2"; shift 2 ;;
        -v|--verbose)  VERBOSE=true;  shift   ;;
        -h|--help)     show_usage; exit 0      ;;
        *)             TOPOLOGY_FILE="$1"; shift ;;
    esac
done

if [[ -z "$TOPOLOGY_FILE" ]]; then
    echo -e "${RED}Error: topology file is required${NC}"
    echo
    show_usage
    exit 1
fi

if [[ ! "$TIMEOUT"  =~ ^[0-9]+$ ]] || [[ $TIMEOUT  -lt 1 ]]; then
    echo -e "${RED}Error: Timeout must be a positive integer${NC}"; exit 1
fi
if [[ ! "$INTERVAL" =~ ^[0-9]+$ ]] || [[ $INTERVAL -lt 1 ]]; then
    echo -e "${RED}Error: Interval must be a positive integer${NC}"; exit 1
fi

for tool in curl jq; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${RED}Error: Required tool '$tool' is not installed${NC}"; exit 1
    fi
done

CONTAINER_PREFIX=$(derive_container_prefix "$TOPOLOGY_FILE")

check_lab_deployed

echo
echo -e "${PURPLE}=== BGP Session Test ===${NC}"
echo -e "Timeout: ${TIMEOUT}s  |  Poll interval: ${INTERVAL}s"
echo

if wait_for_bgp_sessions "$TIMEOUT" "$INTERVAL" "$VERBOSE"; then
    exit 0
else
    echo -e "${RED}Failed: BGP sessions did not reach expected state within timeout${NC}"
    exit 1
fi
