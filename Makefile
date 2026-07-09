.PHONY: all build up down rebuild logs test shell-ubi9 shell-oracle clean

unexport DOCKER_HOST

EXPORTER_VERSION ?= 1.6.0
COMPOSE_FILE ?= docker-compose.yml

all: build

build:
	docker compose -f $(COMPOSE_FILE) build

up:
	docker compose -f $(COMPOSE_FILE) up -d

down:
	docker compose -f $(COMPOSE_FILE) down

rebuild: down build up

logs:
	docker compose -f $(COMPOSE_FILE) logs -f

logs-exporter:
	docker compose -f $(COMPOSE_FILE) logs -f ubi9-target

test-xe1:
	@echo "Testing exporter xe1 metrics endpoint..."
	@curl -sS http://localhost:9161/metrics | head -30 || echo "FAILED: xe1 metrics endpoint not reachable"

test-xe2:
	@echo "Testing exporter xe2 metrics endpoint..."
	@curl -sS http://localhost:9162/metrics | head -30 || echo "FAILED: xe2 metrics endpoint not reachable"

test: test-xe1 test-xe2

test-verbose:
	@echo "Testing exporter xe1 metrics endpoint..."
	@curl -sS http://localhost:9161/metrics || echo "FAILED: xe1 metrics endpoint not reachable"
	@echo "---"
	@echo "Testing exporter xe2 metrics endpoint..."
	@curl -sS http://localhost:9162/metrics || echo "FAILED: xe2 metrics endpoint not reachable"

shell-ubi9:
	docker compose -f $(COMPOSE_FILE) exec ubi9-target bash

shell-oracle:
	docker compose -f $(COMPOSE_FILE) exec oracle-xe bash

shell-oracle-2:
	docker compose -f $(COMPOSE_FILE) exec oracle-xe-2 bash

status:
	docker compose -f $(COMPOSE_FILE) ps

clean: down
	docker compose -f $(COMPOSE_FILE) down -v
	docker rmi $$(docker images -q oracledb_exporter-ubi9-target 2>/dev/null) 2>/dev/null || true

ansible-test:
	@echo "Running Ansible role against UBI9 container..."
	@unset DOCKER_HOST && \
	docker compose -f $(COMPOSE_FILE) up -d oracle-xe oracle-xe-2 ubi9-target && \
	TARGET_IP=$$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ubi9-target) && \
	echo "Target IP: $$TARGET_IP" && \
	ANSIBLE_HOST_KEY_CHECKING=False \
	ansible-playbook -i "$$TARGET_IP," \
	  -u root \
	  -e "ansible_ssh_pass=ansible" \
	  ansible/playbook.yml

health:
	@echo "=== Exporter Health ==="
	@echo "--- xe1 (9161) ---"
	@curl -sS http://localhost:9161/ || echo "Not reachable"
	@echo ""
	@curl -sS http://localhost:9161/metrics | grep -E "(oracledb_up|process_cpu)" || echo "Metrics not available"
	@echo ""
	@echo "--- xe2 (9162) ---"
	@curl -sS http://localhost:9162/ || echo "Not reachable"
	@echo ""
	@curl -sS http://localhost:9162/metrics | grep -E "(oracledb_up|process_cpu)" || echo "Metrics not available"

info:
	@echo "=== OracleDB Exporter Stack ==="
	@echo "Oracle XE (xe1):   localhost:1521"
	@echo "Oracle XE (xe2):   localhost:1522"
	@echo "xe1 metrics:       http://localhost:9161/metrics"
	@echo "xe2 metrics:       http://localhost:9162/metrics"
	@echo "UBI9 SSH:          ssh root@localhost -p 2222 (password: ansible)"
	@echo "Provision:         make ansible-test"
