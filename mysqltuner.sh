#!/bin/sh
# mysqltuner.sh - POSIX shell port (derived from MySQLTuner-perl)
# License: GPLv3 (see LICENSE.GPLv3)

set -u

VERSION="0.9.0-devel"

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
kv_get() { awk -F"\t" -v k="$2" '($1==k){sub(/^[^\t]*\t/, ""); print; exit}' "$1"; }
kv_dump_file() { mysql_query_silent "$1" | awk 'NF>=2{print $1"\t"$2}' >"$2"; }

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

mem_total_bytes() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/{printf "%d", $2*1024; exit}' /proc/meminfo
    return
  fi
  echo 0
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
TABLE_OPEN_CACHE=$(kv_get "$VARS_TSV" table_open_cache)
OPENED_TABLES=$(kv_get "$STATUS_TSV" Opened_tables)

MAX_ALLOWED_PACKET=$(kv_get "$VARS_TSV" max_allowed_packet)

# Memory-related vars (for rough estimates)
KEY_BUFFER_SIZE=$(kv_get "$VARS_TSV" key_buffer_size)
READ_BUFFER_SIZE=$(kv_get "$VARS_TSV" read_buffer_size)
READ_RND_BUFFER_SIZE=$(kv_get "$VARS_TSV" read_rnd_buffer_size)
SORT_BUFFER_SIZE=$(kv_get "$VARS_TSV" sort_buffer_size)
JOIN_BUFFER_SIZE=$(kv_get "$VARS_TSV" join_buffer_size)
THREAD_STACK=$(kv_get "$VARS_TSV" thread_stack)
QCACHE_SIZE=$(kv_get "$VARS_TSV" query_cache_size)

# Network/security exposure
BIND_ADDRESS=$(kv_get "$VARS_TSV" bind_address)
SKIP_NETWORKING=$(kv_get "$VARS_TSV" skip_networking)
PORT_VAR=$(kv_get "$VARS_TSV" port)

# Security-related variables
SKIP_NAME_RESOLVE=$(kv_get "$VARS_TSV" skip_name_resolve)
LOCAL_INFILE=$(kv_get "$VARS_TSV" local_infile)
REQUIRE_SECURE_TRANSPORT=$(kv_get "$VARS_TSV" require_secure_transport)
HAVE_SSL=$(kv_get "$VARS_TSV" have_ssl)
PERFORMANCE_SCHEMA=$(kv_get "$VARS_TSV" performance_schema)

# Derived metrics
QPS=$(rate_per_s "$QUESTIONS" "$UPTIME_S")
ABORT_PCT=$(pct "$ABORTED_CONNECTS" "$CONNECTIONS")
OPENED_TABLES_PS=$(rate_per_s "$OPENED_TABLES" "$UPTIME_S")

# Memory estimate (best-effort)
RAM_TOTAL=$(mem_total_bytes)
GLOBAL_BUFFERS=$(awk -v a="$(num "$KEY_BUFFER_SIZE")" -v b="$(num "$INNODB_BP_SIZE")" -v c="$(num "$QCACHE_SIZE")" 'BEGIN{printf "%d", a+b+c}')
PER_THREAD_BUFFERS=$(awk -v a="$(num "$READ_BUFFER_SIZE")" -v b="$(num "$READ_RND_BUFFER_SIZE")" -v c="$(num "$SORT_BUFFER_SIZE")" -v d="$(num "$JOIN_BUFFER_SIZE")" -v e="$(num "$THREAD_STACK")" 'BEGIN{printf "%d", a+b+c+d+e}')
MAX_MEM=$(awk -v g="$GLOBAL_BUFFERS" -v p="$PER_THREAD_BUFFERS" -v mc="$(num "$MAX_CONNECTIONS")" 'BEGIN{printf "%d", g + (p*mc)}')

# Try to read mysql.user (may fail if no privileges)
USER_ROWS=$(mysql_query_silent "SELECT user,host,plugin,authentication_string FROM mysql.user" 2>/dev/null || true)
USER_COL4="authentication_string"
if [ -z "$USER_ROWS" ]; then
  USER_ROWS=$(mysql_query_silent "SELECT user,host,plugin,password FROM mysql.user" 2>/dev/null || true)
  USER_COL4="password"
