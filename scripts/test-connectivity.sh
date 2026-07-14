#!/bin/bash

# Connectivity test script for AI-FAB lab
# Tests ping reachability between clients on the frontend and backend networks
# M. McCoy 5.12.26 Nokia

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Frontend network (storage servers): all clients on 172.16.10.0/24
declare -A FRONTEND_STORAGE=(
    ["s1"]="172.16.10.1"
    ["s2"]="172.16.10.2"
    ["s3"]="172.16.10.3"
    ["s4"]="172.16.10.4"
)

# Frontend network (Weka storage clients): also on 172.16.10.0/24, bridged into the
# same frontend L2 domain (mac-vrf-storage) via frontend-leaf1/frontend-leaf2
declare -A FRONTEND_STORAGE_WEKA=(
    ["weka1"]="172.16.10.11"
    ["weka2"]="172.16.10.12"
    ["weka3"]="172.16.10.13"
    ["weka4"]="172.16.10.14"
    ["weka5"]="172.16.10.15"
    ["weka6"]="172.16.10.16"
    ["weka7"]="172.16.10.17"
    ["weka8"]="172.16.10.18"
)

# Backend network (rail-optimized): each storage server has a dedicated routed IPv6
# link per rail straight to a stripe leaf switch. s1/s2 ride stripe1 (leaf 1-8),
# s3/s4 ride stripe2 (leaf 9-16). Keys are "<node>:<rail>".
declare -A BACKEND_RAILS=(
    ["s1:1"]="fd00:100:1:1:0:3:0:2"   ["s1:2"]="fd00:100:2:1:0:3:0:2"   ["s1:3"]="fd00:100:3:1:0:3:0:2"   ["s1:4"]="fd00:100:4:1:0:3:0:2"
    ["s1:5"]="fd00:100:5:1:0:3:0:2"   ["s1:6"]="fd00:100:6:1:0:3:0:2"   ["s1:7"]="fd00:100:7:1:0:3:0:2"   ["s1:8"]="fd00:100:8:1:0:3:0:2"
    ["s2:1"]="fd00:100:1:1:0:4:0:2"   ["s2:2"]="fd00:100:2:1:0:4:0:2"   ["s2:3"]="fd00:100:3:1:0:4:0:2"   ["s2:4"]="fd00:100:4:1:0:4:0:2"
    ["s2:5"]="fd00:100:5:1:0:4:0:2"   ["s2:6"]="fd00:100:6:1:0:4:0:2"   ["s2:7"]="fd00:100:7:1:0:4:0:2"   ["s2:8"]="fd00:100:8:1:0:4:0:2"
    ["s3:1"]="fd00:200:9:1:0:3:0:2"   ["s3:2"]="fd00:200:10:1:0:3:0:2"  ["s3:3"]="fd00:200:11:1:0:3:0:2"  ["s3:4"]="fd00:200:12:1:0:3:0:2"
    ["s3:5"]="fd00:200:13:1:0:3:0:2"  ["s3:6"]="fd00:200:14:1:0:3:0:2"  ["s3:7"]="fd00:200:15:1:0:3:0:2"  ["s3:8"]="fd00:200:16:1:0:3:0:2"
    ["s4:1"]="fd00:200:9:1:0:4:0:2"   ["s4:2"]="fd00:200:10:1:0:4:0:2"  ["s4:3"]="fd00:200:11:1:0:4:0:2"  ["s4:4"]="fd00:200:12:1:0:4:0:2"
    ["s4:5"]="fd00:200:13:1:0:4:0:2"  ["s4:6"]="fd00:200:14:1:0:4:0:2"  ["s4:7"]="fd00:200:15:1:0:4:0:2"  ["s4:8"]="fd00:200:16:1:0:4:0:2"
)
BACKEND_RAIL_NODES=(s1 s2 s3 s4)
# stripe1 rides leaf 1-8, stripe2 rides leaf 9-16 (see BACKEND_RAILS above)
BACKEND_STRIPE1_NODES=(s1 s2)
BACKEND_STRIPE2_NODES=(s3 s4)

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

run_ping_test_v6() {
    local src_client="$1"
    local src_ip="$2"
    local target_ip="$3"
    docker exec "aifab-${src_client}" ping -6 -s 1400 -c 2 -W 2 -I "$src_ip" "$target_ip" > /dev/null 2>&1
}

