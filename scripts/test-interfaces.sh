#!/bin/bash

# Interface Status Verification Script for Containerlab Lab
# Verifies all SR Linux interfaces listed in the topology links are up/up
# Ignores client, telemetry, and management interfaces
# M. McCoy 5.12.26 Nokia

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
VERBOSE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPOLOGY_FILE="${SCRIPT_DIR}/../cs.clab.yml"

# SR Linux devices (dynamically discovered)
DEVICES=()

# Per-device interface lists parsed from topology links (device -> "iface1 iface2 ...")
declare -A TOPOLOGY_INTERFACES

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Verify all SR Linux interfaces from the topology links section are up/up"
    echo
    echo "Options:"
    echo "  -v, --verbose           Verbose output with per-interface details"
    echo "  -f, --file FILE         Topology file (default: ../poc.clab.yml)"
    echo "  -h, --help              Show this help message"
    echo
    echo "Examples:"
    echo "  $0                      # Run with default settings"
    echo "  $0 -v                   # Run with verbose output"
}

# Function to discover SR Linux devices dynamically
discover_srlinux_devices() {
    local devices_json
    devices_json=$(containerlab inspect --format json 2>/dev/null | jq -r 'to_entries[].value[] | select(.kind == "nokia_srlinux") | .name' | sed 's/^clab-cs-//')

    if [[ -z "$devices_json" ]]; then
        echo -e "${RED}Error: No SR Linux devices found in the topology${NC}"
        exit 1
    fi

    readarray -t DEVICES <<< "$devices_json"

    echo -e "${CYAN}Discovered ${#DEVICES[@]} SR Linux devices: ${DEVICES[*]}${NC}"
}

# Function to check if lab is deployed and discover devices
check_lab_deployed() {
    if ! containerlab inspect > /dev/null 2>&1; then
        echo -e "${RED}Error: Lab topology is not deployed. Run 'make deploy' first.${NC}"
        exit 1
    fi

    discover_srlinux_devices
}

# Function to check if a name belongs to a discovered SR Linux device
is_srlinux_device() {
    local name="$1"
    for dev in "${DEVICES[@]}"; do
        if [[ "$dev" == "$name" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to load interface lists from the topology links section
load_topology_interfaces() {
    if [[ ! -f "$TOPOLOGY_FILE" ]]; then
        echo -e "${RED}Error: Topology file '$TOPOLOGY_FILE' not found${NC}"
        exit 1
    fi

    # Extract all endpoint pairs from the links section.
    # Each link line looks like: - endpoints: [ 'device:eX-Y', 'device:eX-Y' ]
    # grep -oE extracts each quoted token; we then split on ':' and convert
    # eX-Y notation to ethernet-X/Y for the SR Linux JSON-RPC path.
    while IFS= read -r endpoint; do
        IFS=':' read -r device iface <<< "$endpoint"
        if is_srlinux_device "$device"; then
            # Convert e1-1 -> ethernet-1/1
            local eth_iface
            eth_iface=$(echo "$iface" | sed "s/e\([0-9]*\)-\([0-9]*\)/ethernet-\1\/\2/")
            if [[ -z "${TOPOLOGY_INTERFACES[$device]}" ]]; then
                TOPOLOGY_INTERFACES[$device]="$eth_iface"
            else
                TOPOLOGY_INTERFACES[$device]+=" $eth_iface"
            fi
        fi
    done < <(grep -E "endpoints:" "$TOPOLOGY_FILE" | grep -oE "'[^']+'" | tr -d "'")

    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}Loaded topology interface lists for ${#TOPOLOGY_INTERFACES[@]} devices${NC}"
    fi
}

# Function to get all interfaces for an SR Linux device using JSON-RPC
get_srlinux_interfaces() {
    local device="$1"
    local url="http://clab-cs-${device}/jsonrpc"

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
                        "path": "/interface[name=*]",
                        "datastore": "state"
                    }
                ]
            }
        }' 2>/dev/null)

    if [[ -z "$response" ]]; then
        echo "ERROR_CONNECTION"
        return 1
    fi

    # Format: name:admin-state:oper-state
    echo "$response" | jq -r '
        if .result and .result[0] and .result[0]["srl_nokia-interfaces:interface"] then
            .result[0]["srl_nokia-interfaces:interface"][] |
            .name + ":" + (.["admin-state"] // "unknown") + ":" + (.["oper-state"] // "unknown")
        else
            empty
        end
    ' 2>/dev/null || echo "ERROR_PARSE"
}

