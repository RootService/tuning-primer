#!/bin/sh
# mysqltuner.sh - POSIX shell port (derived from MySQLTuner-perl)
# License: GPLv3 (see LICENSE.GPLv3)

set -u

VERSION="0.5.0-devel"

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

die() { echo "ERROR: $*" 1>&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"; }

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
  [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ] && rm -rf "$WORKDIR" >/dev/null 2>&1 || true
}

# ---- Argument parsing (POSIX-compatible) -----------------------------------
HOST=""; PORT=""; SOCKET=""; USER=""; PASS=""; DEFAULTS_FILE=""; SILENT=0; JSON=0

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
need_cmd tr
need_cmd head
need_cmd printf
need_cmd jq

# ---- MySQL command builder -------------------------------------------------
MYSQL_CMD="mysql"
MYSQL_ARGS="--batch --raw --skip-column-names"

[ -n "$DEFAULTS_FILE" ] && MYSQL_ARGS="$MYSQL_ARGS --defaults-file=$DEFAULTS_FILE"
[ -n "$HOST" ] && MYSQL_ARGS="$MYSQL_ARGS -h $HOST"
[ -n "$PORT" ] && MYSQL_ARGS="$MYSQL_ARGS -P $PORT"
[ -n "$SOCKET" ] && MYSQL_ARGS="$MYSQL_ARGS -S $SOCKET"
[ -n "$USER" ] && MYSQL_ARGS="$MYSQL_ARGS -u $USER"
# WARNING: passing password on CLI can leak via process list
[ -n "$PASS" ] && MYSQL_ARGS="$MYSQL_ARGS -p$PASS"

mysql_query() {
  # shellcheck disable=SC2086
  echo "$1" | $MYSQL_CMD $MYSQL_ARGS
}
mysql_query_silent() { mysql_query "$1" 2>/dev/null; }

# ---- KV helpers ------------------------------------------------------------
kv_get() {
  awk -F"\t" -v k="$2" '($1==k){sub(/^[^\t]*\t/, ""); print; exit}' "$1"
}
kv_dump_file() {
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
  v=$(num "$1"); u=$(num "$2")
  [ "$u" -le 0 ] && { echo 0; return; }
  awk -v v="$v" -v u="$u" 'BEGIN{printf "%.2f", v/u}'
}

pct() {
  a=$(num "$1"); b=$(num "$2")
  [ "$b" -le 0 ] && { echo 0; return; }
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
section() { [ "$SILENT" -eq 1 ] && return 0; echo; echo "== $* =="; }
info()    { [ "$SILENT" -eq 1 ] && return 0; echo "[INFO] $*"; }
warn()    { [ "$SILENT" -eq 1 ] && return 0; echo "[WARN] $*"; }
ok()      { [ "$SILENT" -eq 1 ] && return 0; echo "[OK]   $*"; }

# ---- Core collection -------------------------------------------------------
WORKDIR="$(mktemp_dir)" || die "unable to create temp dir"
trap cleanup EXIT HUP INT TERM

VARS_TSV="$WORKDIR/variables.tsv"
STATUS_TSV="$WORKDIR/status.tsv"

mysql_query_silent "SELECT 1;" >/dev/null 2>&1 || die "unable to connect (check credentials/host/socket)"

kv_dump_file "SHOW GLOBAL VARIABLES" "$VARS_TSV"
kv_dump_file "SHOW GLOBAL STATUS" "$STATUS_TSV"

SERVER_VERSION=$(mysql_query_silent "SELECT VERSION();" | head -n 1 | tr -d '\r')
SERVER_COMMENT=$(kv_get "$VARS_TSV" version_comment | tr -d '\r')
SERVER_FLAVOR="mysql"
case "$SERVER_VERSION" in *MariaDB*) SERVER_FLAVOR="mariadb" ;; esac

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

CREATED_TMP_TABLES=$(kv_get "$STATUS_TSV" Created_tmp_tables)
CREATED_TMP_DISK_TABLES=$(kv_get "$STATUS_TSV" Created_tmp_disk_tables)
TMP_TABLE_SIZE=$(kv_get "$VARS_TSV" tmp_table_size)
MAX_HEAP_TABLE_SIZE=$(kv_get "$VARS_TSV" max_heap_table_size)

INNODB_BP_SIZE=$(kv_get "$VARS_TSV" innodb_buffer_pool_size)
INNODB_BP_READ_REQ=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_read_requests)
INNODB_BP_READS=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_reads)

