#!/bin/sh
# mysqltuner.sh - POSIX shell port (derived from MySQLTuner-perl)
# License: GPLv3 (see LICENSE.GPLv3)

set -u

VERSION="2.2.0-devel"

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

Security/data options:
  --cvefile <path>           (default: ./vulnerabilities.csv if present)
  --passwordfile <path>      (default: ./basic_passwords.txt if present; else /usr/share/mysqltuner/basic_passwords.txt)
  --max-password-checks <n>  (default: 500)

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
CVEFILE=""
PASSWORDFILE=""
MAX_PASSWORD_CHECKS=500

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
    --cvefile) shift; CVEFILE="${1-}" ;;
    --passwordfile) shift; PASSWORDFILE="${1-}" ;;
    --max-password-checks) shift; MAX_PASSWORD_CHECKS="${1-}" ;;
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
need_cmd sed

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

# With column names (first row is header)
mysql_query_table() {
  # shellcheck disable=SC2086
  echo "$1" | $MYSQL_CMD ${MYSQL_ARGS% --skip-column-names} 2>/dev/null
}

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

# ---- Version parsing --------------------------------------------------------
parse_semver3() {
  v="$1"
  v=$(printf "%s" "$v" | tr -cd '0123456789.' | awk -F. '{print $1"."$2"."$3}')
  maj=$(printf "%s" "$v" | awk -F. '{print $1}')
  min=$(printf "%s" "$v" | awk -F. '{print $2}')
  mic=$(printf "%s" "$v" | awk -F. '{print $3}')
  maj=$(num "$maj"); min=$(num "$min"); mic=$(num "$mic")
  echo "$maj $min $mic"
}

# ---- CVE checks ------------------------------------------------------------
check_cves() {
  [ -z "$CVEFILE" ] && return 0
  [ ! -f "$CVEFILE" ] && return 0

  cvefound=0
  CVE_LIST_JSON="[]"

  while IFS=';' read -r f0 f1 f2 f3 f4 f5 f6 rest; do
    [ -z "${f4:-}" ] && continue

    maj=$(num "${f1:-0}")
    min=$(num "${f2:-0}")
    mic=$(num "${f3:-0}")

    [ "$maj" -ne "$MYSQL_VER_MAJ" ] && continue
    [ "$min" -ne "$MYSQL_VER_MIN" ] && continue

    if [ "$mic" -ge "$MYSQL_VER_MIC" ]; then
      cve_id="$f4"
      desc="$f6"
      cvefound=$((cvefound + 1))

      if [ "$JSON" -eq 1 ]; then
        CVE_LIST_JSON=$(printf '%s' "$CVE_LIST_JSON" | jq -c --arg id "$cve_id" --arg v "${maj}.${min}.${mic}" --arg d "$desc" '. + [{id:$id, affected_le:$v, desc:$d}]')
      else
        warn "$cve_id(<= ${maj}.${min}.${mic}): $desc"
      fi
    fi
  done <"$CVEFILE"

  CVE_FOUND="$cvefound"
}

# ---- Weak password checks (MySQL < 8 only, best-effort) ---------------------
check_weak_passwords_pre8() {
  WEAK_PASSWORD_HITS=0
  WEAK_PASSWORD_USERS_JSON="[]"

  [ -z "$PASSWORDFILE" ] && return 0
  [ ! -f "$PASSWORDFILE" ] && return 0
  [ "$MYSQL_VER_MAJ" -ge 8 ] && return 0
  [ "${MYSQL_USER_READABLE:-no}" != "yes" ] && return 0

  PASS_COL="$USER_COL4"

  n=0
  while IFS= read -r line; do
    p=$(printf "%s" "$line" | tr -d '\r' | tr -d ' \t')
    [ -z "$p" ] && continue

    n=$((n + 1))
    [ "$n" -gt "$(num "$MAX_PASSWORD_CHECKS")" ] && break

    psql=$(printf "%s" "$p" | awk '{gsub(/\047/,"\\\047"); printf "%s", $0}')

    q="SELECT CONCAT(user,'@',host) FROM mysql.user WHERE ${PASS_COL} = PASSWORD('${psql}') OR ${PASS_COL} = PASSWORD(UPPER('${psql}')) OR ${PASS_COL} = PASSWORD(CONCAT(UPPER(LEFT('${psql}',1)), SUBSTRING('${psql}',2,LENGTH('${psql}'))));"

    hits=$(mysql_query_silent "$q" | tr -d '\r' || true)
    if [ -n "$hits" ]; then
      WEAK_PASSWORD_HITS=$((WEAK_PASSWORD_HITS + 1))
      if [ "$JSON" -eq 1 ]; then
        while IFS= read -r u; do
          [ -z "$u" ] && continue
          WEAK_PASSWORD_USERS_JSON=$(printf '%s' "$WEAK_PASSWORD_USERS_JSON" | jq -c --arg user "$u" --arg pass "$p" '. + [{user:$user, pass:$pass}]')
        done <<EOF
$hits
EOF
      else
        while IFS= read -r u; do
          [ -z "$u" ] && continue
          warn "User '$u' is using weak password: $p (or case variant)"
        done <<EOF
$hits
EOF
      fi
    fi

    if [ $((n % 100)) -eq 0 ]; then
      mysql_query_silent "FLUSH HOSTS;" >/dev/null 2>&1 || true
    fi
  done <"$PASSWORDFILE"
}

# ---- Replication checks (best-effort) --------------------------------------
replication_parse_show_status() {
  # Input: table output (header + 1 row)
  # Output: sets globals REPL_* variables
  REPL_ROLE="none"
  REPL_IO_RUNNING=""
  REPL_SQL_RUNNING=""
  REPL_SECONDS_BEHIND=""
  REPL_SOURCE_HOST=""
  REPL_SOURCE_PORT=""
  REPL_LAST_IO_ERROR=""
  REPL_LAST_SQL_ERROR=""

  # Build header->index map; then pick fields with fallbacks for MySQL8 naming
  # shellcheck disable=SC2016
  echo "$1" | awk -F"\t" '
    NR==1{
      for(i=1;i<=NF;i++){h[$i]=i}
      next
    }
    NR==2{
      # Slave/Replica io/sql running
      if (h["Slave_IO_Running"]) io=$(h["Slave_IO_Running"])
      else if (h["Replica_IO_Running"]) io=$(h["Replica_IO_Running"])
      else if (h["Receiver_IO_Running"]) io=$(h["Receiver_IO_Running"])
      else io=""

      if (h["Slave_SQL_Running"]) sql=$(h["Slave_SQL_Running"])
      else if (h["Replica_SQL_Running"]) sql=$(h["Replica_SQL_Running"])
      else if (h["Applier_SQL_Running"]) sql=$(h["Applier_SQL_Running"])
      else sql=""

      if (h["Seconds_Behind_Master"]) sbm=$(h["Seconds_Behind_Master"])
      else if (h["Seconds_Behind_Source"]) sbm=$(h["Seconds_Behind_Source"])
      else sbm=""

      if (h["Master_Host"]) shost=$(h["Master_Host"])
      else if (h["Source_Host"]) shost=$(h["Source_Host"])
      else shost=""

      if (h["Master_Port"]) sport=$(h["Master_Port"])
      else if (h["Source_Port"]) sport=$(h["Source_Port"])
      else sport=""

      if (h["Last_IO_Error"]) lio=$(h["Last_IO_Error"])
      else if (h["Last_IO_Error_Message"]) lio=$(h["Last_IO_Error_Message"])
      else lio=""

      if (h["Last_SQL_Error"]) lsql=$(h["Last_SQL_Error"])
      else if (h["Last_SQL_Error_Message"]) lsql=$(h["Last_SQL_Error_Message"])
      else lsql=""

      printf "IO=%s\nSQL=%s\nSBM=%s\nSHOST=%s\nSPORT=%s\nLIO=%s\nLSQL=%s\n", io, sql, sbm, shost, sport, lio, lsql
    }
  '
}

