# OracleDB Exporter — Multi-Instance Product Requirements Document

## 1. Problem Statement

The current Ansible role and Docker Compose stack support only **one** database connection per UBI9 target. In real environments, monitoring teams need to observe multiple Oracle databases from a single exporter host. Each database requires a separate exporter process with its own connection credentials, listening port, and configuration.

## 2. Goals

1. Allow a single Ansible role invocation to install and configure **N oracledb_exporter instances** on one target.
2. Each instance runs as an independent process with its own port, DB connection, config files, and process tracking.
3. The Docker Compose stack demonstrates multi-DB monitoring with two Oracle XE containers.
4. Backward compatible — single-instance users see no breaking changes.

## 3. Scope

### In scope

- Ansible role: define `oracle_exporter_instances` list, loop per-instance tasks.
- Templates: all 4 templates parameterized by instance name.
- Docker Compose: add `oracle-xe-2` service as a second database target.
- Makefile: start both DBs on `up`, test both exporters.
- Documentation: `docs/spec.md` updated.

### Out of scope

- Dynamic service discovery (e.g., Consul, DNS-SD).
- Load balancing or reverse proxy in front of exporters.
- Docker Compose in production — this is a dev/validation stack.

## 4. Architecture

```
┌──────────────┐     ┌──────────────────────────────────────────┐
│  oracle-xe   │     │              ubi9-target                  │
│  (:1521)     │     │                                          │
│              │     │  oracledb_exporter (xe1) :9161            │
│  PDB: XEPDB1 │◄────│    → DB_USERNAME=oracledb_exporter       │
│  APP_USER:   │     │    → DB_CONNECT_STRING=oracle-xe:1521/…  │
│  oracledb_   │     │                                          │
│  exporter    │     │  oracledb_exporter (xe2) :9162            │
├──────────────┤     │    → DB_USERNAME=oracledb_exporter2      │
│  oracle-xe-2 │◄────│    → DB_CONNECT_STRING=oracle-xe-2:1521/…│
│  (:1522)     │     │                                          │
│              │     │  Both started via nohup                  │
│  PDB: XEPDB1 │     │  User/group/dirs per instance             │
│  APP_USER:   │     └──────────────────────────────────────────┘
│  oracledb_   │
│  exporter2   │
└──────────────┘
         │              ┌──────────────────┐
         └──────────────│  oracle-net      │
                        │  (docker bridge) │
                        └──────────────────┘
```

## 5. Functional Requirements

| ID | Requirement | Verification |
|---|---|---|
| F1 | Role accepts a list of exporter instance definitions | `oracle_exporter_instances` variable ≥ 1 entry |
| F2 | Each instance has unique name, DB connection, and port | Ports don't collide |
| F3 | Each instance gets its own config dir, log dir, PID file | Paths contain instance name |
| F4 | Each instance gets its own nohup wrapper script | `run_exporter_{{ name }}.sh` |
| F5 | Each instance gets its own systemd unit (on RHEL) | `oracledb_exporter_{{ name }}.service` |
| F6 | Each instance exports on its configured port | `curl localhost:{{ port }}/metrics` |
| F7 | Each exporter reports `oracledb_up 1` for its DB | Metric check per instance |
| F8 | Prerequisites (IC, ldconfig) are installed once | Single dnf install per RPM |
| F9 | Second DB (`oracle-xe-2`) is created in Docker Compose | `docker compose ps` shows both |

## 6. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NF1 | Single-instance users override no variables → identical behavior |
| NF2 | All instances run as the same OS user (`oracledb_exporter`) |
| NF3 | Each exporter process manages its own lifecycle (no cross-dependency) |
| NF4 | The `fuser -k` restart mechanism targets per-instance ports |

## 7. Instance isolation

Each instance in `oracle_exporter_instances` receives:

| Resource | Pattern |
|---|---|
| Config dir | `{{ exporter_config_dir }}/{{ name }}/` |
| Log dir | `{{ exporter_log_dir }}/{{ name }}/` |
| PID file | `{{ exporter_pid_dir }}/oracledb_exporter_{{ name }}.pid` |
| Metrics TOML | `{{ exporter_config_dir }}/{{ name }}/default-metrics.toml` |
| Env file | `{{ exporter_config_dir }}/{{ name }}/oracle_exporter.sh` |
| Wrapper script | `{{ exporter_bin_dir }}/run_exporter_{{ name }}.sh` |
| Systemd unit | `oracledb_exporter_{{ name }}.service` |
| Listening port | `{{ exporter_port }}` (per-instance) |

## 8. Variable design

```yaml
oracle_exporter_instances:
  - name: xe1
    db_host: localhost
    db_port: 1521
    db_service: XEPDB1
    db_user: system
    db_password: ""
    exporter_port: 9161
    admin_password: ""
```

The `admin_password` field is per-instance for the `GRANT SELECT ANY DICTIONARY` task (each DB has its own SYSTEM password).

## 9. Acceptance criteria

```bash
# Both exporters are reachable
curl -s http://localhost:9161/metrics | grep "oracledb_up 1"
curl -s http://localhost:9162/metrics | grep "oracledb_up 1"

# Each reports a different DB platform (same DB type is OK)
curl -s http://localhost:9161/metrics | grep oracledb_db_platform
curl -s http://localhost:9162/metrics | grep oracledb_db_platform

# Each has unique PID
ps aux | grep "oracledb_exporter" | grep -v grep | wc -l   # → 2
```

## 10. Out of scope (future considerations)

- Encrypted passwords (Ansible Vault)
- TLS for exporter endpoints
- Custom metric TOML per instance (all use the same default-metrics.toml)
- Dynamic addition/removal of instances without re-running full playbook

## 11. Decision log

| Decision | Rationale |
|---|---|
| List loop inside role (not multiple includes) | Simpler variable management, single playbook call |
| Separate containers for DBs | Full isolation, different ports, realistic multi-DB scenario |
| Instance names `xe1`/`xe2` | Short, scoped to DB type, fits in filename constraints |
| Unique host ports 9161/9162 | Direct per-instance access, no reverse proxy needed |
| Single OS user for all instances | All exporters share the same binary and Instant Client; no need for separate users |