# Function to check if an interface name is in the topology list for a device
is_topology_interface() {
    local device="$1"
    local iface="$2"
    local iface_list="${TOPOLOGY_INTERFACES[$device]}"

    for entry in $iface_list; do
        if [[ "$entry" == "$iface" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to verify interfaces on all SR Linux devices
verify_srlinux_interfaces() {
    local -n total_ref=$1
    local -n passed_ref=$2
    local -n failed_ref=$3

    echo -e "${PURPLE}=== SR Linux Interface Verification ===${NC}"
    echo

    for device in "${DEVICES[@]}"; do
        local expected_ifaces="${TOPOLOGY_INTERFACES[$device]}"

        if [[ -z "$expected_ifaces" ]]; then
            echo -e "${BLUE}$device${NC}: ${YELLOW}no topology links defined, skipping${NC}"
            echo
            continue
        fi

        echo -e "${BLUE}Checking $device...${NC}"

        local iface_info
        iface_info=$(get_srlinux_interfaces "$device")

        if [[ "$iface_info" == "ERROR_CONNECTION" ]]; then
            echo -e "  ${RED}Connection failed${NC}"
            echo
            continue
        elif [[ "$iface_info" == "ERROR_PARSE" ]]; then
            echo -e "  ${RED}Parse error${NC}"
            echo
            continue
        fi

        # Index queried interfaces by name for quick lookup
        declare -A iface_map
        while IFS= read -r iface_line; do
            [[ -z "$iface_line" ]] && continue
            IFS=':' read -r iface_name admin_state oper_state <<< "$iface_line"
            iface_map[$iface_name]="$admin_state:$oper_state"
        done <<< "$iface_info"

        local device_passed=0
        local device_failed=0

        for expected in $expected_ifaces; do
            ((total_ref++))
            local states="${iface_map[$expected]}"

            if [[ -z "$states" ]]; then
                # Interface not returned at all
                ((failed_ref++))
                ((device_failed++))
                echo -e "  ${RED}✗ $expected: not found${NC}"
                continue
            fi

            IFS=':' read -r admin_state oper_state <<< "$states"

            if [[ "$admin_state" == "enable" && "$oper_state" == "up" ]]; then
                ((passed_ref++))
                ((device_passed++))
                if [[ "$VERBOSE" == "true" ]]; then
                    echo -e "  ${GREEN}✓ $expected: $admin_state/$oper_state${NC}"
                fi
            else
                ((failed_ref++))
                ((device_failed++))
                echo -e "  ${RED}✗ $expected: $admin_state/$oper_state${NC}"
            fi
        done

        unset iface_map

        if [[ $device_failed -eq 0 ]]; then
            echo -e "  ${GREEN}All $device_passed interfaces up/up${NC}"
        else
            echo -e "  ${YELLOW}$device_passed passed, $device_failed failed${NC}"
        fi
        echo
    done
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -f|--file)
            TOPOLOGY_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
done

# Check if required tools are available
for tool in curl jq; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${RED}Error: Required tool '$tool' is not installed${NC}"
        exit 1
    fi
done

# Check if lab is deployed
check_lab_deployed

# Load interface lists from topology file
load_topology_interfaces

# Show configuration
echo -e "${PURPLE}=== Interface Verification Settings ===${NC}"
echo -e "Topology file: $TOPOLOGY_FILE"
echo -e "Verbose: $VERBOSE"
echo

# Run verification
total_interfaces=0
passed_interfaces=0
failed_interfaces=0

verify_srlinux_interfaces total_interfaces passed_interfaces failed_interfaces

# Summary
echo -e "${PURPLE}=== Interface Verification Summary ===${NC}"
echo -e "Total interfaces checked: ${BLUE}$total_interfaces${NC}"
echo -e "Up/up: ${GREEN}$passed_interfaces${NC}"
echo -e "Not up/up: ${RED}$failed_interfaces${NC}"
echo

if [[ $failed_interfaces -eq 0 ]] && [[ $total_interfaces -gt 0 ]]; then
    echo -e "${GREEN}Success: All interfaces are up/up!${NC}"
    exit 0
elif [[ $total_interfaces -eq 0 ]]; then
    echo -e "${YELLOW}Warning: No interfaces found to check${NC}"
    exit 1
else
    echo -e "${RED}Failed: $failed_interfaces interface(s) are not up/up${NC}"
    exit 1
fi
