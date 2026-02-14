#!/bin/sh
# mysqltuner.sh - POSIX shell port (derived from MySQLTuner-perl)
# License: GPLv3 (see LICENSE.GPLv3)

# Keep strict mode, but avoid set -e (we want controlled error handling)
set -u

VERSION="0.2.0-devel"

usage() {
  cat <<USAGE
mysqltuner.sh (POSIX sh) - ${VERSION}

Usage:
  mysqltuner.sh [options]

Connection options:
  --host <host>
  --port <port>
  --socket <path>
  --user <user>
  --pass <pass>
  --defaults-file <path>   (passed to mysql client)

Output options:
  --silent
  --json

Misc:
  -h, --help
  --version
USAGE
}

die() {
  echo "ERROR: $*" 1>&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"
}

mktemp_dir() {
  if command -v mktemp >/dev/null 2>&1; then
    mktemp -d 2>/dev/null || mktemp -d -t mysqltuner 2>/dev/null
    return
  fi
  d="/tmp/mysqltuner.$$"
  (umask 077 && mkdir "$d") || return 1
  echo "$d"
}

cleanup() {
  if [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ]; then
    rm -rf "$WORKDIR" >/dev/null 2>&1 || true
  fi
}

# ---- Argument parsing (POSIX-compatible) -----------------------------------
HOST=""
PORT=""
SOCKET=""
USER=""
PASS=""
DEFAULTS_FILE=""
SILENT=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    --host) shift; HOST="${1-}" ;;
    --port) shift; PORT="${1-}" ;;
    --socket) shift; SOCKET="${1-}" ;;
    --user|-u) shift; USER="${1-}" ;;
    --pass|-p|--password) shift; PASS="${1-}" ;;
    --defaults-file) shift; DEFAULTS_FILE="${1-}" ;;
    --silent) SILENT=1 ;;
    --json) JSON=1 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
  shift
done

# ---- Runtime deps ----------------------------------------------------------
need_cmd mysql
need_cmd awk
need_cmd sed
need_cmd tr
need_cmd head
need_cmd printf
need_cmd jq

# ---- MySQL command builder -------------------------------------------------
MYSQL_CMD="mysql"
MYSQL_ARGS="--batch --raw --skip-column-names"

if [ -n "$DEFAULTS_FILE" ]; then
  MYSQL_ARGS="$MYSQL_ARGS --defaults-file=$DEFAULTS_FILE"
fi
if [ -n "$HOST" ]; then
  MYSQL_ARGS="$MYSQL_ARGS -h $HOST"
fi
if [ -n "$PORT" ]; then
  MYSQL_ARGS="$MYSQL_ARGS -P $PORT"
fi
if [ -n "$SOCKET" ]; then
  MYSQL_ARGS="$MYSQL_ARGS -S $SOCKET"
fi
if [ -n "$USER" ]; then
  MYSQL_ARGS="$MYSQL_ARGS -u $USER"
fi
# WARNING: passing password on CLI can leak via process list; keep for parity
if [ -n "$PASS" ]; then
  MYSQL_ARGS="$MYSQL_ARGS -p$PASS"
fi

mysql_query() {
  # $1: SQL
  # shellcheck disable=SC2086
  echo "$1" | $MYSQL_CMD $MYSQL_ARGS
}

mysql_query_silent() {
  mysql_query "$1" 2>/dev/null
}

# ---- KV helpers ------------------------------------------------------------
kv_get() {
  # $1: file (tab-separated key \t value)
  # $2: key
  awk -F"\t" -v k="$2" '($1==k){sub(/^[^\t]*\t/, ""); print; exit}' "$1"
}

kv_dump_file() {
  # $1: SQL returning 2 columns (key,value)
  # $2: output file
  mysql_query_silent "$1" | awk 'NF>=2{print $1"\t"$2}' >"$2"
}

# ---- Formatting helpers ----------------------------------------------------
num() {
  # Print integer if possible, else 0
  v="$1"
  case "$v" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
}

bytes_h() {
  b=$(num "$1")
  if [ "$b" -ge 1099511627776 ]; then awk -v b="$b" 'BEGIN{printf "%.1f TiB", b/1099511627776}'; return; fi
  if [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.1f GiB", b/1073741824}'; return; fi
  if [ "$b" -ge 1048576 ]; then awk -v b="$b" 'BEGIN{printf "%.1f MiB", b/1048576}'; return; fi
  if [ "$b" -ge 1024 ]; then awk -v b="$b" 'BEGIN{printf "%.1f KiB", b/1024}'; return; fi
  echo "${b} B"
}

# ---- Reporting helpers -----------------------------------------------------
section() {
  [ "$SILENT" -eq 1 ] && return 0
  echo
  echo "== $* =="
}

info() {
  [ "$SILENT" -eq 1 ] && return 0
  echo "[INFO] $*"
}

warn() {
  [ "$SILENT" -eq 1 ] && return 0
  echo "[WARN] $*"
}

ok() {
  [ "$SILENT" -eq 1 ] && return 0
  echo "[OK]   $*"
}

# ---- Core collection -------------------------------------------------------
WORKDIR="$(mktemp_dir)" || die "unable to create temp dir"
trap cleanup EXIT HUP INT TERM

VARS_TSV="$WORKDIR/variables.tsv"
STATUS_TSV="$WORKDIR/status.tsv"

if ! mysql_query_silent "SELECT 1;" >/dev/null 2>&1; then
  die "unable to connect (check credentials/host/socket)"
fi

kv_dump_file "SHOW GLOBAL VARIABLES" "$VARS_TSV"
kv_dump_file "SHOW GLOBAL STATUS" "$STATUS_TSV"

SERVER_VERSION=$(mysql_query_silent "SELECT VERSION();" | head -n 1 | tr -d '\r')
SERVER_COMMENT=$(kv_get "$VARS_TSV" version_comment | tr -d '\r')
SERVER_FLAVOR="mysql"
case "$SERVER_VERSION" in
  *MariaDB*) SERVER_FLAVOR="mariadb" ;;
