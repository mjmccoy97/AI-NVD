#!/bin/bash

# LLDP Neighbor Verification Script for EVPN Lab
# Verifies that LLDP neighbors match the expected topology defined in cs.clab.yml
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
TOPOLOGY_FILE="cs.clab.yml"
VERBOSE=false

# SR Linux devices (dynamically discovered)
DEVICES=()

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Verify LLDP neighbors against expected topology from cs.clab.yml"
    echo
    echo "Options:"
    echo "  -v, --verbose              Verbose output with detailed neighbor info"
    echo "  -f, --topology-file FILE   Topology YAML file (default: cs.clab.yml)"
    echo "  -h, --help                 Show this help message"
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

    # Convert to array
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

# Function to load expected neighbors from topology YAML
# Parses the links section of cs.clab.yml, converting containerlab interface
# notation (e1-1) to SR Linux format (ethernet-1/1), and prefixing linux node
# hostnames with clab-cs- to match what they advertise via LLDP.
load_topology() {
    local topology_file="$1"

    if [[ ! -f "$topology_file" ]]; then
        echo -e "${RED}Error: Topology file '$topology_file' not found${NC}"
        exit 1
    fi

    declare -g -A EXPECTED_NEIGHBORS

    local srlinux_set=" ${DEVICES[*]} "
    local pattern="endpoints.*'([^:]+):([^']+)'.*'([^:]+):([^']+)'"

    while IFS= read -r line; do
        if [[ "$line" =~ $pattern ]]; then
            local node1="${BASH_REMATCH[1]}"
            local iface1="${BASH_REMATCH[2]}"
            local node2="${BASH_REMATCH[3]}"
            local iface2="${BASH_REMATCH[4]}"

            # Convert e1-1 -> ethernet-1/1 for SR Linux interfaces
            local srlinux_iface1 srlinux_iface2
            srlinux_iface1=$(echo "$iface1" | sed 's/^e\([0-9]*\)-\([0-9]*\)$/ethernet-\1\/\2/')
            srlinux_iface2=$(echo "$iface2" | sed 's/^e\([0-9]*\)-\([0-9]*\)$/ethernet-\1\/\2/')

            local node1_is_srlinux=false node2_is_srlinux=false
            [[ "$srlinux_set" == *" $node1 "* ]] && node1_is_srlinux=true
            [[ "$srlinux_set" == *" $node2 "* ]] && node2_is_srlinux=true

            # Linux nodes advertise clab-cs-<name> as their LLDP system-name
            local sys1 sys2
            if [[ "$node1_is_srlinux" == true ]]; then sys1="$node1"; else sys1="clab-cs-$node1"; fi
            if [[ "$node2_is_srlinux" == true ]]; then sys2="$node2"; else sys2="clab-cs-$node2"; fi

            # Add an expected neighbor entry for each SR Linux endpoint
            if [[ "$node1_is_srlinux" == true ]]; then
                EXPECTED_NEIGHBORS["$node1:$srlinux_iface1"]="$sys2:$iface2"
            fi
            if [[ "$node2_is_srlinux" == true ]]; then
                EXPECTED_NEIGHBORS["$node2:$srlinux_iface2"]="$sys1:$iface1"
            fi
        fi
    done < "$topology_file"

    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}Loaded ${#EXPECTED_NEIGHBORS[@]} expected neighbor relationships from topology${NC}"
    fi
}

# Function to get LLDP neighbors for a device using JSON-RPC
get_lldp_neighbors() {
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
                        "path": "/system/lldp",
                        "datastore": "state"
                    }
                ]
            }
        }' 2>/dev/null)

    if [[ -z "$response" ]]; then
        echo "ERROR_CONNECTION"
        return 1
    fi

    # Format: interface:remote_system_name:remote_port_id
    echo "$response" | jq -r '
        if .result and .result[0] and .result[0].interface then
            .result[0].interface[] |
            select(.name != "mgmt0") |
            if .neighbor then
                .neighbor[] as $neighbor |
                "\(.name):\($neighbor["system-name"] // "unknown"):\($neighbor["port-id"] // "unknown")"
            else
                empty
            end
        else
            empty
        end
    ' 2>/dev/null || echo "ERROR_PARSE"
}

