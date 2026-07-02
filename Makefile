.PHONY: deploy destroy reset status help up bgp-wait test-frontend test-backend test-all test-continuous test-lldp test-interfaces push-configs

deploy:
	containerlab deploy -t aifab.clab.yaml --reconfigure

destroy:
	containerlab destroy -t aifab.clab.yaml --cleanup

reset: destroy deploy

up:
	@echo "=== Starting full lab setup (Ctrl-C to cancel) ==="
	@$(MAKE) reset && $(MAKE) test-interfaces && $(MAKE) test-lldp && $(MAKE) bgp-wait && $(MAKE) test-lag && $(MAKE) test-connectivity

status:
	@containerlab inspect 2>&1 | grep -q "containers not found" && echo "Topology not deployed" || containerlab inspect


# Help target to show all available commands
help:
	@echo "Available targets:"
	@echo "  make deploy               	- Deploy the ContainerLab topology"
	@echo "  make destroy              	- Destroy the topology and cleanup"
	@echo "  make reset                	- Reset topology (destroy then deploy)"
	@echo "  make up                   	- Full lab setup (reset, bgp-wait, test-connectivity)"
	@echo "  make status               	- Check current topology status"
	@echo "  make help                 	- Show this help message"
	@echo "  make bgp-wait             	- Wait for all BGP sessions to become established"
	@echo "  make test-lldp            	- Verify LLDP neighbors match expected topology"
	@echo "  make test-interfaces      	- Verify all interfaces are up/up (includes client links)"
	@echo "  make test-frontend        	- Verify connectivity between the frontend clients and storage"
	@echo "  make test-backend        	- Verify connectivity between the backend compute clients"
	@echo "  make test-all			- Run comprehensive all-to-all connectivity tests on the front and back ends"
	@echo "  make test-continuous      	- Send continuous traffic on all frontend and backend pairs until Ctrl+C"
	@echo "  make push-configs         	- Push configurations to all SR Linux devices via JSON-RPC"


bgp-wait:
	@echo "=== Waiting for BGP Sessions to be Established ==="
	@./scripts/test-bgp.sh aifab.clab.yaml

# VLAN connectivity testing (comprehensive all-to-all)


test-connectivity:
	@echo "Testing all VLAN connectivity with comprehensive matrix..."
	@./scripts/test-connectivity.sh matrix

test-lldp:
	@echo "Verifying LLDP neighbors match expected topology..."
	@./scripts/test-lldp.sh aifab.clab.yaml

test-interfaces:
	@echo "Verifying all interfaces are up/up (includes client links)..."
	@./scripts/test-interfaces.sh aifab.clab.yaml -v

test-frontend:
	@echo "Testing connectivity between frontend clients and storage..."
	@./scripts/test-connectivity.sh test-frontend

test-backend:
	@echo "Testing connectivity between backend compute clients..."
	@./scripts/test-connectivity.sh test-backend

test-all:
	@echo "Running comprehensive all-to-all connectivity tests on the front and back ends..."
	@./scripts/test-connectivity.sh test-all

test-continuous:
	@echo "Sending continuous traffic on all frontend and backend pairs until Ctrl+C..."
	@./scripts/test-connectivity.sh test-continuous

push-configs:
	@echo "Pushing configurations to all SR Linux devices via JSON-RPC..."
	@./scripts/push-configs.sh


