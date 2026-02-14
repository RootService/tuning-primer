#!/bin/sh
# mysqltuner.sh - POSIX shell port (derived from MySQLTuner-perl)
# License: GPLv3 (see LICENSE.GPLv3)

# Keep strict mode, but avoid set -e (we want controlled error handling)
set -u

VERSION="0.4.0-devel"

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
need_cmd grep

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
  v="$1"
  case "$v" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
}

rate_per_s() {
  v=$(num "$1")
  u=$(num "$2")
  if [ "$u" -le 0 ]; then
    echo 0
    return
  fi
  awk -v v="$v" -v u="$u" 'BEGIN{printf "%.2f", v/u}'
}

pct() {
  a=$(num "$1")
  b=$(num "$2")
  if [ "$b" -le 0 ]; then
    echo 0
    return
  fi
  awk -v a="$a" -v b="$b" 'BEGIN{printf "%d", (a*100)/b}'
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

# Common vars/status
MAX_CONNECTIONS=$(kv_get "$VARS_TSV" max_connections)
MAX_USED_CONNECTIONS=$(kv_get "$STATUS_TSV" Max_used_connections)
THREADS_CONNECTED=$(kv_get "$STATUS_TSV" Threads_connected)
THREADS_RUNNING=$(kv_get "$STATUS_TSV" Threads_running)
THREADS_CREATED=$(kv_get "$STATUS_TSV" Threads_created)

CONNECTIONS=$(kv_get "$STATUS_TSV" Connections)
ABORTED_CONNECTS=$(kv_get "$STATUS_TSV" Aborted_connects)
ABORTED_CLIENTS=$(kv_get "$STATUS_TSV" Aborted_clients)

SLOW_QUERY_LOG=$(kv_get "$VARS_TSV" slow_query_log)
LONG_QUERY_TIME=$(kv_get "$VARS_TSV" long_query_time)
SLOW_QUERIES=$(kv_get "$STATUS_TSV" Slow_queries)

QUESTIONS=$(kv_get "$STATUS_TSV" Questions)
QUERIES=$(kv_get "$STATUS_TSV" Queries)

CREATED_TMP_TABLES=$(kv_get "$STATUS_TSV" Created_tmp_tables)
CREATED_TMP_DISK_TABLES=$(kv_get "$STATUS_TSV" Created_tmp_disk_tables)
CREATED_TMP_FILES=$(kv_get "$STATUS_TSV" Created_tmp_files)
TMP_TABLE_SIZE=$(kv_get "$VARS_TSV" tmp_table_size)
MAX_HEAP_TABLE_SIZE=$(kv_get "$VARS_TSV" max_heap_table_size)

INNODB_BP_SIZE=$(kv_get "$VARS_TSV" innodb_buffer_pool_size)
INNODB_BP_INST=$(kv_get "$VARS_TSV" innodb_buffer_pool_instances)
INNODB_BP_READ_REQ=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_read_requests)
INNODB_BP_READS=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_reads)
INNODB_LOG_WAITS=$(kv_get "$STATUS_TSV" Innodb_log_waits)
INNODB_FLUSH_TRX=$(kv_get "$VARS_TSV" innodb_flush_log_at_trx_commit)
INNODB_LOG_BUFFER_SIZE=$(kv_get "$VARS_TSV" innodb_log_buffer_size)

QCACHE_TYPE=$(kv_get "$VARS_TSV" query_cache_type)
QCACHE_SIZE=$(kv_get "$VARS_TSV" query_cache_size)
QCACHE_HITS=$(kv_get "$STATUS_TSV" Qcache_hits)
QCACHE_PRUNES=$(kv_get "$STATUS_TSV" Qcache_lowmem_prunes)

LOG_BIN=$(kv_get "$VARS_TSV" log_bin)
BINLOG_FORMAT=$(kv_get "$VARS_TSV" binlog_format)
SYNC_BINLOG=$(kv_get "$VARS_TSV" sync_binlog)
SERVER_ID=$(kv_get "$VARS_TSV" server_id)
READ_ONLY=$(kv_get "$VARS_TSV" read_only)
SUPER_READ_ONLY=$(kv_get "$VARS_TSV" super_read_only)

