# OracleDB Exporter Stack

Docker Compose stack with Oracle XE 21c + UBI9 target provisioned via Ansible to run [oracledb_exporter](https://github.com/oracle/oracle-db-appdev-monitoring) v1.6.0.

## Quick Start

```bash
make up         # Start Oracle XE + UBI9
make ansible-test  # Provision exporter via Ansible
```

Exporters are then available at `http://localhost:9161/metrics` (xe1) and `http://localhost:9162/metrics` (xe2).

## Stack

| Service | Image | Ports |
|---|---|---|
| `oracle-xe` | `gvenzl/oracle-xe:21-slim-faststart` | `1521` |
| `oracle-xe-2` | `gvenzl/oracle-xe:21-slim-faststart` | `1522` |
| `ubi9-target` | `redhat/ubi9:latest` | `2222` (SSH), `9161` (exporter xe1), `9162` (exporter xe2) |

## Usage

```bash
make build         # Build UBI9 image
make up            # Start all services
make down          # Stop all services
make rebuild       # down + build + up
make logs          # Tail all logs
make test          # Quick metrics check (xe1 + xe2)
make test-xe1      # Check xe1 metrics only
make test-xe2      # Check xe2 metrics only
make ansible-test  # (Re)provision exporter via Ansible
make shell-ubi9    # SSH into UBI9 (docker exec)
make shell-oracle  # SQL*Plus into Oracle XE (xe1)
make shell-oracle-2 # SQL*Plus into Oracle XE (xe2)
make health        # Check exporter status (both)
make clean         # Stop + remove volumes + image
make info          # Show stack info
```

## Architecture

1. **Docker Compose** starts two Oracle XE containers and a minimal UBI9 container (SSH only)
2. **Ansible** connects via SSH (`root:ansible` on port `2222`) and provisions:
   - Oracle Instant Client Basic 21.11 (RPM)
   - oracledb_exporter v1.6.0 binary
   - Exporter user, directories, environment
   - Per-instance config, nohup wrappers, and metrics endpoint per database
3. Each exporter instance connects to its database and serves metrics on its own port (`:9161` for xe1, `:9162` for xe2)

## Provisioning

The Ansible playbook at `ansible/playbook.yml` handles the full installation:

```bash
make ansible-test
```

Or manually:

```bash
ssh root@localhost -p 2222
# password: ansible
```

## Ansible Role

Located at `ansible/roles/oracledb_exporter/`:

- `defaults/main.yml` — configurable variables, `oracle_exporter_instances` list
- `tasks/main.yml` — shared + per-instance looped tasks (21 tasks)
- `templates/` — 4 templates: systemd unit, nohup wrapper, env file, metrics TOML

## Files

```
├── docker-compose.yml          # Stack definition (2 Oracle XE + UBI9)
├── Makefile                    # Orchestration targets
├── healthcheck.sql             # Oracle healthcheck query
├── init-grants.sql             # DB grants for xe1
├── init-grants2.sql            # DB grants for xe2
├── ubi9/Dockerfile             # Minimal SSH-only UBI9 image
├── docs/
│   ├── prd.md                  # Product requirements
│   └── spec.md                 # Full specification
└── ansible/
    ├── playbook.yml            # Ansible playbook (multi-instance)
    └── roles/oracledb_exporter/ # Ansible role
```


