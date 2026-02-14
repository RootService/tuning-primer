# RootService tuning-primer (POSIX shell)

This repository contains a **POSIX `sh`** implementation derived from the upstream **MySQLTuner-perl** project.

The goal is **maximum feature parity** while staying:
- portable (no bashisms)
- dependency-minimal (uses the MySQL CLI; uses `jq` for JSON correctness)

## License

This project is licensed under the **GNU GPL v3**.

- Full text: `LICENSE.GPLv3`

## Quickstart

1) Ensure you have the MySQL client installed and accessible:

```sh
mysql --version
```

2) Prefer a `--defaults-file` (avoids putting passwords on the command line):

```sh
./mysqltuner.sh --defaults-file /path/to/client.cnf
```

3) Run:

```sh
./mysqltuner.sh
./mysqltuner.sh --json
```

## Options

```sh
./mysqltuner.sh --help
```

Notes:
- `--pass` is supported, but **passing a password on the CLI can leak via process lists**.
- `--json` prints a single JSON object (generated via `jq`).

## Checks implemented (current)

This is still WIP, but already includes (high-level):
- Core collection: `SHOW GLOBAL VARIABLES` / `SHOW GLOBAL STATUS`
- Throughput:
  - QPS, CPS, bytes in/out per second
  - read/write mix via `Com_*`
- Connections:
  - max/used/threads
  - aborted connects/clients
  - `Connection_errors_*`
- Memory sizing (upstream-style breakdown):
  - global buffers + per-thread buffers
  - totals at `max_connections` and at `Max_used_connections`
  - percent of RAM (best-effort via `/proc/meminfo`)
- Query Cache (best-effort):
  - efficiency, used %, prunes/day, fragmentation
- Sorts/Joins/Tmp tables:
  - sorts requiring temp tables
  - joins without indexes (+ per day)
  - tmp tables on disk % (+ upstream-like thresholds)
- InnoDB:
  - BP hit rate, occupancy (free/used/dirty)
  - log write efficiency, log wait counters
  - redo/log sizing ratio (% of buffer pool)
  - InnoDB data+index size estimate and BP/data ratio
- Table/Open files:
  - table cache hit rate
  - `table_definition_cache` sizing vs `information_schema.tables`
  - open files usage %
- Binary log:
  - binlog cache memory access %
- Replication (best-effort):
  - `SHOW MASTER STATUS`
  - `SHOW SLAVE STATUS` / `SHOW REPLICA STATUS`
- Security (basic):
  - network exposure (`bind_address`, `skip_networking`)
  - SSL/TLS vars, `local_infile`, etc.
- CVE scan (best-effort):
  - `--cvefile` or auto `./vulnerabilities.csv` if present
- Weak password dictionary check (best-effort, **MySQL < 8 only**)

## JSON output (schema overview)

`--json` outputs one object with many keys. The exact set evolves, but is broadly grouped as:

- **Identity:** `version`, `flavor`, `version_comment`
- **Runtime:** `uptime`
- **Throughput/Network:** `qps`, `cps`, `bytes_received*`, `bytes_sent*`
- **RW mix:** `com_select`, `com_insert`, `com_update`, `com_delete`, `com_replace`, `pct_reads`, `pct_writes`
- **Connections/Threads:** `max_connections`, `max_used_connections*`, `threads_*`, `thread_cache_*`, `aborted_*`, `connection_errors{...}`
- **Tables/Files:** `table_*`, `open_files*`, `total_tables`
- **Query cache:** `qcache_*`, `query_cache_*`
- **Sorts/Joins/Tmp:** `sort_merge_pct`, `joins_without_indexes*`, `tmp_disk_pct`, `select_*`, `handler_read_*`
- **InnoDB:** `innodb_*` (BP, log, redo/log sizing, occupancy, data sizing)
- **Binlog:** `log_bin`, `binlog_*`
- **Security vars:** `skip_name_resolve`, `local_infile`, `require_secure_transport`, `have_ssl`, etc.
- **Memory model:** `*_buffers_bytes`, `max_*memory*`, `pct_max_*memory`
- **CVE/Passwords:** `cve_*`, `weak_password_*`
- **Replication:** `replication{...}`

If you need a pinned schema, open an issue and we can add a `--json-schema` mode.

## Data files

These files are used by some checks:
- `basic_passwords.txt`
- `vulnerabilities.csv`

## CI

A minimal CI workflow runs:
- `sh -n mysqltuner.sh`
- `./mysqltuner.sh --help`

## Upstream references

- MySQLTuner-perl upstream: `jmrenouard/MySQLTuner-perl`