THREAD_CACHE_SIZE=$(kv_get "$VARS_TSV" thread_cache_size)
THREAD_CACHE_HITS=$(kv_get "$STATUS_TSV" Threads_cached)
OPEN_FILES_LIMIT=$(kv_get "$VARS_TSV" open_files_limit)
TABLE_OPEN_CACHE=$(kv_get "$VARS_TSV" table_open_cache)
OPENED_TABLES=$(kv_get "$STATUS_TSV" Opened_tables)
OPEN_TABLES=$(kv_get "$STATUS_TSV" Open_tables)

MAX_ALLOWED_PACKET=$(kv_get "$VARS_TSV" max_allowed_packet)

# ---- Output (JSON) ---------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  jq -n \
    --arg version "$SERVER_VERSION" \
    --arg flavor "$SERVER_FLAVOR" \
    --arg version_comment "$SERVER_COMMENT" \
    --arg uptime "$UPTIME" \
    --arg max_connections "$MAX_CONNECTIONS" \
    --arg max_used_connections "$MAX_USED_CONNECTIONS" \
    --arg threads_connected "$THREADS_CONNECTED" \
    --arg threads_running "$THREADS_RUNNING" \
    --arg threads_created "$THREADS_CREATED" \
    --arg connections "$CONNECTIONS" \
    --arg aborted_connects "$ABORTED_CONNECTS" \
    --arg aborted_clients "$ABORTED_CLIENTS" \
    --arg slow_query_log "$SLOW_QUERY_LOG" \
    --arg long_query_time "$LONG_QUERY_TIME" \
    --arg slow_queries "$SLOW_QUERIES" \
    --arg questions "$QUESTIONS" \
    --arg queries "$QUERIES" \
    --arg created_tmp_tables "$CREATED_TMP_TABLES" \
    --arg created_tmp_disk_tables "$CREATED_TMP_DISK_TABLES" \
    --arg created_tmp_files "$CREATED_TMP_FILES" \
    --arg tmp_table_size "$TMP_TABLE_SIZE" \
    --arg max_heap_table_size "$MAX_HEAP_TABLE_SIZE" \
    --arg innodb_buffer_pool_size "$INNODB_BP_SIZE" \
    --arg innodb_buffer_pool_instances "$INNODB_BP_INST" \
    --arg innodb_buffer_pool_read_requests "$INNODB_BP_READ_REQ" \
    --arg innodb_buffer_pool_reads "$INNODB_BP_READS" \
    --arg innodb_log_waits "$INNODB_LOG_WAITS" \
    --arg innodb_flush_log_at_trx_commit "$INNODB_FLUSH_TRX" \
    --arg innodb_log_buffer_size "$INNODB_LOG_BUFFER_SIZE" \
    --arg query_cache_type "$QCACHE_TYPE" \
    --arg query_cache_size "$QCACHE_SIZE" \
    --arg qcache_hits "$QCACHE_HITS" \
    --arg qcache_lowmem_prunes "$QCACHE_PRUNES" \
    --arg log_bin "$LOG_BIN" \
    --arg binlog_format "$BINLOG_FORMAT" \
    --arg sync_binlog "$SYNC_BINLOG" \
    --arg server_id "$SERVER_ID" \
    --arg read_only "$READ_ONLY" \
    --arg super_read_only "$SUPER_READ_ONLY" \
    --arg thread_cache_size "$THREAD_CACHE_SIZE" \
    --arg open_files_limit "$OPEN_FILES_LIMIT" \
    --arg table_open_cache "$TABLE_OPEN_CACHE" \
    --arg opened_tables "$OPENED_TABLES" \
    --arg open_tables "$OPEN_TABLES" \
    --arg max_allowed_packet "$MAX_ALLOWED_PACKET" \
    '{
      version:$version,
      flavor:$flavor,
      version_comment:$version_comment,
      uptime:$uptime,
      max_connections:$max_connections,
      max_used_connections:$max_used_connections,
      threads_connected:$threads_connected,
      threads_running:$threads_running,
      threads_created:$threads_created,
      connections:$connections,
      aborted_connects:$aborted_connects,
      aborted_clients:$aborted_clients,
      slow_query_log:$slow_query_log,
      long_query_time:$long_query_time,
      slow_queries:$slow_queries,
      questions:$questions,
      queries:$queries,
      created_tmp_tables:$created_tmp_tables,
      created_tmp_disk_tables:$created_tmp_disk_tables,
      created_tmp_files:$created_tmp_files,
      tmp_table_size:$tmp_table_size,
      max_heap_table_size:$max_heap_table_size,
      innodb_buffer_pool_size:$innodb_buffer_pool_size,
      innodb_buffer_pool_instances:$innodb_buffer_pool_instances,
      innodb_buffer_pool_read_requests:$innodb_buffer_pool_read_requests,
      innodb_buffer_pool_reads:$innodb_buffer_pool_reads,
      innodb_log_waits:$innodb_log_waits,
      innodb_flush_log_at_trx_commit:$innodb_flush_log_at_trx_commit,
      innodb_log_buffer_size:$innodb_log_buffer_size,
      query_cache_type:$query_cache_type,
      query_cache_size:$query_cache_size,
      qcache_hits:$qcache_hits,
      qcache_lowmem_prunes:$qcache_lowmem_prunes,
      log_bin:$log_bin,
      binlog_format:$binlog_format,
      sync_binlog:$sync_binlog,
      server_id:$server_id,
      read_only:$read_only,
      super_read_only:$super_read_only,
      thread_cache_size:$thread_cache_size,
      open_files_limit:$open_files_limit,
      table_open_cache:$table_open_cache,
      opened_tables:$opened_tables,
      open_tables:$open_tables,
      max_allowed_packet:$max_allowed_packet
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