check_replication() {
  REPL_ROLE="none"
  REPL_IO_RUNNING=""
  REPL_SQL_RUNNING=""
  REPL_SECONDS_BEHIND=""
  REPL_SOURCE_HOST=""
  REPL_SOURCE_PORT=""
  REPL_LAST_IO_ERROR=""
  REPL_LAST_SQL_ERROR=""
  MASTER_LOG_FILE=""
  MASTER_LOG_POS=""

  # Master status (if binlog enabled)
  ms=$(mysql_query_table "SHOW MASTER STATUS;" | tr -d '\r' || true)
  if [ -n "$ms" ]; then
    MASTER_LOG_FILE=$(printf "%s\n" "$ms" | awk -F"\t" 'NR==1{for(i=1;i<=NF;i++){h[$i]=i};next} NR==2{if(h["File"])print $(h["File"]); exit}')
    MASTER_LOG_POS=$(printf "%s\n" "$ms" | awk -F"\t" 'NR==1{for(i=1;i<=NF;i++){h[$i]=i};next} NR==2{if(h["Position"])print $(h["Position"]); exit}')
    [ -n "$MASTER_LOG_FILE" ] && REPL_ROLE="master"
  fi

  # Slave/Replica status
  ss=$(mysql_query_table "SHOW SLAVE STATUS;" | tr -d '\r' || true)
  if [ -z "$ss" ]; then
    ss=$(mysql_query_table "SHOW REPLICA STATUS;" | tr -d '\r' || true)
  fi

  if [ -n "$ss" ]; then
    parsed=$(replication_parse_show_status "$ss")
    REPL_IO_RUNNING=$(printf "%s\n" "$parsed" | awk -F= '/^IO=/{print $2; exit}')
    REPL_SQL_RUNNING=$(printf "%s\n" "$parsed" | awk -F= '/^SQL=/{print $2; exit}')
    REPL_SECONDS_BEHIND=$(printf "%s\n" "$parsed" | awk -F= '/^SBM=/{print $2; exit}')
    REPL_SOURCE_HOST=$(printf "%s\n" "$parsed" | awk -F= '/^SHOST=/{print $2; exit}')
    REPL_SOURCE_PORT=$(printf "%s\n" "$parsed" | awk -F= '/^SPORT=/{print $2; exit}')
    REPL_LAST_IO_ERROR=$(printf "%s\n" "$parsed" | awk -F= '/^LIO=/{print $2; exit}')
    REPL_LAST_SQL_ERROR=$(printf "%s\n" "$parsed" | awk -F= '/^LSQL=/{print $2; exit}')

    # if both master and slave signals, treat as both
    if [ "$REPL_ROLE" = "master" ]; then REPL_ROLE="master+replica"; else REPL_ROLE="replica"; fi
  fi
}

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

# Default files if not provided
if [ -z "$CVEFILE" ] && [ -f ./vulnerabilities.csv ]; then
  CVEFILE=./vulnerabilities.csv
fi

if [ -z "$PASSWORDFILE" ]; then
  if [ -f ./basic_passwords.txt ]; then
    PASSWORDFILE=./basic_passwords.txt
  elif [ -f /usr/share/mysqltuner/basic_passwords.txt ]; then
    PASSWORDFILE=/usr/share/mysqltuner/basic_passwords.txt
  fi
fi

set -- $(parse_semver3 "$SERVER_VERSION")
MYSQL_VER_MAJ="$1"; MYSQL_VER_MIN="$2"; MYSQL_VER_MIC="$3"

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

OPEN_TABLES=$(kv_get "$STATUS_TSV" Open_tables)

SLOW_QUERY_LOG=$(kv_get "$VARS_TSV" slow_query_log)
LONG_QUERY_TIME=$(kv_get "$VARS_TSV" long_query_time)
SLOW_QUERIES=$(kv_get "$STATUS_TSV" Slow_queries)

QUESTIONS=$(kv_get "$STATUS_TSV" Questions)

CREATED_TMP_TABLES=$(kv_get "$STATUS_TSV" Created_tmp_tables)
CREATED_TMP_DISK_TABLES=$(kv_get "$STATUS_TSV" Created_tmp_disk_tables)
TMP_TABLE_SIZE=$(kv_get "$VARS_TSV" tmp_table_size)
MAX_HEAP_TABLE_SIZE=$(kv_get "$VARS_TSV" max_heap_table_size)

INNODB_BP_SIZE=$(kv_get "$VARS_TSV" innodb_buffer_pool_size)
INNODB_BP_INSTANCES=$(kv_get "$VARS_TSV" innodb_buffer_pool_instances)
INNODB_BP_READ_REQ=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_read_requests)
INNODB_BP_READS=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_reads)

INNODB_FLUSH_LOG_AT_TRX=$(kv_get "$VARS_TSV" innodb_flush_log_at_trx_commit)
INNODB_LOG_BUFFER_SIZE=$(kv_get "$VARS_TSV" innodb_log_buffer_size)
INNODB_LOG_FILE_SIZE=$(kv_get "$VARS_TSV" innodb_log_file_size)
INNODB_REDO_LOG_CAPACITY=$(kv_get "$VARS_TSV" innodb_redo_log_capacity)
INNODB_FILE_PER_TABLE=$(kv_get "$VARS_TSV" innodb_file_per_table)
INNODB_FLUSH_METHOD=$(kv_get "$VARS_TSV" innodb_flush_method)

