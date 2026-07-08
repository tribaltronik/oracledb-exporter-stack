# OracleDB Exporter Stack — Specification

## 1. Goal

Run a Docker Compose stack with **Oracle XE 21c** and a **UBI9 target** provisioned by **Ansible** to expose Oracle database metrics via [oracledb_exporter](https://github.com/oracle/oracle-db-appdev-monitoring) v1.6.0 on `http://localhost:9161/metrics`.

---

## 2. Architecture

```
┌──────────────┐     ┌────────────────────────────┐
│  oracle-xe   │     │       ubi9-target           │
│              │     │                            │
│  Oracle XE   │     │  SSH (2222→22)             │
│  21c PDB     │◄────│  Ansible provisions via SSH │
│              │     │                            │
│  Port 1521   │     │  oracledb_exporter :9161   │
│  Service:    │     │  (exposed as localhost:9161)│
│  XEPDB1      │     │                            │
└──────────────┘     └────────────────────────────┘
       │                        │
       └──── oracle-net ────────┘
           (docker bridge)
```

| Component | Image | Host Port | Container Port |
|---|---|---|---|
| oracle-xe | `gvenzl/oracle-xe:21-slim-faststart` | 1521 | 1521 |
| ubi9-target | `redhat/ubi9:latest` | 2222 | 22 (SSH) |
| ubi9-target | (same) | 9161 | 9161 (exporter) |

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
depends_on:
  oracle-xe:
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
- Role variables:
  - `oracle_db_host: oracle-xe`
  - `oracle_db_port: 1521`
  - `oracle_db_service: XEPDB1`
  - `oracle_db_user: oracledb_exporter`
  - `oracle_db_password: exporter_pass`
  - `oracle_admin_password: SysPassword1`

### 4.2 Role structure

```
ansible/roles/oracledb_exporter/
├── defaults/main.yml         # All configurable variables
├── handlers/main.yml         # ldconfig handler
├── tasks/main.yml            # 18 tasks (see below)
└── templates/
    ├── default-metrics.toml.j2   # Full metrics definition
    ├── oracle_exporter.sh.j2     # Profile env vars
    ├── oracledb_exporter.service.j2  # Systemd unit (RHEL VMs)
    └── run_exporter.sh.j2        # Nohup wrapper (Docker)
```

### 4.3 Task execution order

| # | Task | Module | Details |
|---|---|---|---|
| 1 | Install prerequisites | `dnf` | tar, gzip, procps-ng, psmisc, libaio |
| 2 | Install Oracle Instant Client Basic | `dnf` | RPM from `oracle_instantclient_url` (21.11.0.0.0), `disable_gpg_check: yes` |
| 3 | Configure Oracle library path | `shell` | `echo /usr/lib/oracle/*/client64/lib > /etc/ld.so.conf.d/oracle-instantclient.conf` |
| 4 | Update ldconfig cache | `command` | `ldconfig` |
| 5 | Create exporter group | `group` | `oracledb_exporter`, system account |
| 6 | Create exporter user | `user` | `oracledb_exporter`, shell `/sbin/nologin`, no home |
| 7 | Create exporter directories | `file` | `/opt/oracledb_exporter`, `/etc/oracledb_exporter`, `/var/log/oracledb_exporter` |
| 8 | Download exporter archive | `get_url` | GitHub releases `oracledb_exporter-1.6.0.linux-amd64.tar.gz` |
| 9 | Extract exporter | `unarchive` | To `{{ exporter_home }}` |
| 10 | Install binary | `copy` | To `/usr/local/bin/oracledb_exporter` |
| 11 | Deploy default-metrics.toml | `template` | To `{{ exporter_config_dir }}/default-metrics.toml` |
| 12 | Deploy nohup wrapper | `template` | To `/usr/local/bin/run_exporter.sh` |
| 13 | Set profile.d env vars | `template` | To `/etc/profile.d/oracle_exporter.sh` |
| 14 | Create systemd service | `template` | When `ansible_service_mgr == "systemd"` (skipped in Docker) |
| 15 | Enable/start systemd service | `systemd` | When systemd (skipped in Docker) |
| 16 | Install SQL\*Plus | `dnf` | Required for DB grants from UBI9, same version as Basic |
| 17 | Grant SELECT ANY DICTIONARY | `shell` | `sqlplus -L "system/{{ oracle_admin_password }}@//{{ oracle_db_host }}:{{ oracle_db_port }}/{{ oracle_db_service }}"` |
| 18 | Start exporter (non-systemd) | `shell` | `fuser -k 9161/tcp` → `nohup ... --default.metrics ...` |
| 19 | Wait for exporter | `wait_for` | Port `9161`, timeout `30s` |
| 20 | Verify metrics | `uri` | Assert `oracledb_up` in response |
| 21 | Cleanup archive | `file` | Remove `/tmp/oracledb_exporter-*.tar.gz` |

### 4.4 Exporter startup (nohup fallback)

```bash
. /etc/profile.d/oracle_exporter.sh
fuser -k 9161/tcp 2>/dev/null || true
sleep 1
nohup /usr/local/bin/oracledb_exporter \
    --default.metrics /etc/oracledb_exporter/default-metrics.toml \
    --log.level error \
    --web.listen-address 0.0.0.0:9161 \
    >> /var/log/oracledb_exporter/exporter.log 2>&1 &
echo $! > /var/run/oracledb_exporter.pid
```

### 4.5 Environment variables

Set in `/etc/profile.d/oracle_exporter.sh` (sourced by the wrapper before launch):

```bash
export DB_USERNAME="oracledb_exporter"
export DB_PASSWORD="exporter_pass"
export DB_CONNECT_STRING="oracle-xe:1521/XEPDB1"
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
test               curl localhost:9161/metrics | head -50
shell-ubi9         docker compose exec ubi9-target bash
shell-oracle       docker compose exec oracle-xe bash
status             docker compose ps
clean              down -v + remove image
ansible-test       up → docker inspect IP → ansible-playbook
health             curl localhost:9161/ + /metrics
info               Print stack info
```

### 7.1 ansible-test target details

```bash
unset DOCKER_HOST && \
docker compose -f docker-compose.yml up -d oracle-xe ubi9-target && \
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
|---|---|---|
| 1 | Oracle XE accepts connections | `sqlplus system/SysPassword1@//localhost:1521/XEPDB1` returns "Connected" |
| 2 | UBI9 container is SSH-reachable | `sshpass -p ansible ssh root@localhost -p 2222 "echo OK"` prints "OK" |
| 3 | Ansible playbook completes with 0 failures | `make ansible-test` → `failed=0` |
| 4 | Exporter serves metrics | `curl http://localhost:9161/metrics` returns HTTP 200 |
| 5 | Database is reachable | `oracledb_up 1` in metrics output |
| 6 | TOML metrics are exposed | `oracledb_sessions_value`, `oracledb_process_count`, `oracledb_tablespace_bytes` present in metrics |
| 7 | Instant Client 21.11 is installed | `rpm -qi oracle-instantclient-basic` → Version `21.11.0.0.0-1` |

---

## 10. Constraints & decisions log

| Decision | Rationale |
|---|---|
| Instant Client 21.11 (not 23.x) | Tested and verified compatible with oracledb_exporter v1.6.0. The permanent URL (`/oracle-instantclient-basic-linuxx64.rpm`) redirects to 23.x which also works, but 21.11 is pinned for reproducibility. |
| No systemd in Docker | Docker containers don't run systemd by default. The `nohup` fallback handles this. The systemd unit is only created on real RHEL9 VMs. |
| Separate env vars (DB_USERNAME, etc.) | v1.6.0 uses three separate env vars, not `DATA_SOURCE_NAME`. This differs from other exporter forks. |
| SQL\*Plus installed on UBI9 | Required to run `GRANT SELECT ANY DICTIONARY` from within the Ansible provisioner. Alternative would require mounting init scripts to Oracle XE (only works on fresh DB). |
| `fuser -k` for restart | The exporter binary's process name is truncated to 15 chars (`oracledb_expor`), making `pkill oracledb_exporter` ineffective. `fuser -k 9161/tcp` precisely targets the process holding the port. |
| No `default-metrics.toml` in release archive | v1.6.0 GitHub release only ships the binary, not the TOML file. The TOML content must be sourced from the source repo and deployed via Ansible. |
| Nohup wrapper sources profile.d | The shell spawned by Ansible's `shell` module is non-interactive and non-login, so `/etc/profile.d` is not sourced automatically. The wrapper explicitly sources it. |
