# OracleDB Exporter Stack

Docker Compose stack with Oracle XE 21c + UBI9 target provisioned via Ansible to run [oracledb_exporter](https://github.com/oracle/oracle-db-appdev-monitoring) v1.6.0.

## Quick Start

```bash
make up         # Start Oracle XE + UBI9
make ansible-test  # Provision exporter via Ansible
```

The exporter is then available at `http://localhost:9161/metrics`.

## Stack

| Service | Image | Ports |
|---|---|---|
| `oracle-xe` | `gvenzl/oracle-xe:21-slim-faststart` | `1521` |
| `ubi9-target` | `redhat/ubi9:latest` | `2222` (SSH), `9161` (exporter) |

## Usage

```bash
make build         # Build UBI9 image
make up            # Start all services
make down          # Stop all services
make rebuild       # down + build + up
make logs          # Tail all logs
make test          # Quick metrics check
make ansible-test  # (Re)provision exporter via Ansible
make shell-ubi9    # SSH into UBI9 (docker exec)
make shell-oracle  # SQL*Plus into Oracle XE
make health        # Check exporter status
make clean         # Stop + remove volumes + image
make info          # Show stack info
```

## Architecture

1. **Docker Compose** starts Oracle XE and a minimal UBI9 container (SSH only)
2. **Ansible** connects via SSH (`root:ansible` on port `2222`) and provisions:
   - Oracle Instant Client Basic 23.x (RPM)
   - oracledb_exporter v1.6.0 binary
   - Exporter user, directories, environment
   - Systemd service (or nohup fallback in containers)
3. The exporter connects to Oracle XE and serves metrics on `:9161`

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

- `defaults/main.yml` — configurable variables
- `tasks/main.yml` — installation tasks
- `templates/` — systemd unit, nohup wrapper, profile.d vars

## Files

```
├── docker-compose.yml          # Stack definition
├── Makefile                    # Orchestration targets
├── healthcheck.sql             # Oracle healthcheck query
├── ubi9/Dockerfile             # Minimal SSH-only UBI9 image
├── scripts/run_exporter.sh     # Nohup wrapper script
└── ansible/
    ├── playbook.yml            # Ansible playbook
    └── roles/oracledb_exporter/ # Ansible role
```

## Environment

If `DOCKER_HOST` points to Colima (inactive), the Makefile automatically unsets it for all recipe commands via `unexport DOCKER_HOST`.