INNODB_LOG_WAITS=$(kv_get "$STATUS_TSV" Innodb_log_waits)
INNODB_LOG_WRITE_REQ=$(kv_get "$STATUS_TSV" Innodb_log_write_requests)
INNODB_OS_LOG_FSYNCS=$(kv_get "$STATUS_TSV" Innodb_os_log_fsyncs)
INNODB_OS_LOG_WRITTEN=$(kv_get "$STATUS_TSV" Innodb_os_log_written)

INNODB_BP_PAGES_TOTAL=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_pages_total)
INNODB_BP_PAGES_FREE=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_pages_free)
INNODB_BP_PAGES_DIRTY=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_pages_dirty)
INNODB_BP_BYTES_DATA=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_bytes_data)
INNODB_BP_BYTES_FREE=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_bytes_free)

THREAD_CACHE_SIZE=$(kv_get "$VARS_TSV" thread_cache_size)
TABLE_OPEN_CACHE=$(kv_get "$VARS_TSV" table_open_cache)
OPENED_TABLES=$(kv_get "$STATUS_TSV" Opened_tables)
OPENED_TABLE_DEFS=$(kv_get "$STATUS_TSV" Opened_table_definitions)

MAX_ALLOWED_PACKET=$(kv_get "$VARS_TSV" max_allowed_packet)

# Files / limits
OPEN_FILES_LIMIT=$(kv_get "$VARS_TSV" open_files_limit)
OPEN_FILES=$(kv_get "$STATUS_TSV" Open_files)
TABLE_DEF_CACHE=$(kv_get "$VARS_TSV" table_definition_cache)

# MyISAM / key buffer metrics
KEY_READ_REQUESTS=$(kv_get "$STATUS_TSV" Key_read_requests)
KEY_READS=$(kv_get "$STATUS_TSV" Key_reads)
KEY_WRITE_REQUESTS=$(kv_get "$STATUS_TSV" Key_write_requests)
KEY_WRITES=$(kv_get "$STATUS_TSV" Key_writes)

# Memory-related vars (for rough estimates)
KEY_BUFFER_SIZE=$(kv_get "$VARS_TSV" key_buffer_size)
READ_BUFFER_SIZE=$(kv_get "$VARS_TSV" read_buffer_size)
READ_RND_BUFFER_SIZE=$(kv_get "$VARS_TSV" read_rnd_buffer_size)
SORT_BUFFER_SIZE=$(kv_get "$VARS_TSV" sort_buffer_size)
JOIN_BUFFER_SIZE=$(kv_get "$VARS_TSV" join_buffer_size)
THREAD_STACK=$(kv_get "$VARS_TSV" thread_stack)

SORT_MERGE_PASSES=$(kv_get "$STATUS_TSV" Sort_merge_passes)
SORT_RANGE=$(kv_get "$STATUS_TSV" Sort_range)
SORT_ROWS=$(kv_get "$STATUS_TSV" Sort_rows)
SORT_SCAN=$(kv_get "$STATUS_TSV" Sort_scan)

SELECT_FULL_JOIN=$(kv_get "$STATUS_TSV" Select_full_join)
SELECT_FULL_RANGE_JOIN=$(kv_get "$STATUS_TSV" Select_full_range_join)
SELECT_RANGE_CHECK=$(kv_get "$STATUS_TSV" Select_range_check)

HANDLER_READ_RND_NEXT=$(kv_get "$STATUS_TSV" Handler_read_rnd_next)
HANDLER_READ_RND=$(kv_get "$STATUS_TSV" Handler_read_rnd)
HANDLER_READ_FIRST=$(kv_get "$STATUS_TSV" Handler_read_first)
HANDLER_READ_KEY=$(kv_get "$STATUS_TSV" Handler_read_key)
HANDLER_READ_NEXT=$(kv_get "$STATUS_TSV" Handler_read_next)
HANDLER_READ_PREV=$(kv_get "$STATUS_TSV" Handler_read_prev)
HANDLER_READ_LAST=$(kv_get "$STATUS_TSV" Handler_read_last)
QCACHE_SIZE=$(kv_get "$VARS_TSV" query_cache_size)
QCACHE_TYPE=$(kv_get "$VARS_TSV" query_cache_type)
QCACHE_LIMIT=$(kv_get "$VARS_TSV" query_cache_limit)
QCACHE_MIN_RES_UNIT=$(kv_get "$VARS_TSV" query_cache_min_res_unit)

QCACHE_HITS=$(kv_get "$STATUS_TSV" Qcache_hits)
QCACHE_INSERTS=$(kv_get "$STATUS_TSV" Qcache_inserts)
QCACHE_NOT_CACHED=$(kv_get "$STATUS_TSV" Qcache_not_cached)
QCACHE_LOWPRUNES=$(kv_get "$STATUS_TSV" Qcache_lowmem_prunes)
QCACHE_FREE_MEM=$(kv_get "$STATUS_TSV" Qcache_free_memory)
QCACHE_FREE_BLOCKS=$(kv_get "$STATUS_TSV" Qcache_free_blocks)
QCACHE_TOTAL_BLOCKS=$(kv_get "$STATUS_TSV" Qcache_total_blocks)

# Network/security exposure
BIND_ADDRESS=$(kv_get "$VARS_TSV" bind_address)
SKIP_NETWORKING=$(kv_get "$VARS_TSV" skip_networking)
PORT_VAR=$(kv_get "$VARS_TSV" port)

# Binary log / durability variables
LOG_BIN=$(kv_get "$VARS_TSV" log_bin)
BINLOG_FORMAT=$(kv_get "$VARS_TSV" binlog_format)
SYNC_BINLOG=$(kv_get "$VARS_TSV" sync_binlog)

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

# Thread cache hit rate (best-effort)
conn=$(num "$CONNECTIONS")
thrcreated=$(num "$THREADS_CREATED")
if [ "$conn" -gt 0 ]; then
  createdpct=$(pct "$thrcreated" "$conn")
  THREAD_CACHE_HIT_PCT=$((100 - createdpct))
  [ "$THREAD_CACHE_HIT_PCT" -lt 0 ] && THREAD_CACHE_HIT_PCT=0
else
  THREAD_CACHE_HIT_PCT=""
fi

# Query cache efficiency (best-effort)
qch=$(num "$QCACHE_HITS")
qci=$(num "$QCACHE_INSERTS")
qct=$((qch + qci))
if [ "$qct" -gt 0 ]; then
  QCACHE_HIT_PCT=$(pct "$qch" "$qct")
else
  QCACHE_HIT_PCT=""
fi

# MyISAM key buffer hit rate (best-effort)
krreq=$(num "$KEY_READ_REQUESTS")
kr=$(num "$KEY_READS")
if [ "$krreq" -gt 0 ]; then
  misspct=$(pct "$kr" "$krreq")
  KEY_BUFFER_HIT_PCT=$((100 - misspct))
  [ "$KEY_BUFFER_HIT_PCT" -lt 0 ] && KEY_BUFFER_HIT_PCT=0
