#!/bin/bash

# BGP Session Test Script for SR Linux Containerlab Topologies
# Supports two modes, auto-selected based on whether EXPECTED_PEERS is populated:
#
#   baseline  (EXPECTED_PEERS non-empty) — validates each node against a known
#             expected dynamic peer count; detects missing/unlearned peers.
#
#   discovery (EXPECTED_PEERS empty) — discovers all SR Linux nodes, checks that
#             every configured/static peer is established; shows per-peer detail
#             on failures.
#
# M. McCoy 5.12.26 Nokia

# Color codes
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
MODE=""

# Baseline expected established peer count per node.
# Leave this map empty to use discovery mode instead.
# Update these values if the topology changes.
declare -A EXPECTED_PEERS=(
    [spine1]=16          [spine2]=16
    [stripe1-leaf1]=2    [stripe1-leaf2]=2
    [stripe1-leaf3]=2    [stripe1-leaf4]=2
    [stripe1-leaf5]=2    [stripe1-leaf6]=2
    [stripe1-leaf7]=2    [stripe1-leaf8]=2
    [stripe2-leaf1]=2    [stripe2-leaf2]=2
    [stripe2-leaf3]=2    [stripe2-leaf4]=2
    [stripe2-leaf5]=2    [stripe2-leaf6]=2
    [stripe2-leaf7]=2    [stripe2-leaf8]=2
    [frontend-spine1]=2  [frontend-spine2]=2
    [frontend-leaf1]=2   [frontend-leaf2]=2
)

# Populated in discovery mode via containerlab inspect
DEVICES=()