THREAD_CACHE_SIZE=$(kv_get "$VARS_TSV" thread_cache_size)
OPEN_FILES_LIMIT=$(kv_get "$VARS_TSV" open_files_limit)
TABLE_OPEN_CACHE=$(kv_get "$VARS_TSV" table_open_cache)
OPENED_TABLES=$(kv_get "$STATUS_TSV" Opened_tables)
OPEN_TABLES=$(kv_get "$STATUS_TSV" Open_tables)

MAX_ALLOWED_PACKET=$(kv_get "$VARS_TSV" max_allowed_packet)

# Derived metrics
QPS=$(rate_per_s "$QUESTIONS" "$UPTIME_S")
ABORT_PCT=$(pct "$ABORTED_CONNECTS" "$CONNECTIONS")
TC_HIT_PCT=0
c=$(num "$CONNECTIONS")
tc=$(num "$THREADS_CREATED")
if [ "$c" -gt 0 ] && [ "$tc" -ge 0 ]; then
  hits=$((c - tc))
  [ "$hits" -lt 0 ] && hits=0
  TC_HIT_PCT=$(pct "$hits" "$c")
fi
OPENED_TABLES_PS=$(rate_per_s "$OPENED_TABLES" "$UPTIME_S")

# ---- Output (JSON) ---------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  jq -n \
    --arg version "$SERVER_VERSION" \
    --arg flavor "$SERVER_FLAVOR" \
    --arg version_comment "$SERVER_COMMENT" \
    --arg uptime "$UPTIME" \
    --arg qps "$QPS" \
    --arg max_connections "$MAX_CONNECTIONS" \
    --arg max_used_connections "$MAX_USED_CONNECTIONS" \
    --arg threads_connected "$THREADS_CONNECTED" \
    --arg threads_running "$THREADS_RUNNING" \
    --arg threads_created "$THREADS_CREATED" \
    --arg connections "$CONNECTIONS" \
    --arg aborted_connects "$ABORTED_CONNECTS" \
    --arg aborted_connects_pct "$ABORT_PCT" \
    --arg thread_cache_size "$THREAD_CACHE_SIZE" \
    --arg thread_cache_hit_pct "$TC_HIT_PCT" \
    --arg open_files_limit "$OPEN_FILES_LIMIT" \
    --arg table_open_cache "$TABLE_OPEN_CACHE" \
    --arg opened_tables "$OPENED_TABLES" \
    --arg opened_tables_per_s "$OPENED_TABLES_PS" \
    --arg open_tables "$OPEN_TABLES" \
    --arg slow_query_log "$SLOW_QUERY_LOG" \
    --arg long_query_time "$LONG_QUERY_TIME" \
    --arg slow_queries "$SLOW_QUERIES" \
    --arg created_tmp_tables "$CREATED_TMP_TABLES" \
    --arg created_tmp_disk_tables "$CREATED_TMP_DISK_TABLES" \
    --arg tmp_table_size "$TMP_TABLE_SIZE" \
    --arg max_heap_table_size "$MAX_HEAP_TABLE_SIZE" \
    --arg innodb_buffer_pool_size "$INNODB_BP_SIZE" \
    --arg innodb_buffer_pool_read_requests "$INNODB_BP_READ_REQ" \
    --arg innodb_buffer_pool_reads "$INNODB_BP_READS" \
    --arg max_allowed_packet "$MAX_ALLOWED_PACKET" \
    '{
      version:$version,
      flavor:$flavor,
      version_comment:$version_comment,
      uptime:$uptime,
      qps:$qps,
      max_connections:$max_connections,
      max_used_connections:$max_used_connections,
      threads_connected:$threads_connected,
      threads_running:$threads_running,
      threads_created:$threads_created,
      connections:$connections,
      aborted_connects:$aborted_connects,
      aborted_connects_pct:$aborted_connects_pct,
      thread_cache_size:$thread_cache_size,
      thread_cache_hit_pct:$thread_cache_hit_pct,
      open_files_limit:$open_files_limit,
      table_open_cache:$table_open_cache,
      opened_tables:$opened_tables,
      opened_tables_per_s:$opened_tables_per_s,
      open_tables:$open_tables,
      slow_query_log:$slow_query_log,
      long_query_time:$long_query_time,
      slow_queries:$slow_queries,
      created_tmp_tables:$created_tmp_tables,
      created_tmp_disk_tables:$created_tmp_disk_tables,
      tmp_table_size:$tmp_table_size,
      max_heap_table_size:$max_heap_table_size,
      innodb_buffer_pool_size:$innodb_buffer_pool_size,
      innodb_buffer_pool_read_requests:$innodb_buffer_pool_read_requests,
      innodb_buffer_pool_reads:$innodb_buffer_pool_reads,
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
info "Uptime (s):      $UPTIME"

