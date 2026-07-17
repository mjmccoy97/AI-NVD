#!/bin/bash

# Collect "info flat" configs from all SRLinux nodes in the two-stripe-rail-optimized topology.
# Saves each node's config to ../configs/srlinux/<node-name>.cfg -- the same files
# containerlab loads as startup-config at deploy time.

set -euo pipefail

RED='\033[0;31m'
NC='\033[0m'

OUTPUT_DIR="$(dirname "$0")/../configs/srlinux"
BACKUP_DIR="$(dirname "$0")/../configs/srlinux-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT_DIR"

echo -e "${RED}WARNING: this will overwrite the existing startup-config files in"
echo "$OUTPUT_DIR"
echo "with each node's current running config. This is what containerlab will"
echo "load on the next 'make deploy' -- any config drift on the live nodes that"
echo "hasn't been reviewed will become the new baseline."
echo -e "The existing files will be backed up first to $BACKUP_DIR${NC}"
read -r -p "Continue? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted. No files were changed."
    exit 0
fi
echo

if compgen -G "$OUTPUT_DIR"/*.cfg > /dev/null; then
    mkdir -p "$BACKUP_DIR"
    cp "$OUTPUT_DIR"/*.cfg "$BACKUP_DIR"/
    echo "Backed up existing configs to $BACKUP_DIR"
    echo
fi

declare -A NODES=(
    [spine1]=172.21.21.101
    [spine2]=172.21.21.102
    [stripe1-leaf1]=172.21.21.11
    [stripe1-leaf2]=172.21.21.12
    [stripe1-leaf3]=172.21.21.13
    [stripe1-leaf4]=172.21.21.14
    [stripe1-leaf5]=172.21.21.15
    [stripe1-leaf6]=172.21.21.16
    [stripe1-leaf7]=172.21.21.17
    [stripe1-leaf8]=172.21.21.18
    [stripe2-leaf1]=172.21.21.21
    [stripe2-leaf2]=172.21.21.22
    [stripe2-leaf3]=172.21.21.23
    [stripe2-leaf4]=172.21.21.24
    [stripe2-leaf5]=172.21.21.25
    [stripe2-leaf6]=172.21.21.26
    [stripe2-leaf7]=172.21.21.27
    [stripe2-leaf8]=172.21.21.28
    [frontend-spine1]=172.21.21.31
    [frontend-spine2]=172.21.21.32
    [frontend-leaf1]=172.21.21.33
    [frontend-leaf2]=172.21.21.34
)

SUCCESS=0
FAILED=0

for NODE in "${!NODES[@]}"; do
    OUTPUT_FILE="$OUTPUT_DIR/$NODE.cfg"
    echo -n "Collecting config from $NODE ... "
    if docker exec "aifab-$NODE" sr_cli "info flat" > "$OUTPUT_FILE" 2>&1; then
        echo "OK -> $OUTPUT_FILE"
        SUCCESS=$(( SUCCESS + 1 ))
    else
        echo "FAILED"
        rm -f "$OUTPUT_FILE"
        FAILED=$(( FAILED + 1 ))
    fi
done

echo ""
echo "Done: $SUCCESS succeeded, $FAILED failed."