run_continuous_ping() {
    local src_client="$1"
    local src_ip="$2"
    local tgt="$3"
    local tgt_ip="$4"
    local v6_flag="${5:-}"
    while true; do
        if docker exec "aifab-${src_client}" ping $v6_flag -s 1400 -c 1 -W 2 -I "$src_ip" "$tgt_ip" > /dev/null 2>&1; then
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

    # Launch continuous pings for frontend storage pairs
    local -a fe_names=("${!FRONTEND_STORAGE[@]}")
    for src in "${fe_names[@]}"; do
        for tgt in "${fe_names[@]}"; do
            [[ "$src" == "$tgt" ]] && continue
            run_continuous_ping "$src" "${FRONTEND_STORAGE[$src]}" "$tgt" "${FRONTEND_STORAGE[$tgt]}" &
            pids+=($!)
        done
    done

    # Launch continuous pings for frontend Weka pairs
    local -a weka_names=("${!FRONTEND_STORAGE_WEKA[@]}")
    for src in "${weka_names[@]}"; do
        for tgt in "${weka_names[@]}"; do
            [[ "$src" == "$tgt" ]] && continue
            run_continuous_ping "$src" "${FRONTEND_STORAGE_WEKA[$src]}" "$tgt" "${FRONTEND_STORAGE_WEKA[$tgt]}" &
            pids+=($!)
        done
    done

    # Launch continuous pings for backend rail pairs (intra- and inter-stripe)
    for rail in 1 2 3 4 5 6 7 8; do
        for src in "${BACKEND_RAIL_NODES[@]}"; do
            for tgt in "${BACKEND_RAIL_NODES[@]}"; do
                [[ "$src" == "$tgt" ]] && continue
                run_continuous_ping "$src" "${BACKEND_RAILS[${src}:${rail}]}" "$tgt" "${BACKEND_RAILS[${tgt}:${rail}]}" "-6" &
                pids+=($!)
            done
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

# Runs a pre-built set of "src|src_ip|tgt|tgt_ip|rail" backend pairs (pipe-delimited
# since IPv6 addresses contain colons), grouped and reported by rail.
run_backend_pair_tests() {
    local label="$1"
    local -n pairs_ref=$2

    echo -e "${BLUE}=== Testing Backend ${label} Connectivity ===${NC}"
    echo

    local -a pids=()
    local -a results=()

    echo -e "${YELLOW}Running ${#pairs_ref[@]} ping tests in parallel...${NC}"

    for pair in "${pairs_ref[@]}"; do
        IFS='|' read -r src src_ip tgt tgt_ip rail <<< "$pair"
        ( run_ping_test_v6 "$src" "$src_ip" "$tgt_ip" ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid"
        results+=($?)
    done

    echo

    local passed=0
    local total=${#pairs_ref[@]}
    local current_rail=""

    for i in "${!pairs_ref[@]}"; do
        IFS='|' read -r src src_ip tgt tgt_ip rail <<< "${pairs_ref[$i]}"

        if [[ "$rail" != "$current_rail" ]]; then
            [[ -n "$current_rail" ]] && echo
            echo -e "${YELLOW}Rail ${rail}:${NC}"
            current_rail="$rail"
        fi

        if [[ ${results[$i]} -eq 0 ]]; then
            echo -e "  ${src} (${src_ip}) → ${tgt} (${tgt_ip}): ${GREEN}✓ PASS${NC}"
            ((passed++))
        else
            echo -e "  ${src} (${src_ip}) → ${tgt} (${tgt_ip}): ${RED}✗ FAIL${NC}"
        fi
    done

    echo
    echo -e "${PURPLE}=== Backend ${label} Summary ===${NC}"
    if [[ $passed -eq $total ]]; then
        echo -e "${GREEN}${passed}/${total} tests passed — all backend ${label} connectivity OK${NC}"
    else
        echo -e "${RED}${passed}/${total} tests passed — $((total - passed)) failure(s) detected${NC}"
    fi
    echo

    return $((total - passed))
}

# Intra-stripe: pairs that share a leaf (s1<->s2 on stripe1, s3<->s4 on stripe2).
# These stay within a single leaf's all-rails VRF and never cross the spine.
test_backend_intra_stripe() {
    local -a test_pairs=()

    for rail in 1 2 3 4 5 6 7 8; do
        for src in "${BACKEND_STRIPE1_NODES[@]}"; do
            for tgt in "${BACKEND_STRIPE1_NODES[@]}"; do
                [[ "$src" == "$tgt" ]] && continue
                test_pairs+=("${src}|${BACKEND_RAILS[${src}:${rail}]}|${tgt}|${BACKEND_RAILS[${tgt}:${rail}]}|${rail}")
            done
        done
        for src in "${BACKEND_STRIPE2_NODES[@]}"; do
            for tgt in "${BACKEND_STRIPE2_NODES[@]}"; do
                [[ "$src" == "$tgt" ]] && continue
                test_pairs+=("${src}|${BACKEND_RAILS[${src}:${rail}]}|${tgt}|${BACKEND_RAILS[${tgt}:${rail}]}|${rail}")
            done
        done
    done

    run_backend_pair_tests "Intra-Stripe" test_pairs
}

# Inter-stripe: pairs that cross from stripe1 (s1/s2) to stripe2 (s3/s4), which
# requires transiting a spine and a second leaf's all-rails VRF.
test_backend_inter_stripe() {
    local -a test_pairs=()

    for rail in 1 2 3 4 5 6 7 8; do
        for src in "${BACKEND_STRIPE1_NODES[@]}"; do
            for tgt in "${BACKEND_STRIPE2_NODES[@]}"; do
                test_pairs+=("${src}|${BACKEND_RAILS[${src}:${rail}]}|${tgt}|${BACKEND_RAILS[${tgt}:${rail}]}|${rail}")
                test_pairs+=("${tgt}|${BACKEND_RAILS[${tgt}:${rail}]}|${src}|${BACKEND_RAILS[${src}:${rail}]}|${rail}")
            done
        done
    done

    run_backend_pair_tests "Inter-Stripe" test_pairs
}

test_backend_rails() {
    local failures=0
    test_backend_intra_stripe
    failures=$((failures + $?))
    test_backend_inter_stripe
    failures=$((failures + $?))
    return $failures
}

show_help() {
    echo "Usage: $0 [OPTION]"
    echo "Test client connectivity in the AI-FAB lab"
    echo
    echo "Options:"
    echo "  test-frontend         Test storage clients on the frontend network (172.16.10.0/24)"
    echo "                        Devices: s1, s2, s3, s4"
    echo "  test-frontend-weka    Test Weka storage clients on the frontend network (172.16.10.0/24)"
    echo "                        Devices: weka1-weka8"
    echo "  test-backend-intra    Test rail-optimized IPv6 backend links within a stripe"
    echo "                        (s1<->s2 on stripe1, s3<->s4 on stripe2; stays within one leaf)"
    echo "  test-backend-inter    Test rail-optimized IPv6 backend links across stripes"
    echo "                        (s1/s2 <-> s3/s4; transits spine to a second leaf)"
    echo "  test-backend          Run both backend tests (intra- and inter-stripe)"
    echo "  test-all              Run frontend, frontend-weka, and both backend tests (default)"
    echo "  test-continuous       Send continuous traffic on all frontend and backend pairs until Ctrl+C"
    echo "  help                  Show this help message"
}

case "${1:-test-all}" in
    "test-frontend")
        check_lab_deployed
        test_network "Frontend (172.16.10.0/24)" FRONTEND_STORAGE
        exit $?
        ;;
    "test-frontend-weka")
        check_lab_deployed
        test_network "Frontend Weka (172.16.10.0/24)" FRONTEND_STORAGE_WEKA
        exit $?
        ;;
    "test-backend-intra")
        check_lab_deployed
        test_backend_intra_stripe
        exit $?
        ;;
    "test-backend-inter")
        check_lab_deployed
        test_backend_inter_stripe
        exit $?
        ;;
    "test-backend")
        check_lab_deployed
        test_backend_rails
        exit $?
        ;;
    "test-all")
        check_lab_deployed
        failures=0
        test_network "Frontend (172.16.10.0/24)" FRONTEND_STORAGE
        failures=$((failures + $?))
        test_network "Frontend Weka (172.16.10.0/24)" FRONTEND_STORAGE_WEKA
        failures=$((failures + $?))
        test_backend_intra_stripe
        failures=$((failures + $?))
        test_backend_inter_stripe
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