show_usage() {
    echo "Usage: $0 [OPTIONS] <topology-file>"
    echo "Validates BGP sessions for SR Linux nodes in a containerlab topology."
    echo
    echo "  Baseline mode  (EXPECTED_PEERS populated): validates each node against its"
    echo "                 expected dynamic peer count."
    echo "  Discovery mode (EXPECTED_PEERS empty):     checks all configured/static peers"
    echo "                 are established — no expected count required."
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

    if [[ "$MODE" == "baseline" ]]; then
        local missing=()
        for device in "${!EXPECTED_PEERS[@]}"; do
            if ! grep -qx "$device" <<< "$running"; then
                missing+=("$device")
            fi
        done
        [[ ${#missing[@]} -gt 0 ]] && \
            echo -e "${YELLOW}Warning: expected devices not found: ${missing[*]}${NC}"
        local total_expected=0
        for v in "${EXPECTED_PEERS[@]}"; do total_expected=$(( total_expected + v )); done
        echo -e "${CYAN}Mode: baseline | ${#EXPECTED_PEERS[@]} devices | ${total_expected} total expected peers${NC}"
    else
        readarray -t DEVICES <<< "$running"
        if [[ ${#DEVICES[@]} -eq 0 ]]; then
            echo -e "${RED}Error: No SR Linux devices found in the topology${NC}"
            exit 1
        fi
        echo -e "${CYAN}Mode: discovery | ${#DEVICES[@]} SR Linux devices discovered${NC}"
    fi
}

# Query a single device via JSON-RPC.
# Returns "established:learned" counts, or "ERROR".
# jq handles IPv6 peer addresses natively — no string-splitting required.
get_bgp_sessions() {
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

    [[ -z "$response" ]] && { echo "ERROR"; return 1; }

    local learned established
    learned=$(echo "$response" | jq -r '
        if .result and .result[0] and .result[0].neighbor then
            .result[0].neighbor | length
        else 0 end' 2>/dev/null)

    established=$(echo "$response" | jq -r '
        if .result and .result[0] and .result[0].neighbor then
            [.result[0].neighbor[] | select(."session-state" == "established")] | length
        else 0 end' 2>/dev/null)

    echo "${established:-0}:${learned:-0}"
}

# Get per-peer detail for a device (discovery mode final summary).
# Returns lines of: state|peer-address|description
# Uses | as separator to avoid splitting on IPv6 colons.
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
        else empty end' 2>/dev/null
}

# Baseline mode check.
# Returns "established:expected:device_results~..."
# Each device result: "device:est:learned:expected"
check_sessions_baseline() {
    local verbose="$1"
    local total_established=0 total_expected=0
    local device_results=()

    for device in "${!EXPECTED_PEERS[@]}"; do
        local expected="${EXPECTED_PEERS[$device]}"
        total_expected=$(( total_expected + expected ))

        local result dev_est=0 dev_learned=0
        result=$(get_bgp_sessions "$device")
        [[ "$result" != "ERROR" ]] && IFS=':' read -r dev_est dev_learned <<< "$result"

        total_established=$(( total_established + dev_est ))
        device_results+=("$device:$dev_est:$dev_learned:$expected")

        if [[ "$verbose" == "true" ]]; then
            if [[ "$result" == "ERROR" ]]; then
                echo -e "${RED}  $device: connection failed (expected ${expected})${NC}" >&2
            elif [[ $dev_est -eq $expected ]]; then
                echo -e "${GREEN}  $device: ${dev_est}/${expected} established${NC}" >&2
            elif [[ $dev_learned -lt $expected ]]; then
                echo -e "${RED}  $device: ${dev_est}/${expected} established (only ${dev_learned}/${expected} peers learned)${NC}" >&2
            else
                echo -e "${YELLOW}  $device: ${dev_est}/${expected} established (${dev_learned} learned, some sessions down)${NC}" >&2
            fi
        fi
    done

    echo "${total_established}:${total_expected}:$(IFS='~'; echo "${device_results[*]}")"
}

# Discovery mode check.
# Returns "established:total_learned:device_results~..."
# Each device result: "device:est:learned"
check_sessions_discovery() {
    local verbose="$1"
    local total_established=0 total_learned=0
    local device_results=()

    for device in "${DEVICES[@]}"; do
        local result dev_est=0 dev_learned=0
        result=$(get_bgp_sessions "$device")
        [[ "$result" != "ERROR" ]] && IFS=':' read -r dev_est dev_learned <<< "$result"

        total_established=$(( total_established + dev_est ))
        total_learned=$(( total_learned + dev_learned ))
        device_results+=("$device:$dev_est:$dev_learned")

        if [[ "$verbose" == "true" ]]; then
            if [[ "$result" == "ERROR" ]]; then
                echo -e "${RED}  $device: connection failed${NC}" >&2
            elif [[ $dev_learned -eq 0 ]]; then
                echo -e "${CYAN}  $device: no BGP peers configured${NC}" >&2
            elif [[ $dev_est -eq $dev_learned ]]; then
                echo -e "${GREEN}  $device: ${dev_est}/${dev_learned} established${NC}" >&2
            else
                echo -e "${YELLOW}  $device: ${dev_est}/${dev_learned} established${NC}" >&2
            fi
        fi
    done

    echo "${total_established}:${total_learned}:$(IFS='~'; echo "${device_results[*]}")"
}

check_all_bgp_sessions() {
    if [[ "$MODE" == "baseline" ]]; then
        check_sessions_baseline "$1"
    else
        check_sessions_discovery "$1"
    fi
}

show_final_summary() {
    local session_data="$1"
    local established total details
    IFS=':' read -r established total details <<< "$session_data"

    echo -e "${PURPLE}=== BGP Session Summary ===${NC}"

    if [[ "$MODE" == "baseline" ]]; then
        echo -e "Expected: ${BLUE}${total}${NC}  |  Established: ${GREEN}${established}${NC}  |  Missing: ${YELLOW}$(( total - established ))${NC}"
        echo

        local failures=() successes=() device_results=()
        IFS='~' read -r -a device_results <<< "$details"

        for entry in "${device_results[@]}"; do
            [[ -z "$entry" ]] && continue
            local device dev_est dev_learned dev_expected
            IFS=':' read -r device dev_est dev_learned dev_expected <<< "$entry"
            [[ $dev_est -eq $dev_expected ]] && successes+=("$entry") || failures+=("$entry")
        done

        for entry in "${failures[@]}" "${successes[@]}"; do
            [[ -z "$entry" ]] && continue
            local device dev_est dev_learned dev_expected
            IFS=':' read -r device dev_est dev_learned dev_expected <<< "$entry"
            if [[ $dev_est -eq $dev_expected ]]; then
                echo -e "  ${GREEN}${device}: ${dev_est}/${dev_expected} established${NC}"
            elif [[ $dev_learned -lt $dev_expected ]]; then
                echo -e "  ${RED}${device}: ${dev_est}/${dev_expected} established  [only ${dev_learned}/${dev_expected} peers learned — link/peer missing?]${NC}"
            else
                echo -e "  ${YELLOW}${device}: ${dev_est}/${dev_expected} established  [${dev_learned} peers learned, $(( dev_learned - dev_est )) session(s) down]${NC}"
            fi
        done

    else
        echo -e "Total peers: ${BLUE}${total}${NC}  |  Established: ${GREEN}${established}${NC}  |  Not established: ${YELLOW}$(( total - established ))${NC}"
        echo

        local failures=() successes=() device_results=()
        IFS='~' read -r -a device_results <<< "$details"

        for entry in "${device_results[@]}"; do
            [[ -z "$entry" ]] && continue
            local device dev_est dev_learned
            IFS=':' read -r device dev_est dev_learned <<< "$entry"
            [[ $dev_learned -eq 0 ]] && continue
            [[ $dev_est -eq $dev_learned ]] && successes+=("$entry") || failures+=("$entry")
        done

        for entry in "${failures[@]}" "${successes[@]}"; do
            [[ -z "$entry" ]] && continue
            local device dev_est dev_learned
            IFS=':' read -r device dev_est dev_learned <<< "$entry"
            if [[ $dev_est -eq $dev_learned ]]; then
                echo -e "  ${GREEN}${device}: ${dev_est}/${dev_learned} established${NC}"
            else
                echo -e "  ${YELLOW}${device}: ${dev_est}/${dev_learned} established${NC}"
                # Show individual peer states for failing devices
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
    fi
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
            show_final_summary "$(check_all_bgp_sessions false)"
            return 1
        fi

        [[ "$verbose" == "true" ]] && echo -e "${CYAN}[${elapsed}s] Per-device status:${NC}" >&2

        local session_data established total
        session_data=$(check_all_bgp_sessions "$verbose")
        IFS=':' read -r established total _ <<< "$session_data"

        echo -e "${BLUE}[${elapsed}s/${timeout}s]${NC} BGP sessions: ${GREEN}${established}${NC}/${BLUE}${total}${NC} established  (${remaining}s remaining)"

        if [[ $total -gt 0 ]] && [[ $established -eq $total ]]; then
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

[[ ${#EXPECTED_PEERS[@]} -gt 0 ]] && MODE="baseline" || MODE="discovery"

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