esac

UPTIME=$(kv_get "$STATUS_TSV" Uptime | tr -d '\r')
UPTIME_S=$(num "$UPTIME")

# some commonly used vars/status
MAX_CONNECTIONS=$(kv_get "$VARS_TSV" max_connections)
THREADS_CONNECTED=$(kv_get "$STATUS_TSV" Threads_connected)
THREADS_RUNNING=$(kv_get "$STATUS_TSV" Threads_running)
SLOW_QUERY_LOG=$(kv_get "$VARS_TSV" slow_query_log)
LONG_QUERY_TIME=$(kv_get "$VARS_TSV" long_query_time)
INNODB_BP_SIZE=$(kv_get "$VARS_TSV" innodb_buffer_pool_size)
INNODB_BP_INST=$(kv_get "$VARS_TSV" innodb_buffer_pool_instances)
QCACHE_TYPE=$(kv_get "$VARS_TSV" query_cache_type)
QCACHE_SIZE=$(kv_get "$VARS_TSV" query_cache_size)

# ---- Output (JSON) ---------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  jq -n \
    --arg version "$SERVER_VERSION" \
    --arg flavor "$SERVER_FLAVOR" \
    --arg version_comment "$SERVER_COMMENT" \
    --arg uptime "$UPTIME" \
    --arg max_connections "$MAX_CONNECTIONS" \
    --arg threads_connected "$THREADS_CONNECTED" \
    --arg threads_running "$THREADS_RUNNING" \
    --arg slow_query_log "$SLOW_QUERY_LOG" \
    --arg long_query_time "$LONG_QUERY_TIME" \
    --arg innodb_buffer_pool_size "$INNODB_BP_SIZE" \
    --arg innodb_buffer_pool_instances "$INNODB_BP_INST" \
    --arg query_cache_type "$QCACHE_TYPE" \
    --arg query_cache_size "$QCACHE_SIZE" \
    '{
      version:$version,
      flavor:$flavor,
      version_comment:$version_comment,
      uptime:$uptime,
      max_connections:$max_connections,
      threads_connected:$threads_connected,
      threads_running:$threads_running,
      slow_query_log:$slow_query_log,
      long_query_time:$long_query_time,
      innodb_buffer_pool_size:$innodb_buffer_pool_size,
      innodb_buffer_pool_instances:$innodb_buffer_pool_instances,
      query_cache_type:$query_cache_type,
      query_cache_size:$query_cache_size
    }'
  exit 0
fi

# ---- Output (human) --------------------------------------------------------
[ "$SILENT" -eq 1 ] && exit 0

echo "MySQLTuner POSIX port (WIP)"
echo "--------------------------------"
info "Server version:  $SERVER_VERSION"
info "Server flavor:   $SERVER_FLAVOR"
[ -n "$SERVER_COMMENT" ] && info "Version comment: $SERVER_COMMENT"
[ -n "$UPTIME" ] && info "Uptime (s):      $UPTIME"

section "Connections"
info "max_connections:   $MAX_CONNECTIONS"
info "Threads_connected: $THREADS_CONNECTED"
info "Threads_running:   $THREADS_RUNNING"

mc=$(num "$MAX_CONNECTIONS")
tc=$(num "$THREADS_CONNECTED")
if [ "$mc" -gt 0 ] && [ "$tc" -gt 0 ]; then
  pct=$(awk -v a="$tc" -v b="$mc" 'BEGIN{printf "%d", (a*100)/b}')
  if [ "$pct" -ge 80 ]; then
    warn "High connection usage: ${pct}% of max_connections"
  else
    ok "Connection usage: ${pct}% of max_connections"
  fi
fi

section "InnoDB"
if [ -n "$INNODB_BP_SIZE" ]; then
  info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"
fi
[ -n "$INNODB_BP_INST" ] && info "innodb_buffer_pool_instances: $INNODB_BP_INST"

section "Query Cache"
if [ -n "$QCACHE_TYPE" ]; then
  info "query_cache_type: $QCACHE_TYPE"
fi
if [ -n "$QCACHE_SIZE" ]; then
  info "query_cache_size: $(bytes_h "$QCACHE_SIZE")"
fi

section "Slow Query Log"
[ -n "$SLOW_QUERY_LOG" ] && info "slow_query_log: $SLOW_QUERY_LOG"
[ -n "$LONG_QUERY_TIME" ] && info "long_query_time: $LONG_QUERY_TIME"

ok "Collected: SHOW GLOBAL VARIABLES/STATUS"
warn "Next: implement full MySQLTuner-perl checks for feature parity."

exit 0
