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

2) Run the tuner:

```sh
./mysqltuner.sh
```

3) Prefer a `--defaults-file` (avoids putting passwords on the command line):

```sh
./mysqltuner.sh --defaults-file=/root/.my.cnf
```

## Options

```sh
./mysqltuner.sh --help
```

Notes:
- `--pass` is supported, but **passing a password on the CLI can leak via process lists**.
- `--json` prints a single JSON object (generated via `jq`).

## Checks implemented (current)

This is still WIP, but already includes:
- Core collection: `SHOW GLOBAL VARIABLES` / `SHOW GLOBAL STATUS`
- Throughput: QPS
- Connections: max/used/threads + aborted connect rate
- Memory sizing (rough estimate):
  - global buffers + (per-thread buffers * `max_connections`)
  - best-effort compare to system RAM via `/proc/meminfo`
- InnoDB buffer pool hit rate
- Temporary table disk ratio
- Packet size check (`max_allowed_packet`)
- Network exposure checks: `bind_address`, `skip_networking`, `port`
- Replication checks (best-effort):
  - `SHOW MASTER STATUS`
  - `SHOW SLAVE STATUS` / `SHOW REPLICA STATUS` (parses IO/SQL running, seconds behind, errors)
- CVE scan (best-effort):
  - `--cvefile` or auto `./vulnerabilities.csv` if present
- Weak password dictionary check (best-effort, **MySQL < 8 only**):
  - `--passwordfile` or auto `./basic_passwords.txt` if present

## Data files

These files are used by some checks:
- `basic_passwords.txt`
- `vulnerabilities.csv`

## CI

A minimal CI workflow runs:
- `sh -n mysqltuner.sh`
- `./mysqltuner.sh --help`

## Upstream references

- MySQLTuner-perl upstream clone used during migration: `jmrenouard/MySQLTuner-perl`
