# OracleDB Exporter Stack — Specification

## 1. Goal

Run a Docker Compose stack with **two Oracle XE 21c** databases and a **UBI9 target** provisioned by **Ansible** to expose Oracle database metrics via [oracledb_exporter](https://github.com/oracle/oracle-db-appdev-monitoring) v1.6.0 — one exporter process per database on ports 9161 (xe1) and 9162 (xe2).

---

## 2. Architecture

```
┌──────────────┐     ┌──────────────────────────────────────────┐
│  oracle-xe   │     │              ubi9-target                  │
│  (:1521)     │     │                                          │
│              │     │  oracledb_exporter (xe1) :9161            │
│  PDB: XEPDB1 │◄────│    → DB: oracle-xe:1521/XEPDB1           │
│  APP_USER:   │     │                                          │
│  oracledb_   │     │  oracledb_exporter (xe2) :9162            │
│  exporter    │     │    → DB: oracle-xe-2:1521/XEPDB1          │
├──────────────┤     │                                          │
│  oracle-xe-2 │◄────│  Both started via nohup                  │
│  (:1522)     │     │  Instance dirs under /etc /opt /var/log   │
│  PDB: XEPDB1 │     │                                          │
│  APP_USER:   │     │  SSH (2222→22)                           │
│  oracledb_   │     │  Ansible provisions via SSH               │
│  exporter2   │     └──────────────────────────────────────────┘
└──────────────┘                │
                               └──── oracle-net ────────┘
                                   (docker bridge)
```

| Component | Image | Host Port | Container Port |
|---|---|---|---|
| oracle-xe | `gvenzl/oracle-xe:21-slim-faststart` | 1521 | 1521 |
| oracle-xe-2 | `gvenzl/oracle-xe:21-slim-faststart` | 1522 | 1521 |
| ubi9-target | `redhat/ubi9:latest` | 2222 | 22 (SSH) |
| ubi9-target | (same) | 9161 | 9161 (exporter xe1) |
| ubi9-target | (same) | 9162 | 9162 (exporter xe2) |

---

## 3. Services

### 3.1 oracle-xe

```yaml
image: gvenzl/oracle-xe:21-slim-faststart
container_name: oracle-xe
environment:
  ORACLE_PASSWORD: SysPassword1
  APP_USER: oracledb_exporter
  APP_USER_PASSWORD: exporter_pass
healthcheck:
  test: ["CMD", "sqlplus", "-L", "system/SysPassword1@//localhost/XEPDB1", "@/healthcheck.sql"]
  interval: 30s
  timeout: 10s
  retries: 10
  start_period: 60s
volumes:
  - ./healthcheck.sql:/healthcheck.sql
  - ./init-grants.sql:/container-entrypoint-startdb.d/init-grants.sql
  - oracle_data:/opt/oracle/oradata
```

#### Default credentials

| User | Password | Purpose |
|---|---|---|
| SYS | SysPassword1 | Admin SYSDBA |
| SYSTEM | SysPassword1 | Admin (used for grants) |
| PDBADMIN | SysPassword1 | PDB admin |
| oracledb_exporter | exporter_pass | App user (metrics queries) |

#### Grants required by the exporter

The `oracledb_exporter` user needs `GRANT SELECT ANY DICTIONARY` to query `v$session`, `v$process`, `v$tablespace`, etc. This is applied:

- On fresh DB creation via `init-grants.sql` mounted to `/container-entrypoint-startdb.d/`
- On existing DBs via the Ansible role using SQL\*Plus from the UBI9 target

### 3.2 ubi9-target

```yaml
build:
  context: .
  dockerfile: ubi9/Dockerfile
container_name: ubi9-target
ports:
  - "2222:22"
  - "9161:9161"
  - "9162:9162"
depends_on:
  oracle-xe:
    condition: service_healthy
  oracle-xe-2:
    condition: service_healthy
```

#### Dockerfile

```
FROM redhat/ubi9:latest
```

No application packages are installed in the image. It contains only:
- `openssh-server` — SSH daemon for Ansible
- `python3` — required by Ansible for remote execution
- `root:ansible` password for password-based SSH auth
- `PermitRootLogin yes` and `PasswordAuthentication yes` in sshd_config
- CMD: `/usr/sbin/sshd -D`

#### SSH access

```bash
ssh root@localhost -p 2222  # password: ansible
```

---

## 4. Ansible Role

### 4.1 Playbook

**File:** `ansible/playbook.yml`

- Hosts: all
- Become: yes
- Role variables: `oracle_exporter_instances` list with per-instance DB connection params, exporter ports, and admin passwords

```yaml
oracle_exporter_instances:
  - name: xe1
    db_host: oracle-xe
    db_port: 1521
    db_service: XEPDB1
    db_user: oracledb_exporter
    db_password: exporter_pass
    exporter_port: 9161
    admin_password: SysPassword1
  - name: xe2
    db_host: oracle-xe-2
    db_port: 1521
    db_service: XEPDB1
    db_user: oracledb_exporter2
    db_password: exporter_pass2
    exporter_port: 9162
    admin_password: SysPassword2
```

### 4.2 Role structure

```
ansible/roles/oracledb_exporter/
├── defaults/main.yml         # All configurable variables
├── handlers/main.yml         # ldconfig handler
├── tasks/main.yml            # 22 tasks (11 shared + 10 per-instance + archive cleanup)
└── templates/
    ├── default-metrics.toml.j2   # Full metrics definition
    ├── oracle_exporter.sh.j2     # Profile env vars
    ├── oracledb_exporter.service.j2  # Systemd unit (RHEL VMs)
    └── run_exporter.sh.j2        # Nohup wrapper (Docker)
```

### 4.3 Instance definition

Each exporter instance is defined as an entry in `oracle_exporter_instances`:

```yaml
oracle_exporter_instances:
  - name: xe1
    db_host: oracle-xe
    db_port: 1521
    db_service: XEPDB1
    db_user: oracledb_exporter
    db_password: exporter_pass
    exporter_port: 9161
    admin_password: SysPassword1
  - name: xe2
    db_host: oracle-xe-2
    db_port: 1521
    db_service: XEPDB1
    db_user: oracledb_exporter2
    db_password: exporter_pass2
    exporter_port: 9162
    admin_password: SysPassword2
```

### 4.4 Task execution order

**Shared tasks** (run once):

| # | Task | Module | Details |
|---|---|---|---|
| 1 | Install prerequisites | `dnf` | tar, gzip, procps-ng, psmisc, libaio |
| 2 | Install Oracle Instant Client Basic | `dnf` | RPM from `oracle_instantclient_url` (21.11.0.0.0), `disable_gpg_check: yes` |
| 3 | Configure Oracle library path | `shell` | `echo /usr/lib/oracle/*/client64/lib > /etc/ld.so.conf.d/oracle-instantclient.conf` |
| 4 | Update ldconfig cache | `command` | `ldconfig` |
| 5 | Create exporter group | `group` | `oracledb_exporter`, system account |
| 6 | Create exporter user | `user` | `oracledb_exporter`, shell `/sbin/nologin`, no home |
| 7 | Download exporter archive | `get_url` | GitHub releases `oracledb_exporter-1.6.0.linux-amd64.tar.gz` |
| 8 | Extract exporter | `unarchive` | To `{{ exporter_home }}` |
| 9 | Install binary | `copy` | To `/usr/local/bin/oracledb_exporter` |
| 10 | Install SQL\*Plus | `dnf` | Required for DB grants from UBI9, same version as Basic |
| 11 | Cleanup archive | `file` | Remove downloaded tar.gz |

**Per-instance tasks** (looped over `oracle_exporter_instances`):

| # | Task | Module | Instance-specific |
|---|---|---|---|
| 12 | Create instance directories | `file` | `{{ exporter_home }}/{{ name }}/`, `{{ exporter_config_dir }}/{{ name }}/`, `{{ exporter_log_dir }}/{{ name }}/` |
| 13 | Deploy default-metrics.toml | `template` | `{{ exporter_config_dir }}/{{ name }}/default-metrics.toml` |
| 14 | Deploy environment file | `template` | `{{ exporter_config_dir }}/{{ name }}/oracle_exporter.sh` |
| 15 | Deploy nohup wrapper | `template` | `{{ exporter_bin_dir }}/run_exporter_{{ name }}.sh` |
| 16 | Create systemd service | `template` | `oracledb_exporter_{{ name }}.service` (only when systemd) |
| 17 | Enable/start systemd | `systemd` | Per-instance service (only when systemd) |
| 18 | Grant SELECT ANY DICTIONARY | `shell` | Connects to each DB using `{{ admin_password }}` |
| 19 | Start exporter (non-systemd) | `shell` | `fuser -k {{ exporter_port }}/tcp` → `nohup ... --default.metrics` |
| 20 | Wait for exporter | `wait_for` | Port `{{ exporter_port }}`, timeout 30s |
| 21 | Verify metrics | `uri` | `http://127.0.0.1:{{ exporter_port }}/metrics` |

### 4.5 Per-instance exporter startup (nohup fallback)

```bash
source {{ exporter_config_dir }}/xe1/oracle_exporter.sh
fuser -k 9161/tcp 2>/dev/null || true
sleep 1
nohup /usr/local/bin/oracledb_exporter \
    --default.metrics /etc/oracledb_exporter/xe1/default-metrics.toml \
    --log.level error \
    --web.listen-address 0.0.0.0:9161 \
    >> /var/log/oracledb_exporter/xe1/exporter.log 2>&1 &
echo $! > /var/run/oracledb_exporter_xe1.pid
```

### 4.6 Per-instance environment variables

Each instance has its own env file at `{{ exporter_config_dir }}/{{ name }}/oracle_exporter.sh`:

```bash
export DB_USERNAME="oracledb_exporter"     # instance-specific
export DB_PASSWORD="exporter_pass"         # instance-specific
export DB_CONNECT_STRING="oracle-xe:1521/XEPDB1"  # instance-specific
export NLS_LANG="AMERICAN_AMERICA.AL32UTF8"
```

> **Important:** v1.6.0 uses `DB_USERNAME`, `DB_PASSWORD`, `DB_CONNECT_STRING` separately — NOT the single `DATA_SOURCE_NAME` format.

---

## 5. Versions (pinned)

| Dependency | Version | Source |
|---|---|---|
| Oracle XE | 21c | `gvenzl/oracle-xe:21-slim-faststart` |
| UBI | 9 | `redhat/ubi9:latest` |
| Oracle Instant Client Basic | 21.11.0.0.0-1 (EL8) | `https://download.oracle.com/otn_software/linux/instantclient/2111000/oracle-instantclient-basic-21.11.0.0.0-1.el8.x86_64.rpm` |
| Oracle Instant Client SQL\*Plus | 21.11.0.0.0-1 (EL8) | Same pattern with `sqlplus` in filename |
| oracledb_exporter | 1.6.0 | `https://github.com/oracle/oracle-db-appdev-monitoring/releases/download/1.6.0/oracledb_exporter-1.6.0.linux-amd64.tar.gz` |

---

## 6. Metrics

### 6.1 Default metrics (compiled-in, no TOML needed)

- `oracledb_up` (1/0)
- `oracledb_dbtype`
- `oracledb_exporter_build_info`
- `oracledb_exporter_last_scrape_duration_seconds`
- `oracledb_exporter_last_scrape_error`
- `oracledb_exporter_scrapes_total`

### 6.2 TOML-defined metrics (from default-metrics.toml)

| Context | Metrics | Source |
|---|---|---|
| sessions | `oracledb_sessions_value` (by status, type) | `v$session` |
| resource | `oracledb_resource_current_utilization`, `oracledb_resource_limit_value` | `v$resource_limit` |
| asm_diskgroup | `oracledb_asm_diskgroup_total`, `oracledb_asm_diskgroup_free` | `v$asm_diskgroup_stat` |
| activity | `oracledb_activity_*_count` (parse, execute, commits, rollbacks) | `v$sysstat` |
| process | `oracledb_process_count` | `v$process` |
| wait_time | `oracledb_wait_time_time_waited_sec_total` (by class) | `v$system_wait_class` |
| tablespace | `oracledb_tablespace_bytes`, `oracledb_tablespace_free`, `oracledb_tablespace_max_bytes`, `oracledb_tablespace_used_percent` | `dba_tablespace_usage_metrics` |
| db_system | `oracledb_db_system_value` (cpu_count, sga_max_size, pga_aggregate_limit) | `v$parameter` |
| db_platform | `oracledb_db_platform_value` | `v$database` |
| top_sql | `oracledb_top_sql_elapsed` (top 15) | `v$sqlstats` |
| cache_hit_ratio | `oracledb_cache_hit_ratio_value` | `v$sysmetric` |

---

## 7. Makefile targets

```makefile
unexport DOCKER_HOST  # On the host's shell

build              docker compose build
up                 docker compose up -d
down               docker compose down
rebuild            down → build → up
logs               docker compose logs -f
test               test-xe1 + test-xe2
test-xe1           curl localhost:9161/metrics | head -30
test-xe2           curl localhost:9162/metrics | head -30
shell-ubi9         docker compose exec ubi9-target bash
shell-oracle       docker compose exec oracle-xe bash
shell-oracle-2     docker compose exec oracle-xe-2 bash
status             docker compose ps
clean              down -v + remove image
ansible-test       up → docker inspect IP → ansible-playbook
health             curl both :9161/ and :9162/ + /metrics
info               Print stack info (both DBs + exporters)
```

### 7.1 ansible-test target details

```bash
unset DOCKER_HOST && \
docker compose -f docker-compose.yml up -d oracle-xe oracle-xe-2 ubi9-target && \
TARGET_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ubi9-target) && \
ANSIBLE_HOST_KEY_CHECKING=False \
ansible-playbook -i "$TARGET_IP," \
  -u root \
  -e "ansible_ssh_pass=ansible" \
  ansible/playbook.yml
```

---

## 8. Environment constraints

- **Docker context:** The user's environment may have `DOCKER_HOST` set to a non-functional socket. The Makefile uses `unexport DOCKER_HOST` to avoid this. Every `docker`/`docker compose` call must be preceded by `unset DOCKER_HOST` or equivalent.
- **SSH:** `sshpass` must be installed on the host for Ansible to connect via password auth.
- **Ansible:** Must be installed on the host.

---

## 9. Acceptance criteria

| # | Criterion | Verification |
|---|---|---|---|
| 1 | Oracle XE (xe1) accepts connections | `sqlplus system/SysPassword1@//localhost:1521/XEPDB1` returns "Connected" |
| 2 | Oracle XE (xe2) accepts connections | `sqlplus system/SysPassword2@//localhost:1522/XEPDB1` returns "Connected" |
| 3 | UBI9 container is SSH-reachable | `sshpass -p ansible ssh root@localhost -p 2222 "echo OK"` prints "OK" |
| 4 | Ansible playbook completes with 0 failures | `make ansible-test` → `failed=0` |
| 5 | Both exporters serve metrics | `curl http://localhost:9161/metrics` and `:9162/metrics` return HTTP 200 |
| 6 | Both databases are reachable | `oracledb_up 1` in both metrics outputs |
| 7 | TOML metrics are exposed (both) | `oracledb_sessions_value`, `oracledb_process_count`, `oracledb_tablespace_bytes` present in both |
| 8 | Instant Client 21.11 is installed | `rpm -qi oracle-instantclient-basic` → Version `21.11.0.0.0-1` |

---

## 10. Constraints & decisions log

| Decision | Rationale |
|---|---|
| Instant Client 21.11 (not 23.x) | Tested and verified compatible with oracledb_exporter v1.6.0. The permanent URL (`/oracle-instantclient-basic-linuxx64.rpm`) redirects to 23.x which also works, but 21.11 is pinned for reproducibility. |
| No systemd in Docker | Docker containers don't run systemd by default. The `nohup` fallback handles this. The systemd unit is only created on real RHEL9 VMs. |
| Separate env vars (DB_USERNAME, etc.) | v1.6.0 uses three separate env vars, not `DATA_SOURCE_NAME`. This differs from other exporter forks. |
| SQL\*Plus installed on UBI9 | Required to run `GRANT SELECT ANY DICTIONARY` from within the Ansible provisioner. Alternative would require mounting init scripts to Oracle XE (only works on fresh DB). |
| List loop inside role (not multiple includes) | Simpler variable management, single playbook call for N instances. |
| Separate Oracle XE containers | Full isolation, different ports, realistic multi-DB scenario for CI/CD validation. |
| Instance names `xe1`/`xe2` | Short, scoped to DB type, fits in 15-char process name and filename constraints. |
| Unique host ports 9161/9162 | Direct per-instance access to each exporter endpoint without reverse proxy. |
| Single OS user for all instances | All exporters share the same binary and Instant Client; no need for separate OS users. |
| `fuser -k` for restart | The exporter binary's process name is truncated to 15 chars (`oracledb_expor`), making `pkill oracledb_exporter` ineffective. `fuser -k 9161/tcp` precisely targets the process holding the port. |
| No `default-metrics.toml` in release archive | v1.6.0 GitHub release only ships the binary, not the TOML file. The TOML content must be sourced from the source repo and deployed via Ansible. |
| Nohup wrapper sources env file | The shell spawned by Ansible's `shell` module is non-interactive and non-login, so `/etc/profile.d` is not sourced automatically. The wrapper explicitly sources the per-instance env file. |