section "Throughput"
qps=$(rate_per_s "$QUESTIONS" "$UPTIME_S")
info "Questions: $QUESTIONS (QPS: $qps)"

section "Connections"
info "max_connections:      $MAX_CONNECTIONS"
info "Max_used_connections: $MAX_USED_CONNECTIONS"
info "Threads_connected:    $THREADS_CONNECTED"
info "Threads_running:      $THREADS_RUNNING"
info "Threads_created:      $THREADS_CREATED"

mc=$(num "$MAX_CONNECTIONS")
tc=$(num "$THREADS_CONNECTED")
mu=$(num "$MAX_USED_CONNECTIONS")
if [ "$mc" -gt 0 ] && [ "$tc" -gt 0 ]; then
  pct_now=$(pct "$tc" "$mc")
  if [ "$pct_now" -ge 80 ]; then
    warn "High current connection usage: ${pct_now}% of max_connections"
  else
    ok "Current connection usage: ${pct_now}% of max_connections"
  fi
fi
if [ "$mc" -gt 0 ] && [ "$mu" -gt 0 ]; then
  pct_peak=$(pct "$mu" "$mc")
  if [ "$pct_peak" -ge 90 ]; then
    warn "Peak connection usage: ${pct_peak}% of max_connections"
  else
    ok "Peak connection usage: ${pct_peak}% of max_connections"
  fi
fi

ac=$(num "$ABORTED_CONNECTS")
if [ "$ac" -gt 0 ]; then
  warn "Aborted_connects: $ABORTED_CONNECTS"
fi

section "Slow Query Log"
[ -n "$SLOW_QUERY_LOG" ] && info "slow_query_log: $SLOW_QUERY_LOG"
[ -n "$LONG_QUERY_TIME" ] && info "long_query_time: $LONG_QUERY_TIME"
if [ "$(num "$SLOW_QUERIES")" -gt 0 ]; then
  warn "Slow_queries: $SLOW_QUERIES"
else
  ok "Slow_queries: $SLOW_QUERIES"
fi