else
  KEY_BUFFER_HIT_PCT=""
fi

# InnoDB buffer pool free/dirty percent (best-effort)
bpt=$(num "$INNODB_BP_PAGES_TOTAL")
bpf=$(num "$INNODB_BP_PAGES_FREE")
bpd=$(num "$INNODB_BP_PAGES_DIRTY")
if [ "$bpt" -gt 0 ]; then
  INNODB_BP_FREE_PCT=$(pct "$bpf" "$bpt")
  INNODB_BP_DIRTY_PCT=$(pct "$bpd" "$bpt")
else
  INNODB_BP_FREE_PCT=""
  INNODB_BP_DIRTY_PCT=""
fi

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
MYSQL_USER_READABLE="$( [ -n "$USER_ROWS" ] && echo yes || echo no )"

# Best-effort CVE scan
CVE_FOUND=0
CVE_LIST_JSON="[]"
check_cves

# Best-effort weak password scan (pre-MySQL8)
WEAK_PASSWORD_HITS=0
WEAK_PASSWORD_USERS_JSON="[]"
check_weak_passwords_pre8

# Best-effort replication scan
check_replication

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
    --arg max_used_connections_pct "${mupct:-}" \
    --arg threads_connected "$THREADS_CONNECTED" \
    --arg threads_running "$THREADS_RUNNING" \
    --arg threads_created "$THREADS_CREATED" \
    --arg thread_cache_size "$THREAD_CACHE_SIZE" \
    --arg thread_cache_hit_pct "$THREAD_CACHE_HIT_PCT" \
    --arg aborted_connects_pct "$ABORT_PCT" \
    --arg opened_tables_per_s "$OPENED_TABLES_PS" \
    --arg open_tables "$OPEN_TABLES" \
    --arg opened_table_definitions "$OPENED_TABLE_DEFS" \
    --arg open_files_limit "$OPEN_FILES_LIMIT" \
    --arg open_files "$OPEN_FILES" \
    --arg table_definition_cache "$TABLE_DEF_CACHE" \
    --arg slow_query_log "$SLOW_QUERY_LOG" \
    --arg slow_queries "$SLOW_QUERIES" \
    --arg innodb_buffer_pool_size "$INNODB_BP_SIZE" \
    --arg innodb_buffer_pool_instances "$INNODB_BP_INSTANCES" \
    --arg innodb_buffer_pool_read_requests "$INNODB_BP_READ_REQ" \
    --arg innodb_buffer_pool_reads "$INNODB_BP_READS" \
    --arg innodb_flush_log_at_trx_commit "$INNODB_FLUSH_LOG_AT_TRX" \
    --arg innodb_log_buffer_size "$INNODB_LOG_BUFFER_SIZE" \
    --arg innodb_log_file_size "$INNODB_LOG_FILE_SIZE" \
    --arg innodb_redo_log_capacity "$INNODB_REDO_LOG_CAPACITY" \
    --arg innodb_file_per_table "$INNODB_FILE_PER_TABLE" \
    --arg innodb_flush_method "$INNODB_FLUSH_METHOD" \
    --arg innodb_log_waits "$INNODB_LOG_WAITS" \
    --arg innodb_log_write_requests "$INNODB_LOG_WRITE_REQ" \
    --arg innodb_os_log_fsyncs "$INNODB_OS_LOG_FSYNCS" \
    --arg innodb_os_log_written "$INNODB_OS_LOG_WRITTEN" \
    --arg innodb_buffer_pool_pages_total "$INNODB_BP_PAGES_TOTAL" \
    --arg innodb_buffer_pool_pages_free "$INNODB_BP_PAGES_FREE" \
    --arg innodb_buffer_pool_pages_dirty "$INNODB_BP_PAGES_DIRTY" \
    --arg innodb_buffer_pool_bytes_data "$INNODB_BP_BYTES_DATA" \
    --arg innodb_buffer_pool_bytes_free "$INNODB_BP_BYTES_FREE" \
    --arg innodb_buffer_pool_free_pct "$INNODB_BP_FREE_PCT" \
    --arg innodb_buffer_pool_dirty_pct "$INNODB_BP_DIRTY_PCT" \
    --arg bind_address "$BIND_ADDRESS" \
    --arg skip_networking "$SKIP_NETWORKING" \
    --arg port "$PORT_VAR" \
    --arg log_bin "$LOG_BIN" \
    --arg binlog_format "$BINLOG_FORMAT" \
    --arg sync_binlog "$SYNC_BINLOG" \
    --arg skip_name_resolve "$SKIP_NAME_RESOLVE" \
    --arg local_infile "$LOCAL_INFILE" \
    --arg require_secure_transport "$REQUIRE_SECURE_TRANSPORT" \
    --arg have_ssl "$HAVE_SSL" \
    --arg performance_schema "$PERFORMANCE_SCHEMA" \
    --arg max_allowed_packet "$MAX_ALLOWED_PACKET" \
    --arg key_buffer_size "$KEY_BUFFER_SIZE" \
    --arg key_read_requests "$KEY_READ_REQUESTS" \
    --arg key_reads "$KEY_READS" \
    --arg key_buffer_hit_pct "$KEY_BUFFER_HIT_PCT" \
    --arg query_cache_size "$QCACHE_SIZE" \
    --arg query_cache_type "$QCACHE_TYPE" \
    --arg query_cache_limit "$QCACHE_LIMIT" \
    --arg query_cache_min_res_unit "$QCACHE_MIN_RES_UNIT" \
    --arg qcache_hits "$QCACHE_HITS" \
    --arg qcache_inserts "$QCACHE_INSERTS" \
    --arg qcache_lowmem_prunes "$QCACHE_LOWPRUNES" \
    --arg qcache_not_cached "$QCACHE_NOT_CACHED" \
    --arg qcache_free_memory "$QCACHE_FREE_MEM" \
    --arg qcache_free_blocks "$QCACHE_FREE_BLOCKS" \
    --arg qcache_total_blocks "$QCACHE_TOTAL_BLOCKS" \
    --arg qcache_hit_pct "$QCACHE_HIT_PCT" \
    --arg select_full_join "$SELECT_FULL_JOIN" \
    --arg select_full_range_join "$SELECT_FULL_RANGE_JOIN" \
    --arg select_range_check "$SELECT_RANGE_CHECK" \
    --arg handler_read_rnd_next "$HANDLER_READ_RND_NEXT" \
    --arg handler_read_rnd "$HANDLER_READ_RND" \
    --arg handler_read_first "$HANDLER_READ_FIRST" \
    --arg handler_read_key "$HANDLER_READ_KEY" \
    --arg handler_read_next "$HANDLER_READ_NEXT" \
    --arg handler_read_prev "$HANDLER_READ_PREV" \
    --arg handler_read_last "$HANDLER_READ_LAST" \
    --arg mysql_user_readable "$MYSQL_USER_READABLE" \
    --arg mysql_user_col4 "$USER_COL4" \
    --arg passwordfile "$PASSWORDFILE" \
    --arg max_password_checks "$MAX_PASSWORD_CHECKS" \
    --arg ram_total_bytes "$RAM_TOTAL" \
    --arg global_buffers_bytes "$GLOBAL_BUFFERS" \
    --arg per_thread_buffers_bytes "$PER_THREAD_BUFFERS" \
    --arg max_memory_estimate_bytes "$MAX_MEM" \
    --arg cve_found "$CVE_FOUND" \
    --argjson cve_list "$CVE_LIST_JSON" \
    --arg weak_password_hits "$WEAK_PASSWORD_HITS" \
    --argjson weak_password_users "$WEAK_PASSWORD_USERS_JSON" \
    --arg repl_role "$REPL_ROLE" \
    --arg repl_io_running "$REPL_IO_RUNNING" \
    --arg repl_sql_running "$REPL_SQL_RUNNING" \
    --arg repl_seconds_behind "$REPL_SECONDS_BEHIND" \
    --arg repl_source_host "$REPL_SOURCE_HOST" \
    --arg repl_source_port "$REPL_SOURCE_PORT" \
    --arg repl_last_io_error "$REPL_LAST_IO_ERROR" \
    --arg repl_last_sql_error "$REPL_LAST_SQL_ERROR" \
    --arg master_log_file "$MASTER_LOG_FILE" \
    --arg master_log_pos "$MASTER_LOG_POS" \
    '{
      version:$version,
      flavor:$flavor,
      version_comment:$version_comment,
      uptime:$uptime,
      qps:$qps,
      max_connections:$max_connections,
      max_used_connections:$max_used_connections,
      max_used_connections_pct:$max_used_connections_pct,
      threads_connected:$threads_connected,
      threads_running:$threads_running,
      threads_created:$threads_created,
      thread_cache_size:$thread_cache_size,
      thread_cache_hit_pct:$thread_cache_hit_pct,
      aborted_connects_pct:$aborted_connects_pct,
      opened_tables_per_s:$opened_tables_per_s,
      open_tables:$open_tables,
      opened_table_definitions:$opened_table_definitions,
      open_files_limit:$open_files_limit,
      open_files:$open_files,
      table_definition_cache:$table_definition_cache,
      slow_query_log:$slow_query_log,
      slow_queries:$slow_queries,
      innodb_buffer_pool_size:$innodb_buffer_pool_size,
      innodb_buffer_pool_instances:$innodb_buffer_pool_instances,
      innodb_buffer_pool_read_requests:$innodb_buffer_pool_read_requests,
      innodb_buffer_pool_reads:$innodb_buffer_pool_reads,
      innodb_flush_log_at_trx_commit:$innodb_flush_log_at_trx_commit,
      innodb_log_buffer_size:$innodb_log_buffer_size,
      innodb_log_file_size:$innodb_log_file_size,
      innodb_redo_log_capacity:$innodb_redo_log_capacity,
      innodb_file_per_table:$innodb_file_per_table,
      innodb_flush_method:$innodb_flush_method,
      innodb_log_waits:$innodb_log_waits,
      innodb_log_write_requests:$innodb_log_write_requests,
      innodb_os_log_fsyncs:$innodb_os_log_fsyncs,
      innodb_os_log_written:$innodb_os_log_written,
      innodb_buffer_pool_pages_total:$innodb_buffer_pool_pages_total,
      innodb_buffer_pool_pages_free:$innodb_buffer_pool_pages_free,
      innodb_buffer_pool_pages_dirty:$innodb_buffer_pool_pages_dirty,
      innodb_buffer_pool_bytes_data:$innodb_buffer_pool_bytes_data,
      innodb_buffer_pool_bytes_free:$innodb_buffer_pool_bytes_free,
      innodb_buffer_pool_free_pct:$innodb_buffer_pool_free_pct,
      innodb_buffer_pool_dirty_pct:$innodb_buffer_pool_dirty_pct,
      bind_address:$bind_address,
      skip_networking:$skip_networking,
      port:$port,
      log_bin:$log_bin,
      binlog_format:$binlog_format,
      sync_binlog:$sync_binlog,
      skip_name_resolve:$skip_name_resolve,
      local_infile:$local_infile,
      require_secure_transport:$require_secure_transport,
      have_ssl:$have_ssl,
      performance_schema:$performance_schema,
      max_allowed_packet:$max_allowed_packet,
      key_buffer_size:$key_buffer_size,
      key_read_requests:$key_read_requests,
      key_reads:$key_reads,
      key_buffer_hit_pct:$key_buffer_hit_pct,
      query_cache_size:$query_cache_size,
      query_cache_type:$query_cache_type,
      query_cache_limit:$query_cache_limit,
      query_cache_min_res_unit:$query_cache_min_res_unit,
      qcache_hits:$qcache_hits,
      qcache_inserts:$qcache_inserts,
      qcache_lowmem_prunes:$qcache_lowmem_prunes,
      qcache_not_cached:$qcache_not_cached,
      qcache_free_memory:$qcache_free_memory,
      qcache_free_blocks:$qcache_free_blocks,
      qcache_total_blocks:$qcache_total_blocks,
      qcache_hit_pct:$qcache_hit_pct,
      select_full_join:$select_full_join,
      select_full_range_join:$select_full_range_join,
      select_range_check:$select_range_check,
      handler_read_rnd_next:$handler_read_rnd_next,
      handler_read_rnd:$handler_read_rnd,
      handler_read_first:$handler_read_first,
      handler_read_key:$handler_read_key,
      handler_read_next:$handler_read_next,
      handler_read_prev:$handler_read_prev,
      handler_read_last:$handler_read_last,
      mysql_user_readable:$mysql_user_readable,
      mysql_user_col4:$mysql_user_col4,
      passwordfile:$passwordfile,
      max_password_checks:$max_password_checks,
      ram_total_bytes:$ram_total_bytes,
      global_buffers_bytes:$global_buffers_bytes,
      per_thread_buffers_bytes:$per_thread_buffers_bytes,
      max_memory_estimate_bytes:$max_memory_estimate_bytes,
      cve_found:$cve_found,
      cve_list:$cve_list,
      weak_password_hits:$weak_password_hits,
      weak_password_users:$weak_password_users,
      replication:{
        role:$repl_role,
        io_running:$repl_io_running,
        sql_running:$repl_sql_running,
        seconds_behind:$repl_seconds_behind,
        source_host:$repl_source_host,
        source_port:$repl_source_port,
        last_io_error:$repl_last_io_error,
        last_sql_error:$repl_last_sql_error,
        master_log_file:$master_log_file,
        master_log_pos:$master_log_pos
      }
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