section "Throughput"
info "Questions: $QUESTIONS (QPS: $QPS)"

section "Connections"
info "max_connections:      $MAX_CONNECTIONS"
info "Max_used_connections: $MAX_USED_CONNECTIONS"
info "Threads_connected:    $THREADS_CONNECTED"
info "Threads_running:      $THREADS_RUNNING"
info "Threads_created:      $THREADS_CREATED"
info "Connections:          $CONNECTIONS"
info "Aborted_connects:     $ABORTED_CONNECTS (${ABORT_PCT}%)"

if [ "$(num "$ABORTED_CONNECTS")" -gt 0 ] && [ "$ABORT_PCT" -ge 5 ]; then
  warn "High aborted connect rate (${ABORT_PCT}%)"
fi

section "Thread Cache"
info "thread_cache_size: $THREAD_CACHE_SIZE"
info "Thread cache hit:  ${TC_HIT_PCT}% (approx via Connections - Threads_created)"
if [ "$(num "$THREAD_CACHE_SIZE")" -gt 0 ] && [ "$TC_HIT_PCT" -lt 90 ]; then
  warn "Low thread cache hit rate (${TC_HIT_PCT}%). Consider increasing thread_cache_size."
fi

section "Table Open Cache"
info "open_files_limit:  $OPEN_FILES_LIMIT"
info "table_open_cache:  $TABLE_OPEN_CACHE"
info "Open_tables:       $OPEN_TABLES"
info "Opened_tables:     $OPENED_TABLES (~${OPENED_TABLES_PS}/s)"
if [ "$(num "$TABLE_OPEN_CACHE")" -gt 0 ] && [ "$(num "$OPENED_TABLES")" -gt 0 ] && [ "$(num "$UPTIME_S")" -gt 0 ]; then
  if awk -v r="$OPENED_TABLES_PS" 'BEGIN{exit !(r>1)}'; then
    warn "High table cache churn (Opened_tables ~${OPENED_TABLES_PS}/s). Consider increasing table_open_cache."
  else
    ok "Table cache churn looks OK (Opened_tables ~${OPENED_TABLES_PS}/s)."
  fi
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
info "Created_tmp_tables:      $CREATED_TMP_TABLES"
info "Created_tmp_disk_tables: $CREATED_TMP_DISK_TABLES"
info "tmp_table_size:          $(bytes_h "$TMP_TABLE_SIZE")"
info "max_heap_table_size:     $(bytes_h "$MAX_HEAP_TABLE_SIZE")"

tmp=$(num "$CREATED_TMP_TABLES")
tmpdisk=$(num "$CREATED_TMP_DISK_TABLES")
if [ "$tmp" -gt 0 ] && [ "$tmpdisk" -gt 0 ]; then
  p=$(pct "$tmpdisk" "$tmp")
  if [ "$p" -ge 25 ]; then
    warn "High tmp tables on disk: ${p}% (increase tmp_table_size/max_heap_table_size)"
  else
    ok "Tmp tables on disk: ${p}%"
  fi
fi

section "InnoDB"
[ -n "$INNODB_BP_SIZE" ] && info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"

bprr=$(num "$INNODB_BP_READ_REQ")
bpr=$(num "$INNODB_BP_READS")
if [ "$bprr" -gt 0 ]; then
  hit=$((bprr - bpr))
  [ "$hit" -lt 0 ] && hit=0
  hp=$(pct "$hit" "$bprr")
  info "InnoDB BP hit rate: ${hp}%"
  [ "$hp" -lt 95 ] && warn "Low InnoDB buffer pool hit rate (${hp}%)"
fi

section "Packet Size"
info "max_allowed_packet: $(bytes_h "$MAX_ALLOWED_PACKET")"
if [ "$(num "$MAX_ALLOWED_PACKET")" -lt 16777216 ]; then
  warn "max_allowed_packet is below 16MiB; may cause issues with large queries/replication"
fi

ok "Collected: SHOW GLOBAL VARIABLES/STATUS"
warn "Next: implement full MySQLTuner-perl checks for feature parity."

exit 0