section "Temporary Tables"
tmp=$(num "$CREATED_TMP_TABLES")
tmpdisk=$(num "$CREATED_TMP_DISK_TABLES")
info "Created_tmp_tables:      $CREATED_TMP_TABLES"
info "Created_tmp_disk_tables: $CREATED_TMP_DISK_TABLES"
info "tmp_table_size:          $(bytes_h "$TMP_TABLE_SIZE")"
info "max_heap_table_size:     $(bytes_h "$MAX_HEAP_TABLE_SIZE")"
if [ "$tmp" -gt 0 ] && [ "$tmpdisk" -gt 0 ]; then
  p=$(pct "$tmpdisk" "$tmp")
  if [ "$p" -ge 25 ]; then
    warn "High tmp tables on disk: ${p}% (consider increasing tmp_table_size/max_heap_table_size)"
  else
    ok "Tmp tables on disk: ${p}%"
  fi
fi

section "InnoDB"
[ -n "$INNODB_BP_SIZE" ] && info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"
[ -n "$INNODB_BP_INST" ] && info "innodb_buffer_pool_instances: $INNODB_BP_INST"
[ -n "$INNODB_FLUSH_TRX" ] && info "innodb_flush_log_at_trx_commit: $INNODB_FLUSH_TRX"
[ -n "$INNODB_LOG_BUFFER_SIZE" ] && info "innodb_log_buffer_size: $(bytes_h "$INNODB_LOG_BUFFER_SIZE")"

bprr=$(num "$INNODB_BP_READ_REQ")
bpr=$(num "$INNODB_BP_READS")
if [ "$bprr" -gt 0 ]; then
  hit=$((bprr - bpr))
  hp=$(pct "$hit" "$bprr")
  info "InnoDB BP hit rate: ${hp}%"
  if [ "$hp" -lt 95 ]; then
    warn "Low InnoDB buffer pool hit rate (${hp}%)"
  else
    ok "InnoDB buffer pool hit rate looks good (${hp}%)"
  fi
fi

if [ "$(num "$INNODB_LOG_WAITS")" -gt 0 ]; then
  warn "Innodb_log_waits: $INNODB_LOG_WAITS (consider tuning InnoDB redo/log settings)"
fi

section "Query Cache"
[ -n "$QCACHE_TYPE" ] && info "query_cache_type: $QCACHE_TYPE"
[ -n "$QCACHE_SIZE" ] && info "query_cache_size: $(bytes_h "$QCACHE_SIZE")"
if [ "$(num "$QCACHE_PRUNES")" -gt 0 ]; then
  warn "Qcache_lowmem_prunes: $QCACHE_PRUNES"
fi

section "Thread Cache"
[ -n "$THREAD_CACHE_SIZE" ] && info "thread_cache_size: $THREAD_CACHE_SIZE"
[ -n "$THREAD_CACHE_HITS" ] && info "Threads_cached: $THREAD_CACHE_HITS"

section "Table Open Cache"
[ -n "$TABLE_OPEN_CACHE" ] && info "table_open_cache: $TABLE_OPEN_CACHE"
[ -n "$OPEN_TABLES" ] && info "Open_tables: $OPEN_TABLES"
[ -n "$OPENED_TABLES" ] && info "Opened_tables: $OPENED_TABLES"

section "Replication (basic)"
[ -n "$LOG_BIN" ] && info "log_bin: $LOG_BIN"
[ -n "$BINLOG_FORMAT" ] && info "binlog_format: $BINLOG_FORMAT"
[ -n "$SYNC_BINLOG" ] && info "sync_binlog: $SYNC_BINLOG"
[ -n "$SERVER_ID" ] && info "server_id: $SERVER_ID"
[ -n "$READ_ONLY" ] && info "read_only: $READ_ONLY"
[ -n "$SUPER_READ_ONLY" ] && info "super_read_only: $SUPER_READ_ONLY"

section "Packet Size"
[ -n "$MAX_ALLOWED_PACKET" ] && info "max_allowed_packet: $(bytes_h "$MAX_ALLOWED_PACKET")"

ok "Collected: SHOW GLOBAL VARIABLES/STATUS"
warn "Next: implement full MySQLTuner-perl checks for feature parity."

exit 0
