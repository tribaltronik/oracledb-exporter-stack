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

test:
	@echo "Testing exporter metrics endpoint..."
	@curl -sS http://localhost:9161/metrics | head -50 || echo "FAILED: metrics endpoint not reachable"

test-verbose:
	@echo "Testing exporter metrics endpoint..."
	@curl -sS http://localhost:9161/metrics || echo "FAILED: metrics endpoint not reachable"

shell-ubi9:
	docker compose -f $(COMPOSE_FILE) exec ubi9-target bash

shell-oracle:
	docker compose -f $(COMPOSE_FILE) exec oracle-xe bash

status:
	docker compose -f $(COMPOSE_FILE) ps

clean: down
	docker compose -f $(COMPOSE_FILE) down -v
	docker rmi $$(docker images -q oracledb_exporter-ubi9-target 2>/dev/null) 2>/dev/null || true

ansible-test:
	@echo "Running Ansible role against UBI9 container..."
	@unset DOCKER_HOST && \
	docker compose -f $(COMPOSE_FILE) up -d oracle-xe ubi9-target && \
	TARGET_IP=$$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ubi9-target) && \
	echo "Target IP: $$TARGET_IP" && \
	ANSIBLE_HOST_KEY_CHECKING=False \
	ansible-playbook -i "$$TARGET_IP," \
	  -u root \
	  -e "ansible_ssh_pass=ansible" \
	  ansible/playbook.yml

health:
	@echo "Checking exporter health..."
	@curl -sS http://localhost:9161/ || echo "Not reachable"
	@echo ""
	@echo "Checking metrics..."
	@curl -sS http://localhost:9161/metrics | grep -E "(oracledb_up|process_cpu)" || echo "Metrics not available yet"

info:
	@echo "=== OracleDB Exporter Stack ==="
	@echo "Oracle XE:         http://localhost:1521"
	@echo "UBI9 SSH:          ssh root@localhost -p 2222 (password: ansible)"
	@echo "Provision:         make ansible-test"