section "Replication"
info "role: $REPL_ROLE"
if [ "$REPL_ROLE" = "replica" ] || [ "$REPL_ROLE" = "master+replica" ]; then
  [ -n "$REPL_SOURCE_HOST" ] && info "source_host: $REPL_SOURCE_HOST"
  [ -n "$REPL_SOURCE_PORT" ] && info "source_port: $REPL_SOURCE_PORT"
  [ -n "$REPL_IO_RUNNING" ] && info "io_running: $REPL_IO_RUNNING"
  [ -n "$REPL_SQL_RUNNING" ] && info "sql_running: $REPL_SQL_RUNNING"
  [ -n "$REPL_SECONDS_BEHIND" ] && info "seconds_behind: $REPL_SECONDS_BEHIND"

  [ "$REPL_IO_RUNNING" = "No" ] && warn "Replica IO thread not running" || true
  [ "$REPL_SQL_RUNNING" = "No" ] && warn "Replica SQL thread not running" || true
  if [ -n "$REPL_LAST_IO_ERROR" ]; then
    warn "Last_IO_Error: $REPL_LAST_IO_ERROR"
  fi
  if [ -n "$REPL_LAST_SQL_ERROR" ]; then
    warn "Last_SQL_Error: $REPL_LAST_SQL_ERROR"
  fi
