#!/bin/bash

# Connectivity test script for Cerebras EVPN lab
# Tests ping reachability between clients on the frontend and backend networks
# M. McCoy 5.12.26 Nokia

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Frontend network: all clients on 172.16.10.0/24
declare -A FRONTEND_STORAGE=(
    ["s1"]="172.16.10.1"
    ["s2"]="172.16.10.2"
    ["s3"]="172.16.10.3"
    ["s4"]="172.16.10.4"
)

# Backend network: compute clients on 172.16.10.0/24
declare -A BACKEND_CLIENTS=(
    ["weka1"]="172.16.10.11"
    ["weka2"]="172.16.10.12"
    ["weka3"]="172.16.10.13"
    ["weka4"]="172.16.10.14"
    ["weka5"]="172.16.10.15"
    ["weka6"]="172.16.10.16"
    ["weka7"]="172.16.10.17"
    ["weka8"]="172.16.10.18"
)

check_lab_deployed() {
    if ! containerlab inspect > /dev/null 2>&1; then
        echo -e "${RED}Error: Lab topology is not deployed. Run 'make deploy' first.${NC}"
        exit 1
    fi
}

run_ping_test() {
    local src_client="$1"
    local src_ip="$2"
    local target_ip="$3"
    docker exec "aifab-${src_client}" ping -s 1400 -c 2 -W 2 -I "$src_ip" "$target_ip" > /dev/null 2>&1
}

run_continuous_ping() {
    local src_client="$1"
    local src_ip="$2"
    local tgt="$3"
    local tgt_ip="$4"
    while true; do
        if docker exec "aifab-${src_client}" ping -s 1400 -c 1 -W 2 -I "$src_ip" "$tgt_ip" > /dev/null 2>&1; then
            echo -e "$(date '+%H:%M:%S') ${src_client} (${src_ip}) → ${tgt} (${tgt_ip}): ${GREEN}✓${NC}"
        else
            echo -e "$(date '+%H:%M:%S') ${src_client} (${src_ip}) → ${tgt} (${tgt_ip}): ${RED}✗ FAIL${NC}"
        fi
        sleep 1
    done
}

continuous_traffic() {
    echo -e "${BLUE}=== Continuous Traffic Mode ===${NC}"
    echo -e "${YELLOW}Sending traffic on frontend and backend networks. Press Ctrl+C to stop.${NC}"
    echo

    local -a pids=()

    cleanup() {
        echo
        echo -e "${YELLOW}Stopping continuous traffic...${NC}"
        for pid in "${pids[@]}"; do
            kill "$pid" 2>/dev/null
        done
        wait 2>/dev/null
        echo -e "${GREEN}Stopped.${NC}"
        exit 0
    }
    trap cleanup INT TERM

    # Launch continuous pings for frontend pairs
    local -a fe_names=("${!FRONTEND_STORAGE[@]}")
    for src in "${fe_names[@]}"; do
        for tgt in "${fe_names[@]}"; do
            [[ "$src" == "$tgt" ]] && continue
            run_continuous_ping "$src" "${FRONTEND_STORAGE[$src]}" "$tgt" "${FRONTEND_STORAGE[$tgt]}" &
            pids+=($!)
        done
    done

    # Launch continuous pings for backend pairs
    local -a be_names=("${!BACKEND_CLIENTS[@]}")
    for src in "${be_names[@]}"; do
        for tgt in "${be_names[@]}"; do
            [[ "$src" == "$tgt" ]] && continue
            run_continuous_ping "$src" "${BACKEND_CLIENTS[$src]}" "$tgt" "${BACKEND_CLIENTS[$tgt]}" &
            pids+=($!)
        done
    done

    wait
}

test_network() {
    local network_name="$1"
    local -n clients_ref=$2

    echo -e "${BLUE}=== Testing ${network_name} Connectivity ===${NC}"
    echo

    local -a client_names=("${!clients_ref[@]}")
    local -a test_pairs=()
    local -a pids=()
    local -a results=()

    # Generate all src→tgt pairs
    for src in "${client_names[@]}"; do
        for tgt in "${client_names[@]}"; do
            [[ "$src" == "$tgt" ]] && continue
            test_pairs+=("$src:${clients_ref[$src]}:$tgt:${clients_ref[$tgt]}")
        done
    done

    echo -e "${YELLOW}Running ${#test_pairs[@]} ping tests in parallel...${NC}"

    # Launch all pings in background
    for pair in "${test_pairs[@]}"; do
        IFS=':' read -r src src_ip tgt tgt_ip <<< "$pair"
        ( run_ping_test "$src" "$src_ip" "$tgt_ip" ) &
        pids+=($!)
    done

    # Collect exit codes in order
    for pid in "${pids[@]}"; do
        wait "$pid"
        results+=($?)
    done

    echo

    # Display results grouped by source client
    local passed=0
    local total=${#test_pairs[@]}
    local current_src=""

    for i in "${!test_pairs[@]}"; do
        IFS=':' read -r src src_ip tgt tgt_ip <<< "${test_pairs[$i]}"

        if [[ "$src" != "$current_src" ]]; then
            [[ -n "$current_src" ]] && echo
            echo -e "${YELLOW}From ${src} (${src_ip}):${NC}"
            current_src="$src"
        fi

        if [[ ${results[$i]} -eq 0 ]]; then
            echo -e "  → ${tgt} (${tgt_ip}): ${GREEN}✓ PASS${NC}"
            ((passed++))
        else
            echo -e "  → ${tgt} (${tgt_ip}): ${RED}✗ FAIL${NC}"
        fi
    done

    echo
    echo -e "${PURPLE}=== ${network_name} Summary ===${NC}"
    if [[ $passed -eq $total ]]; then
        echo -e "${GREEN}${passed}/${total} tests passed — all ${network_name} connectivity OK${NC}"
    else
        echo -e "${RED}${passed}/${total} tests passed — $((total - passed)) failure(s) detected${NC}"
    fi
    echo

    return $((total - passed))
}

show_help() {
    echo "Usage: $0 [OPTION]"
    echo "Test client connectivity in the Cerebras EVPN lab"
    echo
    echo "Options:"
    echo "  test-frontend   Test all clients on the frontend network (10.255.10.0/24)"
    echo "                  Devices: cs1, cs2, cs3, cs4, store1, store2"
    echo "  test-backend    Test compute clients on the backend network (100.255.20.0/25)"
    echo "                  Devices: cs1, cs2, cs3, cs4"
    echo "  test-all             Run both frontend and backend tests (default)"
    echo "  test-continuous      Send continuous traffic on all frontend and backend pairs until Ctrl+C"
    echo "  help            Show this help message"
}

case "${1:-all}" in
    "test-frontend")
        check_lab_deployed
        test_network "Frontend (172.16.10.0/24)" FRONTEND_STORAGE
        exit $?
        ;;
    "test-backend")
        check_lab_deployed
        test_network "Backend (172.16.10.0/24)" BACKEND_CLIENTS
        exit $?
        ;;
    "test-all")
        check_lab_deployed
        failures=0
        test_network "Frontend (172.16.10.0/24)" FRONTEND_STORAGE
        failures=$((failures + $?))
        test_network "Backend (172.16.10.0/24)" BACKEND_CLIENTS
        failures=$((failures + $?))
        if [[ $failures -eq 0 ]]; then
            echo -e "${GREEN}All connectivity tests passed!${NC}"
        else
            echo -e "${RED}${failures} connectivity test(s) failed.${NC}"
            exit 1
        fi
        ;;
    "test-continuous")
        check_lab_deployed
        continuous_traffic
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        echo -e "${RED}Invalid option: $1${NC}"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