# Function to verify LLDP neighbors for all devices
verify_lldp_neighbors() {
    local total_checks=0
    local passed_checks=0
    local failed_checks=0
    local missing_checks=0

    echo -e "${PURPLE}=== LLDP Neighbor Verification ===${NC}"
    echo

    declare -A seen_neighbors

    for device in "${DEVICES[@]}"; do
        echo -e "${BLUE}Checking $device...${NC}"

        local neighbors_info
        neighbors_info=$(get_lldp_neighbors "$device")

        if [[ "$neighbors_info" == "ERROR_CONNECTION" ]]; then
            echo -e "${RED}  Connection failed${NC}"
            continue
        elif [[ "$neighbors_info" == "ERROR_PARSE" ]]; then
            echo -e "${RED}  Parse error${NC}"
            continue
        fi

        # Reset per-device seen tracker
        seen_neighbors=()

        if [[ -n "$neighbors_info" ]]; then
            while IFS= read -r neighbor_line; do
                if [[ -n "$neighbor_line" ]]; then
                    IFS=':' read -r interface remote_system remote_port <<< "$neighbor_line"

                    local expected="${EXPECTED_NEIGHBORS["$device:$interface"]}"

                    if [[ -n "$expected" ]]; then
                        IFS=':' read -r expected_device expected_interface <<< "$expected"
                        seen_neighbors["$device:$interface"]="seen"

                        if [[ "$remote_system" == "$expected_device" ]]; then
                            echo -e "  ${GREEN}✓ $interface → $remote_system:$remote_port (expected: $expected)${NC}"
                            ((passed_checks++))
                        else
                            echo -e "  ${RED}✗ $interface → $remote_system:$remote_port (expected: $expected)${NC}"
                            ((failed_checks++))
                        fi
                    else
                        echo -e "  ${YELLOW}? $interface → $remote_system:$remote_port (not in topology)${NC}"
                    fi

                    ((total_checks++))
                fi
            done <<< "$neighbors_info"
        fi

        # Check for expected neighbors that were not seen
        for expected_key in "${!EXPECTED_NEIGHBORS[@]}"; do
            IFS=':' read -r exp_device exp_interface <<< "$expected_key"

            if [[ "$exp_device" == "$device" ]] && [[ -z "${seen_neighbors[$expected_key]}" ]]; then
                local expected_neighbor="${EXPECTED_NEIGHBORS[$expected_key]}"
                echo -e "  ${YELLOW}? $exp_interface → MISSING (expected: $expected_neighbor — end device may not be running LLDP)${NC}"
                ((missing_checks++))
                ((total_checks++))
            fi
        done

        echo
    done

    echo -e "${PURPLE}=== Verification Summary ===${NC}"
    echo -e "Total checks: ${BLUE}$total_checks${NC}"
    echo -e "Passed: ${GREEN}$passed_checks${NC}"
    echo -e "Failed: ${RED}$failed_checks${NC}"
    echo -e "Missing: ${RED}$missing_checks${NC}"

    if [[ $failed_checks -eq 0 ]] && [[ $missing_checks -eq 0 ]]; then
        echo -e "${GREEN}All LLDP neighbors match the expected topology!${NC}"
        return 0
    elif [[ $failed_checks -eq 0 ]]; then
        echo -e "${YELLOW}Warning: $missing_checks neighbor(s) not seen — end devices may not be running LLDP${NC}"
        echo -e "${GREEN}No incorrect LLDP neighbors detected.${NC}"
        return 0
    else
        echo -e "${RED}LLDP verification failed - topology mismatch detected${NC}"
        return 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -f|--topology-file)
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

# Load topology
load_topology "$TOPOLOGY_FILE"

# Show configuration
echo -e "${PURPLE}=== LLDP Verification Settings ===${NC}"
echo -e "Topology file: $TOPOLOGY_FILE"
echo

# Start verification
if verify_lldp_neighbors; then
    echo -e "${GREEN}Success: All LLDP neighbors verified!${NC}"
    exit 0
else
    echo -e "${RED}Failed: LLDP verification detected issues${NC}"
    exit 1
fi