fi
if [ "$REPL_ROLE" = "master" ] || [ "$REPL_ROLE" = "master+replica" ]; then
  [ -n "$MASTER_LOG_FILE" ] && info "master_log_file: $MASTER_LOG_FILE"
  [ -n "$MASTER_LOG_POS" ] && info "master_log_pos:  $MASTER_LOG_POS"
fi

section "CVE Security Recommendations"
if [ -z "$CVEFILE" ]; then
  info "Skipped: no --cvefile and ./vulnerabilities.csv not found"
elif [ ! -f "$CVEFILE" ]; then
  info "Skipped: CVE file not found ($CVEFILE)"
elif [ "$CVE_FOUND" -eq 0 ]; then
  ok "NO SECURITY CVE FOUND FOR YOUR VERSION"
else
  warn "$CVE_FOUND CVE(s) found for your MySQL release. Consider upgrading."
fi

section "Weak Passwords (dictionary, best-effort)"
if [ -z "$PASSWORDFILE" ]; then
  info "Skipped: no password file found (use --passwordfile)"
elif [ ! -f "$PASSWORDFILE" ]; then
  info "Skipped: password file not found ($PASSWORDFILE)"
elif [ "${MYSQL_USER_READABLE}" != "yes" ]; then
  info "Skipped: mysql.user not readable with current credentials"
elif [ "$MYSQL_VER_MAJ" -ge 8 ]; then
  info "Skipped: MySQL 8+ (PASSWORD() removed; implement different method later)"
else
  info "Password list: $PASSWORDFILE (max checks: $MAX_PASSWORD_CHECKS)"
  if [ "$WEAK_PASSWORD_HITS" -eq 0 ]; then
    ok "No weak passwords detected (best-effort)"
  else
    warn "Weak password hits: $WEAK_PASSWORD_HITS (see warnings above)"
  fi
fi

section "Throughput"
info "Questions: $QUESTIONS (QPS: $QPS)"

section "Connections"
info "max_connections:      $MAX_CONNECTIONS"
info "Max_used_connections: $MAX_USED_CONNECTIONS"

mc=$(num "$MAX_CONNECTIONS")
mu=$(num "$MAX_USED_CONNECTIONS")
if [ "$mc" -gt 0 ] && [ "$mu" -gt 0 ]; then
  mupct=$(pct "$mu" "$mc")
  info "Max_used_connections % of max: ${mupct}%"
  [ "$mupct" -ge 85 ] && warn "Max_used_connections is high (${mupct}% of max_connections)" || true
fi
info "Threads_connected:    $THREADS_CONNECTED"
info "Threads_running:      $THREADS_RUNNING"
info "Threads_created:      $THREADS_CREATED"
info "thread_cache_size:    $THREAD_CACHE_SIZE"
if [ -n "${THREAD_CACHE_HIT_PCT:-}" ]; then
  info "Thread cache hit rate: ${THREAD_CACHE_HIT_PCT}%"
  [ "$(num "$THREAD_CACHE_SIZE")" -gt 0 ] && [ "$THREAD_CACHE_HIT_PCT" -lt 90 ] && warn "Low thread cache hit rate (${THREAD_CACHE_HIT_PCT}%)" || true
fi
info "Aborted_connects:     $ABORTED_CONNECTS (${ABORT_PCT}%)"
[ "$(num "$ABORTED_CONNECTS")" -gt 0 ] && [ "$ABORT_PCT" -ge 5 ] && warn "High aborted connect rate (${ABORT_PCT}%)"

section "Memory"
info "key_buffer_size:         $(bytes_h "$KEY_BUFFER_SIZE")"
info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"
info "query_cache_size:        $(bytes_h "$QCACHE_SIZE")"
info "Global buffers:          $(bytes_h "$GLOBAL_BUFFERS")"
info "Per-thread buffers:      $(bytes_h "$PER_THREAD_BUFFERS")"
info "  read_buffer_size:      $(bytes_h "$READ_BUFFER_SIZE")"
info "  read_rnd_buffer_size:  $(bytes_h "$READ_RND_BUFFER_SIZE")"
info "  sort_buffer_size:      $(bytes_h "$SORT_BUFFER_SIZE")"
info "  join_buffer_size:      $(bytes_h "$JOIN_BUFFER_SIZE")"
info "  thread_stack:          $(bytes_h "$THREAD_STACK")"
info "Max memory estimate:     $(bytes_h "$MAX_MEM") (global + per-thread*max_connections)"
if [ "$(num "$RAM_TOTAL")" -gt 0 ]; then
  info "System RAM (best-effort): $(bytes_h "$RAM_TOTAL")"
  mempct=$(pct "$MAX_MEM" "$RAM_TOTAL")
  [ "$mempct" -ge 85 ] && warn "Max memory estimate high (${mempct}% of RAM)" || ok "Max memory estimate: ${mempct}% of RAM"
else
  info "System RAM unknown; skipping RAM comparison"
fi

section "Query Cache"
info "query_cache_type:         $QCACHE_TYPE"
info "query_cache_size:         $(bytes_h "$QCACHE_SIZE")"
info "query_cache_limit:        $(bytes_h "$QCACHE_LIMIT")"
info "query_cache_min_res_unit: $(bytes_h "$QCACHE_MIN_RES_UNIT")"
info "Qcache_hits:              $QCACHE_HITS"
info "Qcache_inserts:           $QCACHE_INSERTS"
info "Qcache_not_cached:        $QCACHE_NOT_CACHED"
info "Qcache_lowmem_prunes:     $QCACHE_LOWPRUNES"
info "Qcache_free_memory:       $(bytes_h "$QCACHE_FREE_MEM")"