fi

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
    --arg aborted_connects_pct "$ABORT_PCT" \
    --arg opened_tables_per_s "$OPENED_TABLES_PS" \
    --arg slow_query_log "$SLOW_QUERY_LOG" \
    --arg slow_queries "$SLOW_QUERIES" \
    --arg innodb_buffer_pool_size "$INNODB_BP_SIZE" \
    --arg innodb_buffer_pool_read_requests "$INNODB_BP_READ_REQ" \
    --arg innodb_buffer_pool_reads "$INNODB_BP_READS" \
    --arg bind_address "$BIND_ADDRESS" \
    --arg skip_networking "$SKIP_NETWORKING" \
    --arg port "$PORT_VAR" \
    --arg skip_name_resolve "$SKIP_NAME_RESOLVE" \
    --arg local_infile "$LOCAL_INFILE" \
    --arg require_secure_transport "$REQUIRE_SECURE_TRANSPORT" \
    --arg have_ssl "$HAVE_SSL" \
    --arg performance_schema "$PERFORMANCE_SCHEMA" \
    --arg max_allowed_packet "$MAX_ALLOWED_PACKET" \
    --arg mysql_user_readable "$( [ -n "$USER_ROWS" ] && echo yes || echo no )" \
    --arg mysql_user_col4 "$USER_COL4" \
    --arg ram_total_bytes "$RAM_TOTAL" \
    --arg global_buffers_bytes "$GLOBAL_BUFFERS" \
    --arg per_thread_buffers_bytes "$PER_THREAD_BUFFERS" \
    --arg max_memory_estimate_bytes "$MAX_MEM" \
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
      aborted_connects_pct:$aborted_connects_pct,
      opened_tables_per_s:$opened_tables_per_s,
      slow_query_log:$slow_query_log,
      slow_queries:$slow_queries,
      innodb_buffer_pool_size:$innodb_buffer_pool_size,
      innodb_buffer_pool_read_requests:$innodb_buffer_pool_read_requests,
      innodb_buffer_pool_reads:$innodb_buffer_pool_reads,
      bind_address:$bind_address,
      skip_networking:$skip_networking,
      port:$port,
      skip_name_resolve:$skip_name_resolve,
      local_infile:$local_infile,
      require_secure_transport:$require_secure_transport,
      have_ssl:$have_ssl,
      performance_schema:$performance_schema,
      max_allowed_packet:$max_allowed_packet,
      mysql_user_readable:$mysql_user_readable,
      mysql_user_col4:$mysql_user_col4,
      ram_total_bytes:$ram_total_bytes,
      global_buffers_bytes:$global_buffers_bytes,
      per_thread_buffers_bytes:$per_thread_buffers_bytes,
      max_memory_estimate_bytes:$max_memory_estimate_bytes
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
info "Aborted_connects:     $ABORTED_CONNECTS (${ABORT_PCT}%)"
[ "$(num "$ABORTED_CONNECTS")" -gt 0 ] && [ "$ABORT_PCT" -ge 5 ] && warn "High aborted connect rate (${ABORT_PCT}%)"

section "Memory"
info "key_buffer_size:         $(bytes_h "$KEY_BUFFER_SIZE")"
info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"
info "query_cache_size:        $(bytes_h "$QCACHE_SIZE")"
info "Global buffers:          $(bytes_h "$GLOBAL_BUFFERS")"
info "Per-thread buffers:      $(bytes_h "$PER_THREAD_BUFFERS")"
info "Max memory estimate:     $(bytes_h "$MAX_MEM") (global + per-thread*max_connections)"
if [ "$(num "$RAM_TOTAL")" -gt 0 ]; then
  info "System RAM (best-effort): $(bytes_h "$RAM_TOTAL")"
  mempct=$(pct "$MAX_MEM" "$RAM_TOTAL")
  [ "$mempct" -ge 85 ] && warn "Max memory estimate high (${mempct}% of RAM)" || ok "Max memory estimate: ${mempct}% of RAM"
else
  info "System RAM unknown; skipping RAM comparison"
fi

section "Slow Query Log"
[ -n "$SLOW_QUERY_LOG" ] && info "slow_query_log: $SLOW_QUERY_LOG"
[ -n "$LONG_QUERY_TIME" ] && info "long_query_time: $LONG_QUERY_TIME"
[ "$(num "$SLOW_QUERIES")" -gt 0 ] && warn "Slow_queries: $SLOW_QUERIES" || ok "Slow_queries: $SLOW_QUERIES"

section "Temporary Tables"
info "Created_tmp_tables:      $CREATED_TMP_TABLES"
info "Created_tmp_disk_tables: $CREATED_TMP_DISK_TABLES"
info "tmp_table_size:          $(bytes_h "$TMP_TABLE_SIZE")"
info "max_heap_table_size:     $(bytes_h "$MAX_HEAP_TABLE_SIZE")"