if [ "$(num "$QCACHE_SIZE")" -gt 0 ]; then
  if [ "$MYSQL_VER_MAJ" -ge 8 ]; then
    warn "query_cache_size > 0 on MySQL 8+ (query cache removed upstream; check compatibility)"
  fi
  if [ -n "${QCACHE_HIT_PCT:-}" ]; then
    info "Query cache hit rate:     ${QCACHE_HIT_PCT}%"
    [ "$QCACHE_HIT_PCT" -lt 20 ] && warn "Low query cache hit rate (${QCACHE_HIT_PCT}%)" || true
  fi
  [ "$(num "$QCACHE_LOWPRUNES")" -gt 0 ] && warn "Query cache prunes detected ($QCACHE_LOWPRUNES)" || true
else
  ok "Query cache disabled"
fi

section "Sorts"
info "Sort_merge_passes: $SORT_MERGE_PASSES"
info "Sort_scan:         $SORT_SCAN"
info "Sort_range:        $SORT_RANGE"
info "Sort_rows:         $SORT_ROWS"
[ "$(num "$SORT_MERGE_PASSES")" -gt 0 ] && warn "Sort_merge_passes > 0 (consider increasing sort_buffer_size or optimizing sorts)" || true

section "Joins"
info "Select_full_join:       $SELECT_FULL_JOIN"
info "Select_full_range_join: $SELECT_FULL_RANGE_JOIN"
info "Select_range_check:     $SELECT_RANGE_CHECK"
[ "$(num "$SELECT_FULL_JOIN")" -gt 0 ] && warn "Select_full_join > 0 (joins without indexes detected)" || true
[ "$(num "$SELECT_RANGE_CHECK")" -gt 0 ] && warn "Select_range_check > 0 (joins without keys in some cases)" || true

section "Handler (read patterns)"
info "Handler_read_rnd_next: $HANDLER_READ_RND_NEXT"
info "Handler_read_rnd:      $HANDLER_READ_RND"
info "Handler_read_key:      $HANDLER_READ_KEY"
info "Handler_read_next:     $HANDLER_READ_NEXT"
# Heuristic: high rnd_next often indicates full table scans
[ "$(num "$HANDLER_READ_RND_NEXT")" -gt 0 ] && warn "Handler_read_rnd_next > 0 (possible full table scans)" || true

section "Slow Query Log"
[ -n "$SLOW_QUERY_LOG" ] && info "slow_query_log: $SLOW_QUERY_LOG"
[ -n "$LONG_QUERY_TIME" ] && info "long_query_time: $LONG_QUERY_TIME"
[ "$(num "$SLOW_QUERIES")" -gt 0 ] && warn "Slow_queries: $SLOW_QUERIES" || ok "Slow_queries: $SLOW_QUERIES"

section "Temporary Tables"
info "Created_tmp_tables:      $CREATED_TMP_TABLES"
info "Created_tmp_disk_tables: $CREATED_TMP_DISK_TABLES"
info "tmp_table_size:          $(bytes_h "$TMP_TABLE_SIZE")"
info "max_heap_table_size:     $(bytes_h "$MAX_HEAP_TABLE_SIZE")"

efftmp=$TMP_TABLE_SIZE
if [ "$(num "$MAX_HEAP_TABLE_SIZE")" -gt 0 ] && [ "$(num "$TMP_TABLE_SIZE")" -gt 0 ]; then
  if [ "$(num "$MAX_HEAP_TABLE_SIZE")" -lt "$(num "$TMP_TABLE_SIZE")" ]; then
    efftmp=$MAX_HEAP_TABLE_SIZE
  fi
  info "effective_tmp_table_size: $(bytes_h "$efftmp") (min of tmp_table_size/max_heap_table_size)"
fi

tmp=$(num "$CREATED_TMP_TABLES")
tmpdisk=$(num "$CREATED_TMP_DISK_TABLES")
if [ "$tmp" -gt 0 ] && [ "$tmpdisk" -gt 0 ]; then
  p=$(pct "$tmpdisk" "$tmp")
  [ "$p" -ge 25 ] && warn "High tmp tables on disk: ${p}%" || ok "Tmp tables on disk: ${p}%"
fi

section "InnoDB"
[ -n "$INNODB_BP_SIZE" ] && info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"
[ -n "$INNODB_BP_INSTANCES" ] && info "innodb_buffer_pool_instances: $INNODB_BP_INSTANCES"
[ -n "$INNODB_FILE_PER_TABLE" ] && info "innodb_file_per_table: $INNODB_FILE_PER_TABLE"
[ -n "$INNODB_FLUSH_METHOD" ] && info "innodb_flush_method: $INNODB_FLUSH_METHOD"
[ -n "$INNODB_FLUSH_LOG_AT_TRX" ] && info "innodb_flush_log_at_trx_commit: $INNODB_FLUSH_LOG_AT_TRX"
[ -n "$INNODB_LOG_BUFFER_SIZE" ] && info "innodb_log_buffer_size: $(bytes_h "$INNODB_LOG_BUFFER_SIZE")"

if [ "$(num "$INNODB_REDO_LOG_CAPACITY")" -gt 0 ]; then
  info "innodb_redo_log_capacity: $(bytes_h "$INNODB_REDO_LOG_CAPACITY")"
elif [ "$(num "$INNODB_LOG_FILE_SIZE")" -gt 0 ]; then
  info "innodb_log_file_size: $(bytes_h "$INNODB_LOG_FILE_SIZE")"
fi

[ -n "$INNODB_LOG_WRITE_REQ" ] && info "Innodb_log_write_requests: $INNODB_LOG_WRITE_REQ"
[ -n "$INNODB_LOG_WAITS" ] && info "Innodb_log_waits:          $INNODB_LOG_WAITS"
[ "$(num "$INNODB_LOG_WAITS")" -gt 0 ] && warn "InnoDB log waits detected ($INNODB_LOG_WAITS) - consider larger innodb_log_buffer_size or faster disk" || true

# buffer pool occupancy
if [ "$(num "$INNODB_BP_PAGES_TOTAL")" -gt 0 ]; then
  info "Innodb_buffer_pool_pages_total: $INNODB_BP_PAGES_TOTAL"
  info "Innodb_buffer_pool_pages_free:  $INNODB_BP_PAGES_FREE (${INNODB_BP_FREE_PCT}% free)"
  if [ "$(num "$INNODB_BP_PAGES_DIRTY")" -gt 0 ]; then
    info "Innodb_buffer_pool_pages_dirty: $INNODB_BP_PAGES_DIRTY (${INNODB_BP_DIRTY_PCT}% dirty)"
    [ "$(num "$INNODB_BP_DIRTY_PCT")" -ge 50 ] && warn "High dirty pages in buffer pool (${INNODB_BP_DIRTY_PCT}%)" || true
  fi
  [ "$(num "$INNODB_BP_FREE_PCT")" -lt 3 ] && warn "InnoDB buffer pool has <3% free pages (${INNODB_BP_FREE_PCT}%)" || true
fi
if [ "$(num "$INNODB_BP_BYTES_DATA")" -gt 0 ] || [ "$(num "$INNODB_BP_BYTES_FREE")" -gt 0 ]; then
  info "Innodb_buffer_pool_bytes_data:  $(bytes_h "$INNODB_BP_BYTES_DATA")"
  info "Innodb_buffer_pool_bytes_free:  $(bytes_h "$INNODB_BP_BYTES_FREE")"
fi

if [ "${INNODB_FLUSH_LOG_AT_TRX:-}" = "2" ] || [ "${INNODB_FLUSH_LOG_AT_TRX:-}" = "0" ]; then
  warn "innodb_flush_log_at_trx_commit=$INNODB_FLUSH_LOG_AT_TRX reduces durability"
fi

bprr=$(num "$INNODB_BP_READ_REQ")
bpr=$(num "$INNODB_BP_READS")
if [ "$bprr" -gt 0 ]; then
  hit=$((bprr - bpr)); [ "$hit" -lt 0 ] && hit=0
  hp=$(pct "$hit" "$bprr")
  info "InnoDB BP hit rate: ${hp}%"
  [ "$hp" -lt 95 ] && warn "Low InnoDB buffer pool hit rate (${hp}%)" || ok "InnoDB buffer pool hit rate (${hp}%)"
fi

section "MyISAM / Key Buffer"
info "key_buffer_size:      $(bytes_h "$KEY_BUFFER_SIZE")"
info "Key_read_requests:    $KEY_READ_REQUESTS"
info "Key_reads:            $KEY_READS"
if [ -n "${KEY_BUFFER_HIT_PCT:-}" ]; then
  info "Key buffer hit rate:  ${KEY_BUFFER_HIT_PCT}%"
  [ "$KEY_BUFFER_HIT_PCT" -lt 95 ] && warn "Low key buffer hit rate (${KEY_BUFFER_HIT_PCT}%)" || ok "Key buffer hit rate looks OK (${KEY_BUFFER_HIT_PCT}%)"
else
  info "Key buffer hit rate:  n/a"
fi

section "Table Open Cache"
info "table_open_cache:        $TABLE_OPEN_CACHE"
info "Open_tables:             $OPEN_TABLES"
info "Opened_tables:           $OPENED_TABLES (~${OPENED_TABLES_PS}/s)"
[ -n "$TABLE_DEF_CACHE" ] && info "table_definition_cache:   $TABLE_DEF_CACHE"
[ -n "$OPENED_TABLE_DEFS" ] && info "Opened_table_definitions: $OPENED_TABLE_DEFS"
# crude heuristic: if we open lots of tables per second, cache might be too small
ots=$(printf "%s" "$OPENED_TABLES_PS" | awk -F. '{print $1}')
ots=$(num "$ots")
[ "$ots" -ge 1 ] && warn "High Opened_tables rate (~${OPENED_TABLES_PS}/s); consider increasing table_open_cache" || true

section "Files"
[ -n "$OPEN_FILES_LIMIT" ] && info "open_files_limit: $OPEN_FILES_LIMIT"
[ -n "$OPEN_FILES" ] && info "Open_files:       $OPEN_FILES"

ofl=$(num "$OPEN_FILES_LIMIT")
of=$(num "$OPEN_FILES")
if [ "$ofl" -gt 0 ] && [ "$of" -gt 0 ]; then
  ofpct=$(pct "$of" "$ofl")
  info "Open_files % of limit: ${ofpct}%"
  [ "$ofpct" -ge 85 ] && warn "Open_files is high (${ofpct}% of open_files_limit)" || true
fi

section "Packet Size"
info "max_allowed_packet: $(bytes_h "$MAX_ALLOWED_PACKET")"
[ "$(num "$MAX_ALLOWED_PACKET")" -lt 16777216 ] && warn "max_allowed_packet below 16MiB" || ok "max_allowed_packet looks OK"

section "Binary Log"
[ -n "$LOG_BIN" ] && info "log_bin: $LOG_BIN"
[ -n "$BINLOG_FORMAT" ] && info "binlog_format: $BINLOG_FORMAT"
[ -n "$SYNC_BINLOG" ] && info "sync_binlog: $SYNC_BINLOG"

if [ "${LOG_BIN:-}" = "ON" ] && [ "${SYNC_BINLOG:-}" != "" ]; then
  sb=$(num "$SYNC_BINLOG")
  [ "$sb" -eq 0 ] && warn "sync_binlog=0 with binary logging reduces durability" || true
fi

section "Network"
[ -n "$PORT_VAR" ] && info "port: $PORT_VAR"
[ -n "$BIND_ADDRESS" ] && info "bind_address: $BIND_ADDRESS"
[ -n "$SKIP_NETWORKING" ] && info "skip_networking: $SKIP_NETWORKING"

if [ "$SKIP_NETWORKING" = "ON" ]; then
  ok "skip_networking is ON (TCP disabled)"
else
  if [ "$BIND_ADDRESS" = "0.0.0.0" ] || [ "$BIND_ADDRESS" = "::" ]; then
    warn "bind_address is $BIND_ADDRESS (listens on all interfaces)"
  fi
fi

section "Security (basic)"
[ -n "$SKIP_NAME_RESOLVE" ] && info "skip_name_resolve: $SKIP_NAME_RESOLVE"
[ -n "$LOCAL_INFILE" ] && info "local_infile: $LOCAL_INFILE"
[ -n "$HAVE_SSL" ] && info "have_ssl: $HAVE_SSL"
[ -n "$REQUIRE_SECURE_TRANSPORT" ] && info "require_secure_transport: $REQUIRE_SECURE_TRANSPORT"
[ -n "$PERFORMANCE_SCHEMA" ] && info "performance_schema: $PERFORMANCE_SCHEMA"

[ "$LOCAL_INFILE" = "ON" ] && warn "local_infile is ON (consider OFF unless required)" || true
[ "$REQUIRE_SECURE_TRANSPORT" = "OFF" ] && warn "require_secure_transport is OFF (consider ON if you require TLS)" || true

ok "Collected: SHOW GLOBAL VARIABLES/STATUS"
warn "Next: implement more MySQLTuner-perl checks for feature parity."

exit 0