tmp=$(num "$CREATED_TMP_TABLES")
tmpdisk=$(num "$CREATED_TMP_DISK_TABLES")
if [ "$tmp" -gt 0 ] && [ "$tmpdisk" -gt 0 ]; then
  p=$(pct "$tmpdisk" "$tmp")
  [ "$p" -ge 25 ] && warn "High tmp tables on disk: ${p}%" || ok "Tmp tables on disk: ${p}%"
fi

section "InnoDB"
[ -n "$INNODB_BP_SIZE" ] && info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"

bprr=$(num "$INNODB_BP_READ_REQ")
bpr=$(num "$INNODB_BP_READS")
if [ "$bprr" -gt 0 ]; then
  hit=$((bprr - bpr)); [ "$hit" -lt 0 ] && hit=0
  hp=$(pct "$hit" "$bprr")
  info "InnoDB BP hit rate: ${hp}%"
  [ "$hp" -lt 95 ] && warn "Low InnoDB buffer pool hit rate (${hp}%)" || ok "InnoDB buffer pool hit rate (${hp}%)"
fi

section "Table Open Cache"
info "table_open_cache:  $TABLE_OPEN_CACHE"
info "Opened_tables:     $OPENED_TABLES (~${OPENED_TABLES_PS}/s)"

section "Packet Size"
info "max_allowed_packet: $(bytes_h "$MAX_ALLOWED_PACKET")"
[ "$(num "$MAX_ALLOWED_PACKET")" -lt 16777216 ] && warn "max_allowed_packet below 16MiB" || ok "max_allowed_packet looks OK"

section "Network"
[ -n "$PORT_VAR" ] && info "port: $PORT_VAR"
[ -n "$BIND_ADDRESS" ] && info "bind_address: $BIND_ADDRESS"
[ -n "$SKIP_NETWORKING" ] && info "skip_networking: $SKIP_NETWORKING"

if [ "$SKIP_NETWORKING" = "ON" ]; then
  ok "skip_networking is ON (TCP disabled)"
else
  case "$BIND_ADDRESS" in
    0.0.0.0|::|*)
      if [ "$BIND_ADDRESS" = "0.0.0.0" ] || [ "$BIND_ADDRESS" = "::" ]; then
        warn "bind_address is $BIND_ADDRESS (listens on all interfaces)"
      fi
      ;;
  esac
fi

section "Security (basic)"
[ -n "$SKIP_NAME_RESOLVE" ] && info "skip_name_resolve: $SKIP_NAME_RESOLVE"
[ -n "$LOCAL_INFILE" ] && info "local_infile: $LOCAL_INFILE"
[ -n "$HAVE_SSL" ] && info "have_ssl: $HAVE_SSL"
[ -n "$REQUIRE_SECURE_TRANSPORT" ] && info "require_secure_transport: $REQUIRE_SECURE_TRANSPORT"
[ -n "$PERFORMANCE_SCHEMA" ] && info "performance_schema: $PERFORMANCE_SCHEMA"

[ "$LOCAL_INFILE" = "ON" ] && warn "local_infile is ON (consider OFF unless required)" || true
[ "$REQUIRE_SECURE_TRANSPORT" = "OFF" ] && warn "require_secure_transport is OFF (consider ON if you require TLS)" || true

section "Users (best-effort)"
if [ -n "$USER_ROWS" ]; then
  info "mysql.user readable; checking common issues (col4=$USER_COL4)"

  if printf "%s\n" "$USER_ROWS" | awk -F"\t" '($1=="" && $2!=""){exit 0} END{exit 1}'; then
    warn "Anonymous user accounts exist"
  else
    ok "No anonymous user rows detected"
  fi

  if printf "%s\n" "$USER_ROWS" | awk -F"\t" '($2=="%"){exit 0} END{exit 1}'; then
    warn "Accounts with host=% exist"
  else
    ok "No host=% rows detected"
  fi

  if printf "%s\n" "$USER_ROWS" | awk -F"\t" '($1=="root" && $2=="%"){exit 0} END{exit 1}'; then
    warn "root@% exists"
  fi

  if printf "%s\n" "$USER_ROWS" | awk -F"\t" '($1!="" && $4==""){exit 0} END{exit 1}'; then
    warn "Empty $USER_COL4 detected (possible empty passwords)"
  else
    ok "No empty $USER_COL4 detected"
  fi
else
  info "mysql.user not readable; skipping user checks"
fi

ok "Collected: SHOW GLOBAL VARIABLES/STATUS"
warn "Next: implement full MySQLTuner-perl checks for feature parity."

exit 0
