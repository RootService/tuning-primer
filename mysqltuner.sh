#!/bin/sh
# mysqltuner.sh - POSIX shell port (derived from MySQLTuner-perl)
# License: GPLv3 (see LICENSE.GPLv3)

set -u

VERSION="3.58.0-devel"

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
  --dump-dir <dir>          (write CSV dumps like upstream into this directory)
  --schema-dir <dir>        (write markdown + mermaid ER docs into this directory)

Report modes:
  --tbstat                 (table metrics / per-table index listing; noisy)

Misc:
  --ignore-dbs <db1,db2>    (comma-separated)
  --ignore-tables <t1,t2>   (comma-separated; matches table_name only)
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
HOST=""; PORT=""; SOCKET=""; USER=""; PASS=""; DEFAULTS_FILE=""; SILENT=0; JSON=0; DUMP_DIR=""; SCHEMA_DIR=""; REC_WARN=""; REC_OK=""; IGNORE_DBS=""; IGNORE_TABLES=""; TBSTAT=0
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
    --ignore-dbs) shift; IGNORE_DBS="${1-}" ;;
    --ignore-tables) shift; IGNORE_TABLES="${1-}" ;;
    --silent) SILENT=1 ;;
    --json) JSON=1 ;;
    --dump-dir) shift; DUMP_DIR="${1-}" ;;
    --schema-dir) shift; SCHEMA_DIR="${1-}" ;;
    --tbstat) TBSTAT=1 ;;
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
need_cmd getconf
need_cmd uname

# ---- MySQL command builder -------------------------------------------------
MYSQL_CMD="mysql"
MYSQL_ARGS="--batch --raw --skip-column-names"

# NOTE: mysql requires --defaults-file to be the FIRST option.
[ -n "$DEFAULTS_FILE" ] && MYSQL_ARGS="--defaults-file=$DEFAULTS_FILE $MYSQL_ARGS"
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

sql_in_list() {
  # sql_in_list "a,b,c" -> 'a','b','c'
  # No SQL escaping: for controlled CLI values only.
  s="$1"
  oldIFS=$IFS
  IFS=,
  out=""
  for item in $s; do
    item=$(printf '%s' "$item" | awk '{$1=$1;print}')
    [ -z "$item" ] && continue
    out="${out}${out:+,}'$item'"
  done
  IFS=$oldIFS
  printf '%s' "$out"
}

ignore_sql_dbs() {
  [ -z "$IGNORE_DBS" ] && return 0
  lst=$(sql_in_list "$IGNORE_DBS")
  [ -z "$lst" ] && return 0
  printf '%s' " AND TABLE_SCHEMA NOT IN ($lst)"
}

ignore_sql_tables() {
  [ -z "$IGNORE_TABLES" ] && return 0
  lst=$(sql_in_list "$IGNORE_TABLES")
  [ -z "$lst" ] && return 0
  printf '%s' " AND TABLE_NAME NOT IN ($lst)"
}

# With column names (first row is header)
mysql_query_table() {
  # shellcheck disable=SC2086
  echo "$1" | $MYSQL_CMD ${MYSQL_ARGS% --skip-column-names} 2>/dev/null
}

# ---- KV helpers ------------------------------------------------------------

dump_csv_file() {
  # dump_csv_file <path> <header> <jq_filter>
  # jq_filter will be applied to JSON read from stdin; must output CSV lines (no header)
  path="$1"; header="$2"; filter="$3"
  dir=$(dirname "$path")
  [ -n "$dir" ] && [ "$dir" != "." ] && mkdir -p "$dir" 2>/dev/null || true
  {
    printf '%s\n' "$header"
    jq -r "$filter"
  } >"$path"
}

write_text_file() {
  # write_text_file <path>
  path="$1"
  dir=$(dirname "$path")
  [ -n "$dir" ] && [ "$dir" != "." ] && mkdir -p "$dir" 2>/dev/null || true
  cat >"$path"
}
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

per_day() {
  # value per day given total and uptime seconds
  v=$(num "$1"); u=$(num "$2")
  [ "$u" -le 0 ] && { echo 0; return; }
  awk -v v="$v" -v u="$u" 'BEGIN{printf "%d", v/(u/86400)}'
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
warn() {
  [ "$SILENT" -eq 1 ] && return 0
  echo "[WARN] $*"
  if [ -n "${REC_WARN:-}" ]; then
    REC_WARN=$(printf '%s\n%s' "$REC_WARN" "$*")
  else
    REC_WARN=$*
  fi
}

ok() {
  [ "$SILENT" -eq 1 ] && return 0
  echo "[OK]   $*"
  if [ -n "${REC_OK:-}" ]; then
    REC_OK=$(printf '%s\n%s' "$REC_OK" "$*")
  else
    REC_OK=$*
  fi
}

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

# ---- Performance schema memory (best-effort) -------------------------------
pfs_memory_bytes() {
  # Best-effort: sum all performance_schema.*.memory counters.
  # Note: some MySQL builds may not expose a single "performance_schema\tmemory" row.
  [ "${PERFORMANCE_SCHEMA:-OFF}" != "ON" ] && { echo 0; return; }
  mysql_query_silent "SHOW ENGINE PERFORMANCE_SCHEMA STATUS;" |
    awk -F"\t" '($1=="performance_schema" && $2 ~ /memory$/){sum+=$3} END{printf "%d", sum+0}'
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
BYTES_RECEIVED=$(kv_get "$STATUS_TSV" Bytes_received)
BYTES_SENT=$(kv_get "$STATUS_TSV" Bytes_sent)
ABORTED_CONNECTS=$(kv_get "$STATUS_TSV" Aborted_connects)
ABORTED_CLIENTS=$(kv_get "$STATUS_TSV" Aborted_clients)

CONN_ERRORS_ACCEPT=$(kv_get "$STATUS_TSV" Connection_errors_accept)
CONN_ERRORS_INTERNAL=$(kv_get "$STATUS_TSV" Connection_errors_internal)
CONN_ERRORS_MAXCONN=$(kv_get "$STATUS_TSV" Connection_errors_max_connections)
CONN_ERRORS_PEERADDR=$(kv_get "$STATUS_TSV" Connection_errors_peer_address)
CONN_ERRORS_SELECT=$(kv_get "$STATUS_TSV" Connection_errors_select)
CONN_ERRORS_TCPWRAP=$(kv_get "$STATUS_TSV" Connection_errors_tcpwrap)

BINLOG_CACHE_USE=$(kv_get "$STATUS_TSV" Binlog_cache_use)
BINLOG_CACHE_DISK_USE=$(kv_get "$STATUS_TSV" Binlog_cache_disk_use)

OPEN_TABLES=$(kv_get "$STATUS_TSV" Open_tables)

SLOW_QUERY_LOG=$(kv_get "$VARS_TSV" slow_query_log)
LONG_QUERY_TIME=$(kv_get "$VARS_TSV" long_query_time)
SLOW_QUERIES=$(kv_get "$STATUS_TSV" Slow_queries)

QUESTIONS=$(kv_get "$STATUS_TSV" Questions)

# Slow queries percent / per-day (best-effort)
SLOW_QUERIES_PCT=$(pct "$SLOW_QUERIES" "$QUESTIONS")
SLOW_QUERIES_PER_DAY=$(per_day "$SLOW_QUERIES" "$UPTIME_S")

COM_SELECT=$(kv_get "$STATUS_TSV" Com_select)
COM_INSERT=$(kv_get "$STATUS_TSV" Com_insert)
COM_UPDATE=$(kv_get "$STATUS_TSV" Com_update)
COM_DELETE=$(kv_get "$STATUS_TSV" Com_delete)
COM_REPLACE=$(kv_get "$STATUS_TSV" Com_replace)

CREATED_TMP_TABLES=$(kv_get "$STATUS_TSV" Created_tmp_tables)
CREATED_TMP_DISK_TABLES=$(kv_get "$STATUS_TSV" Created_tmp_disk_tables)
TMP_TABLE_SIZE=$(kv_get "$VARS_TSV" tmp_table_size)
MAX_HEAP_TABLE_SIZE=$(kv_get "$VARS_TSV" max_heap_table_size)

# Effective tmp table size (global)
MAX_TMP_TABLE_SIZE=$TMP_TABLE_SIZE
if [ "$(num "$MAX_HEAP_TABLE_SIZE")" -gt 0 ] && [ "$(num "$TMP_TABLE_SIZE")" -gt 0 ]; then
  if [ "$(num "$MAX_HEAP_TABLE_SIZE")" -lt "$(num "$TMP_TABLE_SIZE")" ]; then
    MAX_TMP_TABLE_SIZE=$MAX_HEAP_TABLE_SIZE
  fi
fi

INNODB_BP_SIZE=$(kv_get "$VARS_TSV" innodb_buffer_pool_size)
INNODB_BP_INSTANCES=$(kv_get "$VARS_TSV" innodb_buffer_pool_instances)
INNODB_BP_CHUNK_SIZE=$(kv_get "$VARS_TSV" innodb_buffer_pool_chunk_size)
INNODB_BP_READ_REQ=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_read_requests)
INNODB_BP_READS=$(kv_get "$STATUS_TSV" Innodb_buffer_pool_reads)

INNODB_FLUSH_LOG_AT_TRX=$(kv_get "$VARS_TSV" innodb_flush_log_at_trx_commit)
INNODB_LOG_BUFFER_SIZE=$(kv_get "$VARS_TSV" innodb_log_buffer_size)
INNODB_LOG_FILE_SIZE=$(kv_get "$VARS_TSV" innodb_log_file_size)
INNODB_LOG_FILES_IN_GROUP=$(kv_get "$VARS_TSV" innodb_log_files_in_group)
INNODB_REDO_LOG_CAPACITY=$(kv_get "$VARS_TSV" innodb_redo_log_capacity)
INNODB_FILE_PER_TABLE=$(kv_get "$VARS_TSV" innodb_file_per_table)
INNODB_FLUSH_METHOD=$(kv_get "$VARS_TSV" innodb_flush_method)

INNODB_LOG_WAITS=$(kv_get "$STATUS_TSV" Innodb_log_waits)
INNODB_LOG_WRITE_REQ=$(kv_get "$STATUS_TSV" Innodb_log_write_requests)
INNODB_LOG_WRITES=$(kv_get "$STATUS_TSV" Innodb_log_writes)
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
TABLE_OPEN_CACHE_HITS=$(kv_get "$STATUS_TSV" Table_open_cache_hits)
TABLE_OPEN_CACHE_MISSES=$(kv_get "$STATUS_TSV" Table_open_cache_misses)

TABLE_LOCKS_IMMEDIATE=$(kv_get "$STATUS_TSV" Table_locks_immediate)
TABLE_LOCKS_WAITED=$(kv_get "$STATUS_TSV" Table_locks_waited)

MAX_ALLOWED_PACKET=$(kv_get "$VARS_TSV" max_allowed_packet)

# Files / limits
OPEN_FILES_LIMIT=$(kv_get "$VARS_TSV" open_files_limit)
OPEN_FILES=$(kv_get "$STATUS_TSV" Open_files)
TABLE_DEF_CACHE=$(kv_get "$VARS_TSV" table_definition_cache)

# Table definition cache sizing (best-effort)
TOTAL_TABLES=$(mysql_query_silent "SELECT COUNT(*) FROM information_schema.tables;" | head -n 1 | tr -d '\r')

# Engine data sizing (best-effort)
INNODB_DATA_BYTES=$(mysql_query_silent "SELECT IFNULL(SUM(data_length+index_length),0) FROM information_schema.tables WHERE engine='InnoDB' AND table_schema NOT IN ('mysql','information_schema','performance_schema','sys');" | head -n 1 | tr -d '\r')

# Storage engine statistics (best-effort)
ENGINES_ENABLED_CSV=$(mysql_query_silent "SELECT ENGINE,SUPPORT FROM information_schema.ENGINES ORDER BY ENGINE;" | awk -F"\t" '($2=="YES"||$2=="DEFAULT"){print $1}' | tr '\n' ',' | sed 's/,$//')
ENGINE_SIZES_JSON=$(mysql_query_silent "SELECT ENGINE, IFNULL(SUM(DATA_LENGTH+INDEX_LENGTH),0) AS total_bytes, COUNT(*) AS table_count, IFNULL(SUM(DATA_LENGTH),0) AS data_bytes, IFNULL(SUM(INDEX_LENGTH),0) AS index_bytes FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys') AND ENGINE IS NOT NULL GROUP BY ENGINE ORDER BY ENGINE;" | jq -Rn '[inputs | select(length>0) | split("\t") | {engine:.[0], total_bytes:(.[1]|tonumber), table_count:(.[2]|tonumber), data_bytes:(.[3]|tonumber), index_bytes:(.[4]|tonumber)}]')

# Table hygiene / modeling (best-effort)
# 1) fragmented tables: DATA_FREE ratio >10% and table >100MiB
FRAGMENTED_TABLES_JSON=$(mysql_query_silent "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, CAST(DATA_FREE AS SIGNED), (DATA_LENGTH+INDEX_LENGTH) AS used_bytes FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys') AND ENGINE IS NOT NULL AND ENGINE!='MEMORY' AND (DATA_LENGTH/1024/1024)>100 AND CAST(DATA_FREE AS SIGNED)*100/(DATA_LENGTH+INDEX_LENGTH+CAST(DATA_FREE AS SIGNED)) > 10 ORDER BY CAST(DATA_FREE AS SIGNED) DESC;" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], engine:.[2], data_free_bytes:(.[3]|tonumber), used_bytes:(.[4]|tonumber)}]')
FRAGMENTED_TABLES_COUNT=$(printf '%s' "$FRAGMENTED_TABLES_JSON" | jq -r 'length')

# 2) tables without any PRI/UNI key
TABLES_NO_PK_JSON=$(mysql_query_silent "SELECT c.table_schema, c.table_name FROM information_schema.columns c JOIN information_schema.tables t USING (table_schema, table_name) WHERE c.table_schema NOT IN ('sys','mysql','information_schema','performance_schema') AND t.table_type='BASE TABLE' GROUP BY c.table_schema,c.table_name HAVING SUM(IF(c.column_key IN ('PRI','UNI'),1,0)) = 0;" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1]}]')
TABLES_NO_PK_COUNT=$(printf '%s' "$TABLES_NO_PK_JSON" | jq -r 'length')

# 3) large tables (>1GiB) without secondary indexes
LARGE_TABLES_NO_SEC_INDEX_JSON=$(mysql_query_silent "SELECT t.table_schema, t.table_name, (t.data_length + t.index_length) AS total_bytes FROM information_schema.tables t WHERE t.table_type='BASE TABLE' AND (t.data_length + t.index_length) > 1024*1024*1024 AND (SELECT COUNT(*) FROM information_schema.statistics s WHERE s.table_schema=t.table_schema AND s.table_name=t.table_name AND s.index_name != 'PRIMARY') = 0 AND t.table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], total_bytes:(.[2]|tonumber)}]')
LARGE_TABLES_NO_SEC_INDEX_COUNT=$(printf '%s' "$LARGE_TABLES_NO_SEC_INDEX_JSON" | jq -r 'length')

# 4) foreign key type mismatches
FK_MISMATCHES_JSON=$(mysql_query_silent "SELECT CONCAT(k.table_schema,'.',k.table_name,' (',k.column_name,': ',c1.column_type,') -> ',k.referenced_table_schema,'.',k.referenced_table_name,' (',k.referenced_column_name,': ',c2.column_type,')') FROM information_schema.key_column_usage k JOIN information_schema.columns c1 ON k.table_schema=c1.table_schema AND k.table_name=c1.table_name AND k.column_name=c1.column_name JOIN information_schema.columns c2 ON k.referenced_table_schema=c2.table_schema AND k.referenced_table_name=c2.table_name AND k.referenced_column_name=c2.column_name WHERE k.referenced_table_name IS NOT NULL AND (c1.data_type != c2.data_type OR c1.column_type != c2.column_type) AND k.table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" | jq -Rn '[inputs | select(length>0) | {mismatch:.}]')
FK_MISMATCHES_COUNT=$(printf '%s' "$FK_MISMATCHES_JSON" | jq -r 'length')

# 5) non-InnoDB tables
NON_INNODB_TABLES_JSON=$(mysql_query_silent "SELECT table_schema, table_name, engine FROM information_schema.tables t WHERE t.engine <> 'InnoDB' AND t.table_type='BASE TABLE' AND t.table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], engine:.[2]}]')
NON_INNODB_TABLES_COUNT=$(printf '%s' "$NON_INNODB_TABLES_JSON" | jq -r 'length')

# 6) unconstrained *_id columns (best-effort)
UNCONSTRAINED_ID_JSON=$(mysql_query_silent "SELECT c.table_schema, c.table_name, c.column_name FROM information_schema.columns c LEFT JOIN information_schema.key_column_usage k ON c.table_schema = k.table_schema AND c.table_name = k.table_name AND c.column_name = k.column_name AND k.referenced_table_name IS NOT NULL JOIN information_schema.tables t ON c.table_schema=t.table_schema AND c.table_name=t.table_name WHERE c.column_name LIKE '%\\_id' ESCAPE '\\' AND k.column_name IS NULL AND t.table_type='BASE TABLE' AND c.table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2]}]')
UNCONSTRAINED_ID_COUNT=$(printf '%s' "$UNCONSTRAINED_ID_JSON" | jq -r '[ .[] | select(.column != (.table + "_id")) ] | length')

# 7) FK delete rule CASCADE (best-effort)
FK_CASCADE_JSON=$(mysql_query_silent "SELECT rc.constraint_schema, rc.table_name, k.column_name, rc.referenced_table_name, k.referenced_column_name, rc.delete_rule FROM information_schema.referential_constraints rc JOIN information_schema.key_column_usage k ON rc.constraint_schema = k.constraint_schema AND rc.constraint_name = k.constraint_name WHERE rc.constraint_schema NOT IN ('sys','mysql','performance_schema','information_schema') AND rc.delete_rule='CASCADE';" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2], ref_table:.[3], ref_column:.[4], delete_rule:.[5]}]')
FK_CASCADE_COUNT=$(printf '%s' "$FK_CASCADE_JSON" | jq -r 'length')

# 8) empty or view-only schemas
EMPTY_SCHEMAS_JSON=$(mysql_query_silent "SELECT TABLE_SCHEMA, SUM(CASE WHEN TABLE_TYPE='BASE TABLE' THEN 1 ELSE 0 END) AS base_tables, SUM(CASE WHEN TABLE_TYPE='VIEW' THEN 1 ELSE 0 END) AS views FROM information_schema.tables WHERE TABLE_SCHEMA NOT IN ('sys','mysql','performance_schema','information_schema') GROUP BY TABLE_SCHEMA HAVING SUM(CASE WHEN TABLE_TYPE='BASE TABLE' THEN 1 ELSE 0 END) = 0;" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], base_tables:(.[1]|tonumber), views:(.[2]|tonumber)}]')
EMPTY_SCHEMAS_COUNT=$(printf '%s' "$EMPTY_SCHEMAS_JSON" | jq -r 'length')

# 9) nullable columns count (datatype optimization, best-effort)
NULLABLE_COLS_COUNT=$(mysql_query_silent "SELECT COUNT(*) FROM information_schema.columns WHERE is_nullable='YES' AND table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" | head -n 1 | tr -d '\r')

# 10) naming conventions (best-effort)
# table naming: plural (very basic) and camelCase
NAMING_TABLE_ISSUES_JSON=$(mysql_query_silent "SELECT table_schema, table_name FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1]} | . + {plural:((.table|test("[^s]s$";"i")) and (.table|test("status|address|glass|process";"i")|not)), camel:((.table|test("[a-z][A-Z]")))} | select(.plural or .camel)]')
NAMING_TABLE_ISSUES_COUNT=$(printf '%s' "$NAMING_TABLE_ISSUES_JSON" | jq -r 'length')

# column naming: camelCase, boolean prefix, datetime suffix
NAMING_COL_ISSUES_JSON=$(mysql_query_silent "SELECT table_schema, table_name, column_name, data_type, column_type FROM information_schema.columns WHERE table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2], data_type:.[3], column_type:.[4]} | . + {camel:((.column|test("[a-z][A-Z]"))), bool_like:((.column_type|test("tinyint\\(1\\)";"i")) or (.data_type|test("bool";"i"))), bool_bad:( ((.column_type|test("tinyint\\(1\\)";"i")) or (.data_type|test("bool";"i"))) and ((.column|test("^(is_|has_|was_|had_)";"i"))|not) ), dt_like:(.data_type|test("date|time";"i")), dt_bad:((.data_type|test("date|time";"i")) and ((.column|test("(_at|_date|_time)$";"i"))|not))} | select(.camel or .bool_bad or .dt_bad)]')
NAMING_COL_ISSUES_COUNT=$(printf '%s' "$NAMING_COL_ISSUES_JSON" | jq -r 'length')

# 11) non-utf8 columns (best-effort)
NON_UTF8_COLS_JSON=$(mysql_query_silent "SELECT table_schema, table_name, column_name, character_set_name, collation_name, data_type, character_maximum_length FROM information_schema.columns WHERE table_schema NOT IN ('sys','mysql','performance_schema','information_schema') AND (character_set_name IS NOT NULL OR collation_name IS NOT NULL) AND (character_set_name NOT LIKE 'utf8%' OR collation_name NOT LIKE 'utf8%');" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2], charset:.[3], collation:.[4], data_type:.[5], max_len:.[6]}]')
NON_UTF8_COLS_COUNT=$(printf '%s' "$NON_UTF8_COLS_JSON" | jq -r 'length')

# 12) primary key modeling checks (best-effort)
PK_INFO_JSON=$(mysql_query_silent "SELECT c.table_schema, c.table_name, c.column_name, c.data_type, c.column_type FROM information_schema.columns c JOIN information_schema.tables t USING (table_schema, table_name) WHERE t.table_type='BASE TABLE' AND c.column_key='PRI' AND c.table_schema NOT IN ('sys','mysql','information_schema','performance_schema');" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2], data_type:.[3], column_type:.[4]}]')

# 13) fulltext columns (best-effort)
FULLTEXT_COLS_JSON=$(mysql_query_silent "SELECT table_schema, table_name, column_name, data_type FROM information_schema.columns WHERE table_schema NOT IN ('sys','mysql','performance_schema','information_schema') AND data_type='fulltext';" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2], data_type:.[3]}]')
FULLTEXT_COLS_COUNT=$(printf '%s' "$FULLTEXT_COLS_JSON" | jq -r 'length')

# 14) MySQL 8.0+ specific modeling checks (best-effort)
# 14a) JSON columns without generated columns (virtual/stored) for indexing
JSON_NO_GEN_JSON=$(mysql_query_silent "SELECT c.table_schema, c.table_name, c.column_name FROM information_schema.columns c WHERE c.data_type='json' AND c.table_schema NOT IN ('sys','mysql','performance_schema','information_schema') AND NOT EXISTS (SELECT 1 FROM information_schema.columns g WHERE g.table_schema=c.table_schema AND g.table_name=c.table_name AND (g.extra LIKE '%VIRTUAL%' OR g.extra LIKE '%STORED%'));" | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2]}]')
JSON_NO_GEN_COUNT=$(printf '%s' "$JSON_NO_GEN_JSON" | jq -r 'length')

# 14b) invisible indexes (MySQL: IS_VISIBLE='NO', MariaDB: IGNORED='YES')
# We detect MariaDB by VERSION() string containing 'MariaDB'
case "$SERVER_VERSION" in
  *MariaDB*)
    INVISIBLE_IDX_JSON=$(mysql_query_silent "SELECT table_schema, table_name, index_name FROM information_schema.statistics WHERE ignored='YES' AND table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], index:.[2]}]')
    ;;
  *)
    INVISIBLE_IDX_JSON=$(mysql_query_silent "SELECT table_schema, table_name, index_name FROM information_schema.statistics WHERE is_visible='NO' AND table_schema NOT IN ('sys','mysql','performance_schema','information_schema');" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], index:.[2]}]')
    ;;
esac
INVISIBLE_IDX_COUNT=$(printf '%s' "$INVISIBLE_IDX_JSON" | jq -r 'length')

# 14c) CHECK constraints (MySQL 8.0.16+; MariaDB differs)
# best-effort: only on MySQL >=8.0.16 and non-MariaDB
CHECK_CONSTRAINTS_JSON='[]'
CHECK_CONSTRAINTS_COUNT=0
if [ "$(num "$MYSQL_VER_MAJ")" -ge 8 ] && [ "$(num "$MYSQL_VER_MIN")" -ge 0 ]; then
  if [ "$(num "$MYSQL_VER_MAJ")" -gt 8 ] || [ "$(num "$MYSQL_VER_MIN")" -gt 0 ] || [ "$(num "$MYSQL_VER_MIC")" -ge 16 ]; then
    case "$SERVER_VERSION" in
      *MariaDB*) : ;;
      *)
        CHECK_CONSTRAINTS_JSON=$(mysql_query_silent "SELECT constraint_schema, table_name, constraint_name FROM information_schema.table_constraints WHERE constraint_type='CHECK' AND constraint_schema NOT IN ('sys','mysql','performance_schema','information_schema');" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], constraint:.[2]}]')
        CHECK_CONSTRAINTS_COUNT=$(printf '%s' "$CHECK_CONSTRAINTS_JSON" | jq -r 'length')
        ;;
    esac
  fi
fi

# 15) Plugin Information (active plugins, best-effort)
PLUGINS_ACTIVE_JSON=$(mysql_query_silent "SELECT plugin_name, plugin_version, plugin_status, plugin_type FROM information_schema.plugins WHERE plugin_status='ACTIVE' AND plugin_type != 'INFORMATION SCHEMA' ORDER BY plugin_type, plugin_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {name:.[0], version:.[1], status:.[2], type:.[3]}]')
PLUGINS_ACTIVE_COUNT=$(printf '%s' "$PLUGINS_ACTIVE_JSON" | jq -r 'length')

# 16) Database Metrics (summary, best-effort)
DATABASES_LIST_JSON=$(mysql_query_silent "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys')"$( [ -n "$IGNORE_DBS" ] && printf '%s' " AND schema_name NOT IN ($(sql_in_list \"$IGNORE_DBS\"))" )";" 2>/dev/null | jq -Rn '[inputs | select(length>0) | {schema:.}]')
DATABASES_COUNT=$(printf '%s' "$DATABASES_LIST_JSON" | jq -r 'length')

DB_TABLES_COUNT=$(mysql_query_silent "SELECT COUNT(*) FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables);" 2>/dev/null | head -n 1 | tr -d '\r')
DB_VIEWS_COUNT=$(mysql_query_silent "SELECT COUNT(*) FROM information_schema.tables WHERE table_type='VIEW' AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs);" 2>/dev/null | head -n 1 | tr -d '\r')
DB_INDEXES_COUNT=$(mysql_query_silent "SELECT COUNT(DISTINCT CONCAT(table_name, table_schema, index_name)) FROM information_schema.statistics WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables);" 2>/dev/null | head -n 1 | tr -d '\r')

DB_SUMMARY_TSV=$(mysql_query_silent "SELECT IFNULL(SUM(table_rows),0), IFNULL(SUM(data_length),0), IFNULL(SUM(index_length),0), IFNULL(SUM(data_length+index_length),0), COUNT(table_name), COUNT(DISTINCT table_collation), COUNT(DISTINCT engine) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables);" 2>/dev/null | head -n 1 | tr -d '\r')
DB_TOTAL_ROWS=$(printf '%s' "$DB_SUMMARY_TSV" | awk -F"\t" '{print $1}')
DB_DATA_BYTES=$(printf '%s' "$DB_SUMMARY_TSV" | awk -F"\t" '{print $2}')
DB_INDEX_BYTES=$(printf '%s' "$DB_SUMMARY_TSV" | awk -F"\t" '{print $3}')
DB_TOTAL_BYTES=$(printf '%s' "$DB_SUMMARY_TSV" | awk -F"\t" '{print $4}')

DB_CHARSETS_JSON=$(mysql_query_silent "SELECT DISTINCT character_set_name FROM information_schema.columns WHERE character_set_name IS NOT NULL AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) ORDER BY character_set_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | .]')
DB_CHARSETS_COUNT=$(printf '%s' "$DB_CHARSETS_JSON" | jq -r 'length')

DB_COLLATIONS_JSON=$(mysql_query_silent "SELECT DISTINCT table_collation FROM information_schema.tables WHERE table_collation IS NOT NULL AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) ORDER BY table_collation;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | .]')
DB_COLLATIONS_COUNT=$(printf '%s' "$DB_COLLATIONS_JSON" | jq -r 'length')

DB_ENGINES_JSON=$(mysql_query_silent "SELECT DISTINCT engine FROM information_schema.tables WHERE engine IS NOT NULL AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) ORDER BY engine;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | .]')
DB_ENGINES_COUNT=$(printf '%s' "$DB_ENGINES_JSON" | jq -r 'length')

# Per-database breakdown (best-effort)
DB_BREAKDOWN_JSON=$(mysql_query_silent "SELECT table_schema, IFNULL(SUM(table_rows),0), IFNULL(SUM(data_length),0), IFNULL(SUM(index_length),0), IFNULL(SUM(data_length+index_length),0), COUNT(CASE WHEN table_type='BASE TABLE' THEN 1 END), COUNT(CASE WHEN table_type='VIEW' THEN 1 END), COUNT(DISTINCT engine), COUNT(DISTINCT table_collation) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) GROUP BY table_schema ORDER BY IFNULL(SUM(data_length+index_length),0) DESC;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], rows:(.[1]|tonumber), data_bytes:(.[2]|tonumber), index_bytes:(.[3]|tonumber), total_bytes:(.[4]|tonumber), tables:(.[5]|tonumber), views:(.[6]|tonumber), engines:(.[7]|tonumber), collations:(.[8]|tonumber)}]')
DB_BREAKDOWN_COUNT=$(printf '%s' "$DB_BREAKDOWN_JSON" | jq -r 'length')

# Largest tables (best-effort)
LARGEST_TABLES_JSON=$(mysql_query_silent "SELECT table_schema, table_name, engine, IFNULL(table_rows,0), IFNULL(data_length,0), IFNULL(index_length,0), IFNULL(data_length+index_length,0) AS total_bytes, CAST(IFNULL(data_free,0) AS SIGNED) AS data_free FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) ORDER BY total_bytes DESC LIMIT 20;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], engine:.[2], rows:(.[3]|tonumber), data_bytes:(.[4]|tonumber), index_bytes:(.[5]|tonumber), total_bytes:(.[6]|tonumber), data_free_bytes:(.[7]|tonumber)}]')
LARGEST_TABLES_COUNT=$(printf '%s' "$LARGEST_TABLES_JSON" | jq -r 'length')

# Index counts per database (best-effort)
DB_INDEX_BREAKDOWN_JSON=$(mysql_query_silent "SELECT table_schema, COUNT(DISTINCT CONCAT(table_name, index_name)) AS indexes FROM information_schema.statistics WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) GROUP BY table_schema ORDER BY indexes DESC;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], indexes:(.[1]|tonumber)}]')
DB_INDEX_BREAKDOWN_COUNT=$(printf '%s' "$DB_INDEX_BREAKDOWN_JSON" | jq -r 'length')

# Views / routines / triggers inventory (best-effort)
VIEWS_JSON=$(mysql_query_silent "SELECT table_schema, table_name FROM information_schema.views WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs) ORDER BY table_schema, table_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], view:.[1]}]')
VIEWS_COUNT=$(printf '%s' "$VIEWS_JSON" | jq -r 'length')

ROUTINES_JSON=$(mysql_query_silent "SELECT routine_schema, routine_name, routine_type, security_type, definer FROM information_schema.routines WHERE routine_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs) ORDER BY routine_schema, routine_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], routine:.[1], type:.[2], security_type:.[3], definer:.[4]}]')
ROUTINES_COUNT=$(printf '%s' "$ROUTINES_JSON" | jq -r 'length')

TRIGGERS_JSON=$(mysql_query_silent "SELECT trigger_schema, trigger_name, event_object_table, event_manipulation, action_timing, definer FROM information_schema.triggers WHERE trigger_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs) ORDER BY trigger_schema, trigger_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], trigger:.[1], table:.[2], event:.[3], timing:.[4], definer:.[5]}]')
TRIGGERS_COUNT=$(printf '%s' "$TRIGGERS_JSON" | jq -r 'length')

# mysql_tables (table metrics) - best-effort; gated by --tbstat
TABLE_METRICS_JSON='[]'
TABLE_METRICS_COUNT=0
if [ "$TBSTAT" -eq 1 ] || [ -n "$SCHEMA_DIR" ]; then
  # table index listing (1 row per index)
  TABLE_IDX_RAW_JSON=$(mysql_query_silent "SELECT t.table_schema, t.table_name, t.engine, s.index_name, GROUP_CONCAT(s.column_name ORDER BY s.seq_in_index) AS cols, s.index_type, s.non_unique FROM information_schema.tables t LEFT JOIN information_schema.statistics s ON t.table_schema=s.table_schema AND t.table_name=s.table_name WHERE t.table_type='BASE TABLE' AND t.table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) GROUP BY t.table_schema, t.table_name, t.engine, s.index_name, s.index_type, s.non_unique ORDER BY t.table_schema, t.table_name, s.index_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], engine:.[2], index:.[3], cols:.[4], index_type:.[5], non_unique:.[6]}]')

  # table stats summary (1 row per table)
  TABLE_STAT_RAW_JSON=$(mysql_query_silent "SELECT table_schema, table_name, engine, row_format, IFNULL(table_rows,0), IFNULL(avg_row_length,0), IFNULL(data_length,0), IFNULL(index_length,0), IFNULL(data_length+index_length,0) AS total_bytes, CAST(IFNULL(data_free,0) AS SIGNED) AS data_free_bytes, IFNULL(table_collation,''), IFNULL(create_time,''), IFNULL(update_time,'') FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) ORDER BY table_schema, table_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], engine:.[2], row_format:.[3], rows:(.[4]|tonumber), avg_row_length:(.[5]|tonumber), data_bytes:(.[6]|tonumber), index_bytes:(.[7]|tonumber), total_bytes:(.[8]|tonumber), data_free_bytes:(.[9]|tonumber), collation:.[10], create_time:.[11], update_time:.[12]}]')

  # table column summary (1 row per table)
  TABLE_COL_RAW_JSON=$(mysql_query_silent "SELECT table_schema, table_name, COUNT(*) AS columns, SUM(CASE WHEN is_nullable='YES' THEN 1 ELSE 0 END) AS nullable_columns, SUM(CASE WHEN data_type='json' THEN 1 ELSE 0 END) AS json_columns, SUM(CASE WHEN data_type IN ('text','tinytext','mediumtext','longtext') THEN 1 ELSE 0 END) AS text_columns, SUM(CASE WHEN data_type IN ('blob','tinyblob','mediumblob','longblob') THEN 1 ELSE 0 END) AS blob_columns, SUM(CASE WHEN column_key='PRI' THEN 1 ELSE 0 END) AS pk_columns, SUM(CASE WHEN extra LIKE '%auto_increment%' THEN 1 ELSE 0 END) AS auto_increment_columns, SUM(CASE WHEN data_type IN ('timestamp','datetime') THEN 1 ELSE 0 END) AS datetime_columns FROM information_schema.columns WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) GROUP BY table_schema, table_name ORDER BY table_schema, table_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], columns:(.[2]|tonumber), nullable_columns:(.[3]|tonumber), json_columns:(.[4]|tonumber), text_columns:(.[5]|tonumber), blob_columns:(.[6]|tonumber), pk_columns:(.[7]|tonumber), auto_increment_columns:(.[8]|tonumber), datetime_columns:(.[9]|tonumber)}]')

  # merge into per-table objects
  TABLE_METRICS_JSON=$(jq -n --argjson idx "$TABLE_IDX_RAW_JSON" --argjson col "$TABLE_COL_RAW_JSON" --argjson st "$TABLE_STAT_RAW_JSON" '
    ($idx | group_by(.schema,.table) | map({schema:.[0].schema, table:.[0].table, engine:.[0].engine, indexes:(map(select(.index!="" and .index!="NULL") | {name:.index, columns:(.cols|split(",")), type:.index_type, non_unique:((.non_unique|tonumber?)//0) }))})) as $t
    | ($col | map({key:(.schema+"\u0000"+.table), value:.}) | from_entries) as $cm
    | ($st  | map({key:(.schema+"\u0000"+.table), value:.}) | from_entries) as $sm
    | $t
    | map(
        .
        + (($cm[(.schema+"\u0000"+.table)] // {}) | {columns, nullable_columns, json_columns, text_columns, blob_columns, pk_columns, auto_increment_columns, datetime_columns})
        + (($sm[(.schema+"\u0000"+.table)] // {}) | {row_format, rows, avg_row_length, data_bytes, index_bytes, total_bytes, data_free_bytes, collation, create_time, update_time})
      )
  ')

  TABLE_METRICS_COUNT=$(printf '%s' "$TABLE_METRICS_JSON" | jq -r 'length')
fi

# Index inventory (best-effort)
INDEXES_JSON=$(mysql_query_silent "SELECT table_schema, table_name, index_name, GROUP_CONCAT(column_name ORDER BY seq_in_index) AS cols, index_type, non_unique FROM information_schema.statistics WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) GROUP BY table_schema, table_name, index_name, index_type, non_unique ORDER BY table_schema, table_name, index_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], index:.[2], columns:(.[3]|split(",")), index_type:.[4], non_unique:(.[5]|tonumber)}]')
INDEXES_COUNT=$(printf '%s' "$INDEXES_JSON" | jq -r 'length')

TABLES_NO_INDEX_JSON=$(mysql_query_silent "SELECT t.table_schema, t.table_name FROM information_schema.tables t WHERE t.table_type='BASE TABLE' AND t.table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) AND NOT EXISTS (SELECT 1 FROM information_schema.statistics s WHERE s.table_schema=t.table_schema AND s.table_name=t.table_name);" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1]}]')
TABLES_NO_INDEX_COUNT=$(printf '%s' "$TABLES_NO_INDEX_JSON" | jq -r 'length')

# Index quality checks (best-effort)
DUPLICATE_INDEXES_JSON=$(mysql_query_silent "SELECT table_schema, table_name, GROUP_CONCAT(index_name ORDER BY index_name) AS indexes, GROUP_CONCAT(DISTINCT column_name ORDER BY seq_in_index) AS cols, index_type, non_unique, COUNT(DISTINCT index_name) AS idx_count FROM information_schema.statistics WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) GROUP BY table_schema, table_name, cols, index_type, non_unique HAVING COUNT(DISTINCT index_name) > 1;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], indexes:(.[2]|split(",")), columns:(.[3]|split(",")), index_type:.[4], non_unique:(.[5]|tonumber), count:(.[6]|tonumber)}]')
DUPLICATE_INDEXES_COUNT=$(printf '%s' "$DUPLICATE_INDEXES_JSON" | jq -r 'length')

# Same columns but different uniqueness (non-unique index redundant if unique exists)
SAME_COLS_DIFF_UNIQ_JSON=$(printf '%s' "$INDEXES_JSON" | jq -c '
  group_by(.schema,.table,.columns,.index_type)
  | map(select((map(.non_unique)|unique|length) > 1))
  | map({schema:.[0].schema, table:.[0].table, columns:.[0].columns, index_type:.[0].index_type,
         unique_indexes:(map(select((.non_unique|tonumber)==0) | .index)),
         non_unique_indexes:(map(select((.non_unique|tonumber)==1) | .index))})
')
SAME_COLS_DIFF_UNIQ_COUNT=$(printf '%s' "$SAME_COLS_DIFF_UNIQ_JSON" | jq -r 'length')

# Redundant/prefix indexes: if index A columns is a strict prefix of index B columns on same table
# Conservative rule: only flag redundant when both indexes have same uniqueness (non_unique).
REDUNDANT_INDEXES_JSON=$(printf '%s' "$INDEXES_JSON" | jq -c '
  group_by(.schema,.table)
  | map({schema:.[0].schema, table:.[0].table, idx:.})
  | map(.idx as $l | [
      ($l[] as $a | $l[] as $b |
        select($a.index != $b.index)
        | select($a.non_unique == $b.non_unique)
        | select(($a.columns|length) < ($b.columns|length))
        | select(($b.columns[0:($a.columns|length)]) == $a.columns)
        | {schema:$a.schema, table:$a.table, redundant:$a.index, covered_by:$b.index, redundant_cols:$a.columns, covering_cols:$b.columns, non_unique:($a.non_unique|tonumber)}
      )
    ] | unique)
  | add
  | (if .==null then [] else . end)
')
REDUNDANT_INDEXES_COUNT=$(printf '%s' "$REDUNDANT_INDEXES_JSON" | jq -r 'length')

# Unique index redundant to PRIMARY KEY (exact same cols)
UNIQUE_REDUNDANT_PK_JSON=$(printf '%s' "$INDEXES_JSON" | jq -c '
  group_by(.schema,.table)
  | map(. as $l |
      ($l | map(select(.index=="PRIMARY") | .columns) | .[0] // null) as $pk
      | select($pk!=null)
      | ($l | map(select(.index!="PRIMARY" and (.non_unique|tonumber)==0 and .columns==$pk)
                | {schema:.schema, table:.table, unique_index:.index, pk_columns:$pk, index_type:.index_type}))
    )
  | add | (if .==null then [] else . end)
')
UNIQUE_REDUNDANT_PK_COUNT=$(printf '%s' "$UNIQUE_REDUNDANT_PK_JSON" | jq -r 'length')

# Schema documentation / Mermaid ERD (best-effort; write files only)
if [ -n "$SCHEMA_DIR" ]; then
  mkdir -p "$SCHEMA_DIR" 2>/dev/null || true
  mkdir -p "$SCHEMA_DIR/databases" 2>/dev/null || true

  NOW_STR=$(date 2>/dev/null || echo "")
  # Schema markdown (overview)
  {
    printf '# Database Schema Documentation\n\n'
    [ -n "$NOW_STR" ] && printf 'Generated by mysqltuner.sh on %s\n\n' "$NOW_STR" || true
    printf '## Summary\n\n'
    printf '%s\n' "- Databases: $DATABASES_COUNT"
    printf '%s\n' "- Tables: $DB_TABLES_COUNT"
    printf '%s\n' "- Views: $DB_VIEWS_COUNT"
    printf '%s\n\n' "- Indexes: $DB_INDEXES_COUNT"
    printf '## Largest tables (top 20)\n\n'
    printf '%s' "$LARGEST_TABLES_JSON" | jq -r '.[] | "- " + .schema + "." + .table + " (" + (.engine//"") + ") total=" + (.total_bytes|tostring)'
    printf '\n## Indexes (by table)\n\n'
    printf '%s' "$INDEXES_JSON" | jq -r '.[] | "- " + .schema + "." + .table + ": " + .index + " (" + (.index_type//"") + ") cols=" + (.columns|join(","))'
  } | write_text_file "$SCHEMA_DIR/schema.md"

  # Mermaid ER diagram (with entities + PK cols, plus FK relationships)
  SCHEMA_TABLES_JSON=$(mysql_query_silent "SELECT table_schema, table_name FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) ORDER BY table_schema, table_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1]}]')
  PK_COLS_JSON=$(mysql_query_silent "SELECT table_schema, table_name, column_name FROM information_schema.columns WHERE column_key='PRI' AND table_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) ORDER BY table_schema, table_name, ordinal_position;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2]}]')
  FK_RELS_JSON=$(mysql_query_silent "SELECT constraint_schema, table_name, referenced_table_name FROM information_schema.key_column_usage WHERE referenced_table_name IS NOT NULL AND constraint_schema NOT IN ('mysql','performance_schema','information_schema','sys')$(ignore_sql_dbs)$(ignore_sql_tables) GROUP BY constraint_schema, table_name, referenced_table_name;" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], ref_table:.[2]}]')

  {
    printf '%s\n' 'erDiagram'

    # entities: list all base tables, with PK columns when present
    printf '%s' "$SCHEMA_TABLES_JSON" | jq -c '.[]' | while IFS= read -r tbl; do
      sch=$(printf '%s' "$tbl" | jq -r '.schema')
      tb=$(printf '%s' "$tbl" | jq -r '.table')
      ent=$(printf '%s' "$sch.$tb" | sed 's/\./_/g')
      printf '  %s {\n' "$ent"
      # PK columns (if any)
      pk_lines=$(printf '%s' "$PK_COLS_JSON" | jq -r --arg s "$sch" --arg t "$tb" '.[] | select(.schema==$s and .table==$t) | "    string " + .column + " PK"')
      if [ -n "$pk_lines" ]; then
        printf '%s\n' "$pk_lines"
      else
        printf '%s\n' "    string _no_pk"
      fi
      printf '%s\n' '  }'
    done

    # relationships
    printf '%s' "$FK_RELS_JSON" | jq -r '.[] | "  " + ((.schema+"."+.table)|gsub("\\.";"_")) + " }o--|| " + ((.schema+"."+.ref_table)|gsub("\\.";"_")) + " : FK"'
  } | write_text_file "$SCHEMA_DIR/schema.mmd"

  # Per-database markdown docs (lightweight)
  printf '%s' "$DB_BREAKDOWN_JSON" | jq -r '.[].schema' | while IFS= read -r db; do
    [ -z "$db" ] && continue
    {
      printf '# Database: %s\n\n' "$db"
      [ -n "$NOW_STR" ] && printf 'Generated by mysqltuner.sh on %s\n\n' "$NOW_STR" || true

      printf '### Tables\n\n'
      # list tables with engine and total size (respect ignore-tables)
      mysql_query_silent "SELECT table_name, engine, IFNULL(data_length+index_length,0) AS total_bytes FROM information_schema.tables WHERE table_schema='$db' AND table_type='BASE TABLE'""$(ignore_sql_tables)"" ORDER BY total_bytes DESC, table_name;" 2>/dev/null | \
        jq -Rnr '[inputs | select(length>0) | split("\t") | {table:.[0], engine:.[1], total_bytes:(.[2]|tonumber)}] | .[] | "- **" + .table + "** (" + (.engine//"") + ") total=" + (.total_bytes|tostring)'

      printf '\n### Foreign Keys\n\n'
      printf '%s' "$FK_RELS_JSON" | jq -r --arg db "$db" '.[] | select(.schema==$db) | "- " + .table + " -> " + .ref_table'
    } | write_text_file "$SCHEMA_DIR/databases/$db.md"

    # per-table docs (when table_metrics available)
    mkdir -p "$SCHEMA_DIR/databases/$db" 2>/dev/null || true
    printf '%s' "$TABLE_METRICS_JSON" | jq -c --arg db "$db" '.[] | select(.schema==$db)' | while IFS= read -r t; do
      tb=$(printf '%s' "$t" | jq -r '.table')
      [ -z "$tb" ] && continue
      {
        printf '%s\n' "### Table: $tb"
        printf '%s\n\n' "- **Engine**: $(printf '%s' "$t" | jq -r '.engine//""')"

        printf '#### Indexes\n\n'
        printf '%s' "$t" | jq -r '.indexes[]? | "- **" + .name + "**: " + (.columns|join(",")) + " (" + (.type//"") + ")" + (if (.non_unique|tonumber)==0 then " UNIQUE" else "" end)'
        if [ "$(printf '%s' "$t" | jq -r '(.indexes|length)')" -eq 0 ]; then
          printf '%s\n' "- *No indexes defined*"
        fi

        printf '\n#### Columns\n\n'
        mysql_query_silent "SELECT column_name, column_type, is_nullable FROM information_schema.columns WHERE table_schema='$db' AND table_name='$tb' ORDER BY ordinal_position;" 2>/dev/null | \
          jq -Rnr '[inputs | select(length>0) | split("\t") | {name:.[0], type:.[1], nullable:.[2]}] | .[] | "- **" + .name + "**: " + (.type|ascii_upcase) + (if .nullable=="NO" then " NOT NULL" else " NULL" end)'

        printf '\n#### Constraints\n\n'
        # CHECK constraints (best-effort) + clauses (MySQL 8+)
        CHECK_NAMES=$(mysql_query_silent "SELECT constraint_name FROM information_schema.table_constraints WHERE constraint_type='CHECK' AND constraint_schema='$db' AND table_name='$tb' ORDER BY constraint_name;" 2>/dev/null)
        if [ -z "$CHECK_NAMES" ]; then
          printf '%s\n' "*No CHECK constraints*"
        else
          printf '%s\n' "$CHECK_NAMES" | while IFS= read -r cn; do
            [ -z "$cn" ] && continue
            clause=$(mysql_query_silent "SELECT check_clause FROM information_schema.check_constraints WHERE constraint_schema='$db' AND constraint_name='$cn';" 2>/dev/null | head -n 1)
            if [ -n "$clause" ]; then
              printf '%s\n' "- $cn: $clause"
            else
              printf '%s\n' "- $cn"
            fi
          done
        fi

        printf '\n#### Foreign Keys\n\n'
        # FK list with update/delete rules (best-effort)
        mysql_query_silent "SELECT k.constraint_name, k.referenced_table_name, k.column_name, k.referenced_column_name, rc.update_rule, rc.delete_rule FROM information_schema.key_column_usage k JOIN information_schema.referential_constraints rc ON k.constraint_schema=rc.constraint_schema AND k.constraint_name=rc.constraint_name WHERE k.table_schema='$db' AND k.table_name='$tb' AND k.referenced_table_name IS NOT NULL ORDER BY k.constraint_name, k.ordinal_position;" 2>/dev/null | \
          jq -Rnr '[inputs | select(length>0) | split("\t") | {name:.[0], ref_table:.[1], col:.[2], ref_col:.[3], update_rule:.[4], delete_rule:.[5]}]
            | if length==0 then ["*No FOREIGN KEY constraints*"]
              else (group_by(.name,.ref_table,.update_rule,.delete_rule)
                | map("- " + .[0].name + " -> " + .[0].ref_table + " (ON UPDATE " + (.[0].update_rule//"") + ", ON DELETE " + (.[0].delete_rule//"") + ") cols=" + (map(.col + "->" + .ref_col) | join(","))))
              end
            | .[]'

        printf '\n---\n\n'
      } | write_text_file "$SCHEMA_DIR/databases/$db/$tb.md"
    done
  done
fi

# Optional: write upstream-style CSV dumps
if [ -n "$DUMP_DIR" ]; then
  mkdir -p "$DUMP_DIR" 2>/dev/null || true

  # tables_without_primary_keys.csv (ours: tables without PRI/UNI)
  printf '%s' "$TABLES_NO_PK_JSON" | dump_csv_file "$DUMP_DIR/tables_without_primary_keys.csv" "Schema,Table" '.[] | [.schema,.table] | @csv'

  # tables_non_innodb.csv
  printf '%s' "$NON_INNODB_TABLES_JSON" | dump_csv_file "$DUMP_DIR/tables_non_innodb.csv" "Schema,Table,Engine" '.[] | [.schema,.table,.engine] | @csv'

  # columns_non_utf8.csv
  printf '%s' "$NON_UTF8_COLS_JSON" | dump_csv_file "$DUMP_DIR/columns_non_utf8.csv" "Schema,Table,Column,Charset,Collation,Data Type,Max Length" '.[] | [.schema,.table,.column,(.charset//""),(.collation//""),.data_type,(.max_len//"")] | @csv'

  # columns_utf8.csv (informational)
  UTF8_COLS_JSON=$(mysql_query_silent "SELECT table_schema, table_name, column_name, character_set_name, collation_name, data_type, character_maximum_length FROM information_schema.columns WHERE table_schema NOT IN ('sys','mysql','performance_schema','information_schema') AND (character_set_name IS NOT NULL OR collation_name IS NOT NULL) AND (character_set_name LIKE 'utf8%' OR collation_name LIKE 'utf8%');" 2>/dev/null | jq -Rn '[inputs | select(length>0) | split("\t") | {schema:.[0], table:.[1], column:.[2], charset:.[3], collation:.[4], data_type:.[5], max_len:.[6]}]')
  printf '%s' "$UTF8_COLS_JSON" | dump_csv_file "$DUMP_DIR/columns_utf8.csv" "Schema,Table,Column,Charset,Collation,Data Type,Max Length" '.[] | [.schema,.table,.column,(.charset//""),(.collation//""),.data_type,(.max_len//"")] | @csv'

  # fulltext_columns.csv
  printf '%s' "$FULLTEXT_COLS_JSON" | dump_csv_file "$DUMP_DIR/fulltext_columns.csv" "Schema,Table,Column,Data Type" '.[] | [.schema,.table,.column,.data_type] | @csv'

  # plugins_active.csv
  printf '%s' "$PLUGINS_ACTIVE_JSON" | dump_csv_file "$DUMP_DIR/plugins_active.csv" "Plugin,Version,Status,Type" '.[] | [.name,(.version//""),(.status//""),(.type//"")] | @csv'

  # databases_summary.csv
  DB_SUMMARY_JSON=$(jq -n --arg databases_count "$DATABASES_COUNT" --arg tables "$DB_TABLES_COUNT" --arg views "$DB_VIEWS_COUNT" --arg indexes "$DB_INDEXES_COUNT" --arg rows "$DB_TOTAL_ROWS" --arg data_bytes "$DB_DATA_BYTES" --arg index_bytes "$DB_INDEX_BYTES" --arg total_bytes "$DB_TOTAL_BYTES" '{databases_count:$databases_count,tables:$tables,views:$views,indexes:$indexes,rows:$rows,data_bytes:$data_bytes,index_bytes:$index_bytes,total_bytes:$total_bytes}')
  printf '%s' "$DB_SUMMARY_JSON" | dump_csv_file "$DUMP_DIR/databases_summary.csv" "Databases,Tables,Views,Indexes,Rows,DataBytes,IndexBytes,TotalBytes" '. | [.databases_count,.tables,.views,.indexes,.rows,.data_bytes,.index_bytes,.total_bytes] | @csv'

  # databases_breakdown.csv
  printf '%s' "$DB_BREAKDOWN_JSON" | dump_csv_file "$DUMP_DIR/databases_breakdown.csv" "Schema,Tables,Views,Rows,DataBytes,IndexBytes,TotalBytes,Engines,Collations" '.[] | [.schema,.tables,.views,.rows,.data_bytes,.index_bytes,.total_bytes,.engines,.collations] | @csv'

  # db_index_breakdown.csv
  printf '%s' "$DB_INDEX_BREAKDOWN_JSON" | dump_csv_file "$DUMP_DIR/db_index_breakdown.csv" "Schema,Indexes" '.[] | [.schema,.indexes] | @csv'

  # largest_tables.csv
  printf '%s' "$LARGEST_TABLES_JSON" | dump_csv_file "$DUMP_DIR/largest_tables.csv" "Schema,Table,Engine,Rows,DataBytes,IndexBytes,TotalBytes,DataFreeBytes" '.[] | [.schema,.table,(.engine//""),.rows,.data_bytes,.index_bytes,.total_bytes,.data_free_bytes] | @csv'

  # views.csv
  printf '%s' "$VIEWS_JSON" | dump_csv_file "$DUMP_DIR/views.csv" "Schema,View" '.[] | [.schema,.view] | @csv'

  # routines.csv
  printf '%s' "$ROUTINES_JSON" | dump_csv_file "$DUMP_DIR/routines.csv" "Schema,Routine,Type,SecurityType,Definer" '.[] | [.schema,.routine,.type,(.security_type//""),(.definer//"")] | @csv'

  # triggers.csv
  printf '%s' "$TRIGGERS_JSON" | dump_csv_file "$DUMP_DIR/triggers.csv" "Schema,Trigger,Table,Event,Timing,Definer" '.[] | [.schema,.trigger,.table,.event,.timing,(.definer//"")] | @csv'

  # indexes.csv
  printf '%s' "$INDEXES_JSON" | dump_csv_file "$DUMP_DIR/indexes.csv" "Schema,Table,Index,IndexType,NonUnique,Columns" '.[] | [.schema,.table,.index,(.index_type//""),(.non_unique|tostring),(.columns|join(","))] | @csv'

  # tables_no_index.csv
  printf '%s' "$TABLES_NO_INDEX_JSON" | dump_csv_file "$DUMP_DIR/tables_no_index.csv" "Schema,Table" '.[] | [.schema,.table] | @csv'

  # table_metrics.json (raw)
  if [ "$TBSTAT" -eq 1 ] || [ -n "$SCHEMA_DIR" ]; then
    printf '%s\n' "$TABLE_METRICS_JSON" >"$DUMP_DIR/table_metrics.json"
    printf '%s' "$TABLE_METRICS_JSON" | dump_csv_file "$DUMP_DIR/table_metrics.csv" "Schema,Table,Engine,Collation,RowFormat,Rows,AvgRowLength,DataBytes,IndexBytes,TotalBytes,DataFreeBytes,Columns,PKColumns,AutoIncColumns,NullableColumns,DatetimeColumns,JSONColumns,TextColumns,BlobColumns" '.[] | [.schema,.table,(.engine//""),(.collation//""),(.row_format//""),(.rows|tostring),(.avg_row_length|tostring),(.data_bytes|tostring),(.index_bytes|tostring),(.total_bytes|tostring),(.data_free_bytes|tostring),(.columns|tostring),(.pk_columns|tostring),(.auto_increment_columns|tostring),(.nullable_columns|tostring),(.datetime_columns|tostring),(.json_columns|tostring),(.text_columns|tostring),(.blob_columns|tostring)] | @csv'
  fi

  # schema_documentation.md (consolidated, upstream-like)
  if [ -n "$SCHEMA_DIR" ] && [ -f "$SCHEMA_DIR/schema.md" ]; then
    {
      cat "$SCHEMA_DIR/schema.md"
      printf '\n\n## Mermaid ER Diagram\n\n```mermaid\n'
      [ -f "$SCHEMA_DIR/schema.mmd" ] && cat "$SCHEMA_DIR/schema.mmd" || true
      printf '\n```\n'
    } >"$DUMP_DIR/schema_documentation.md" 2>/dev/null || true
  fi

  # duplicate_indexes.csv
  printf '%s' "$DUPLICATE_INDEXES_JSON" | dump_csv_file "$DUMP_DIR/duplicate_indexes.csv" "Schema,Table,Indexes,Columns,IndexType,NonUnique" '.[] | [.schema,.table,(.indexes|join("|")),(.columns|join("|")),(.index_type//""),(.non_unique|tostring)] | @csv'

  # same_cols_diff_uniqueness.csv
  printf '%s' "$SAME_COLS_DIFF_UNIQ_JSON" | dump_csv_file "$DUMP_DIR/same_cols_diff_uniqueness.csv" "Schema,Table,Columns,UniqueIndexes,NonUniqueIndexes,IndexType" '.[] | [.schema,.table,(.columns|join("|")),(.unique_indexes|join("|")),(.non_unique_indexes|join("|")),(.index_type//"")] | @csv'

  # redundant_indexes.csv
  printf '%s' "$REDUNDANT_INDEXES_JSON" | dump_csv_file "$DUMP_DIR/redundant_indexes.csv" "Schema,Table,RedundantIndex,CoveredBy,RedundantCols,CoveringCols,NonUnique" '.[] | [.schema,.table,.redundant,.covered_by,(.redundant_cols|join("|")),(.covering_cols|join("|")),(.non_unique|tostring)] | @csv'

  # unique_redundant_pk.csv
  printf '%s' "$UNIQUE_REDUNDANT_PK_JSON" | dump_csv_file "$DUMP_DIR/unique_redundant_pk.csv" "Schema,Table,UniqueIndex,IndexType,PKColumns" '.[] | [.schema,.table,.unique_index,(.index_type//""),(.pk_columns|join("|"))] | @csv'
fi

PK_NAMING_ISSUES_JSON=$(printf '%s' "$PK_INFO_JSON" | jq -c '[.[] | select(type=="object") | select(.column != "id" and .column != (.table + "_id")) | {schema, table, column}]')
PK_NAMING_ISSUES_COUNT=$(printf '%s' "$PK_NAMING_ISSUES_JSON" | jq -r 'length')

UUID_PK_ISSUES_JSON=$(printf '%s' "$PK_INFO_JSON" | jq -c '[.[]
  | select(type=="object")
  | select((.column|test("uuid";"i")))
  | select( ((.data_type|test("binary";"i"))|not) or (((.column_type//"" )|test("16"))|not) )
  | {schema, table, column, data_type, column_type}
]')
UUID_PK_ISSUES_COUNT=$(printf '%s' "$UUID_PK_ISSUES_JSON" | jq -r 'length')

PK_SURROGATE_ISSUES_JSON=$(printf '%s' "$PK_INFO_JSON" | jq -c '[.[]
  | select(type=="object")
  | select((.column|test("uuid";"i"))|not)
  | select(
      ((.data_type|test("int";"i"))|not)
      or (((.column_type//"")|test("unsigned";"i"))|not)
      or (((.column_type//"")|test("auto_increment";"i"))|not)
    )
  | {schema, table, column, data_type, column_type}
]')
PK_SURROGATE_ISSUES_COUNT=$(printf '%s' "$PK_SURROGATE_ISSUES_JSON" | jq -r 'length')

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
BINLOG_CACHE_SIZE=$(kv_get "$VARS_TSV" binlog_cache_size)
GTID_MODE=$(kv_get "$VARS_TSV" gtid_mode)
GTID_CURRENT_POS=$(kv_get "$VARS_TSV" gtid_current_pos)

# Galera / wsrep (MariaDB)
WSREP_ON=$(kv_get "$VARS_TSV" wsrep_on)
WSREP_PROVIDER_OPTIONS=$(kv_get "$VARS_TSV" wsrep_provider_options)
HAVE_GALERA=no
if [ -n "$WSREP_PROVIDER_OPTIONS" ] && [ "${WSREP_ON:-OFF}" != "OFF" ]; then
  HAVE_GALERA=yes
fi

MAX_CONNECT_ERRORS=$(kv_get "$VARS_TSV" max_connect_errors)

# Thread pool (best-effort)
THREAD_HANDLING=$(kv_get "$VARS_TSV" thread_handling)
HAVE_THREADPOOL=no
case "$THREAD_HANDLING" in
  pool-of-threads|loaded-dynamically) HAVE_THREADPOOL=yes ;;
  *) HAVE_THREADPOOL=no ;;
 esac

# Security-related variables
SKIP_NAME_RESOLVE=$(kv_get "$VARS_TSV" skip_name_resolve)
LOCAL_INFILE=$(kv_get "$VARS_TSV" local_infile)
REQUIRE_SECURE_TRANSPORT=$(kv_get "$VARS_TSV" require_secure_transport)
HAVE_SSL=$(kv_get "$VARS_TSV" have_ssl)
PERFORMANCE_SCHEMA=$(kv_get "$VARS_TSV" performance_schema)

# Derived metrics
QPS=$(rate_per_s "$QUESTIONS" "$UPTIME_S")
CPS=$(rate_per_s "$CONNECTIONS" "$UPTIME_S")
ABORT_PCT=$(pct "$ABORTED_CONNECTS" "$CONNECTIONS")
ABORTED_CLIENTS_PCT=$(pct "$ABORTED_CLIENTS" "$CONNECTIONS")
OPENED_TABLES_PS=$(rate_per_s "$OPENED_TABLES" "$UPTIME_S")

# Network throughput (best-effort)
BYTES_RECEIVED_PS=$(rate_per_s "$BYTES_RECEIVED" "$UPTIME_S")
BYTES_SENT_PS=$(rate_per_s "$BYTES_SENT" "$UPTIME_S")

# Read/write mix (best-effort)
TOTAL_READS=$(num "$COM_SELECT")
TOTAL_WRITES=$(( $(num "$COM_DELETE") + $(num "$COM_INSERT") + $(num "$COM_UPDATE") + $(num "$COM_REPLACE") ))
TOTAL_RW=$(( $(num "$TOTAL_READS") + $(num "$TOTAL_WRITES") ))
if [ "$TOTAL_RW" -gt 0 ]; then
  PCT_READS=$(pct "$TOTAL_READS" "$TOTAL_RW")
  PCT_WRITES=$((100 - $(num "$PCT_READS")))
else
  PCT_READS=""
  PCT_WRITES=""
fi

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
# Upstream-like: Qcache_hits / (Com_select + Qcache_hits)
qch=$(num "$QCACHE_HITS")
cs=$(num "$COM_SELECT")
qden=$((qch + cs))
if [ "$qden" -gt 0 ]; then
  QCACHE_EFF_PCT=$(pct "$qch" "$qden")
else
  QCACHE_EFF_PCT=""
fi

# Alternate ratio (internal): hits / (hits + inserts)
qci=$(num "$QCACHE_INSERTS")
qct=$((qch + qci))
if [ "$qct" -gt 0 ]; then
  QCACHE_HIT_PCT=$(pct "$qch" "$qct")
else
  QCACHE_HIT_PCT=""
fi

# Query cache used percent (best-effort)
qcs=$(num "$QCACHE_SIZE")
qcfm=$(num "$QCACHE_FREE_MEM")
if [ "$qcs" -gt 0 ]; then
  # upstream-like: 100 - (free/query_cache_size)*100
  QCACHE_USED_PCT=$(awk -v f="$qcfm" -v s="$qcs" 'BEGIN{printf "%.1f", 100 - (f/s)*100}')
else
  QCACHE_USED_PCT=""
fi

# Query cache prunes per day (best-effort)
QCACHE_PRUNES_PER_DAY=$(per_day "$QCACHE_LOWPRUNES" "$UPTIME_S")

# Sorting
TOTAL_SORTS=$(( $(num "$SORT_SCAN") + $(num "$SORT_RANGE") ))
if [ "$TOTAL_SORTS" -gt 0 ]; then
  SORT_MERGE_PCT=$(pct "$SORT_MERGE_PASSES" "$TOTAL_SORTS")
else
  SORT_MERGE_PCT=""
fi

# Joins without indexes (best-effort)
JOINS_WITHOUT_INDEXES=$(( $(num "$SELECT_FULL_JOIN") + $(num "$SELECT_RANGE_CHECK") ))
JOINS_WO_IDX_PER_DAY=$(per_day "$JOINS_WITHOUT_INDEXES" "$UPTIME_S")

# Table lock waited percent (best-effort)
tli=$(num "$TABLE_LOCKS_IMMEDIATE")
tlw=$(num "$TABLE_LOCKS_WAITED")
tlt=$((tli + tlw))
if [ "$tlt" -gt 0 ]; then
  TABLE_LOCKS_WAITED_PCT=$(pct "$tlw" "$tlt")
  TABLE_LOCKS_IMMEDIATE_PCT=$((100 - $(num "$TABLE_LOCKS_WAITED_PCT")))
else
  TABLE_LOCKS_WAITED_PCT=""
  TABLE_LOCKS_IMMEDIATE_PCT=""
fi

# Binlog cache pct (best-effort)
bcu=$(num "$BINLOG_CACHE_USE")
bcdu=$(num "$BINLOG_CACHE_DISK_USE")
if [ "$bcu" -gt 0 ]; then
  # pct memory = (use - disk_use) / use
  BINLOG_CACHE_PCT=$(pct "$((bcu - bcdu))" "$bcu")
else
  BINLOG_CACHE_PCT=""
fi

# Galera gcache size (best-effort) from wsrep_provider_options
GCACHE_SIZE_BYTES=0
if [ "$HAVE_GALERA" = "yes" ] && [ -n "$WSREP_PROVIDER_OPTIONS" ]; then
  gcs=$(printf "%s" "$WSREP_PROVIDER_OPTIONS" | tr ';' '\n' | awk -F= '$1 ~ /^[[:space:]]*gcache\.size[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
  if [ -n "$gcs" ]; then
    # interpret suffix K/M/G (binary-ish 1024)
    case "$gcs" in
      *K|*k) n=${gcs%[Kk]}; GCACHE_SIZE_BYTES=$(( $(num "$n") * 1024 )) ;;
      *M|*m) n=${gcs%[Mm]}; GCACHE_SIZE_BYTES=$(( $(num "$n") * 1024 * 1024 )) ;;
      *G|*g) n=${gcs%[Gg]}; GCACHE_SIZE_BYTES=$(( $(num "$n") * 1024 * 1024 * 1024 )) ;;
      *) GCACHE_SIZE_BYTES=$(num "$gcs") ;;
    esac
  fi
fi

# Query cache fragmentation percent (best-effort)
qcfb=$(num "$QCACHE_FREE_BLOCKS")
qctb=$(num "$QCACHE_TOTAL_BLOCKS")
if [ "$qctb" -gt 0 ]; then
  QCACHE_FREE_BLOCKS_PCT=$(pct "$qcfb" "$qctb")
else
  QCACHE_FREE_BLOCKS_PCT=""
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

# InnoDB buffer pool free/used/dirty percent (best-effort)
bpt=$(num "$INNODB_BP_PAGES_TOTAL")
bpf=$(num "$INNODB_BP_PAGES_FREE")
bpd=$(num "$INNODB_BP_PAGES_DIRTY")
if [ "$bpt" -gt 0 ]; then
  INNODB_BP_FREE_PCT=$(pct "$bpf" "$bpt")
  INNODB_BP_USED_PCT=$((100 - $(num "$INNODB_BP_FREE_PCT")))
  INNODB_BP_DIRTY_PCT=$(pct "$bpd" "$bpt")
else
  INNODB_BP_FREE_PCT=""
  INNODB_BP_USED_PCT=""
  INNODB_BP_DIRTY_PCT=""
fi

# InnoDB log write cache efficiency (best-effort)
lwr=$(num "$INNODB_LOG_WRITE_REQ")
lw=$(num "$INNODB_LOG_WRITES")
if [ "$lwr" -gt 0 ]; then
  # pct = (write_requests - log_writes) / write_requests
  INNODB_LOG_WRITE_EFF_PCT=$(pct "$((lwr - lw))" "$lwr")
else
  INNODB_LOG_WRITE_EFF_PCT=""
fi

# InnoDB log size pct of buffer pool (best-effort)
# For MySQL >= 8.0.30: prefer innodb_redo_log_capacity.
# Otherwise: innodb_log_file_size * innodb_log_files_in_group.
rbp=$(num "$INNODB_BP_SIZE")
redo=$(num "$INNODB_REDO_LOG_CAPACITY")
logfs=$(num "$INNODB_LOG_FILE_SIZE")
logg=$(num "$INNODB_LOG_FILES_IN_GROUP")
[ "$logg" -le 0 ] && logg=1
if [ "$rbp" -gt 0 ]; then
  if [ "$redo" -gt 0 ]; then
    INNODB_LOG_SIZE_PCT=$(awk -v r="$redo" -v bp="$rbp" 'BEGIN{printf "%d", (r*100)/bp}')
  elif [ "$logfs" -gt 0 ]; then
    INNODB_LOG_SIZE_PCT=$(awk -v lf="$logfs" -v lg="$logg" -v bp="$rbp" 'BEGIN{printf "%d", (lf*lg*100)/bp}')
  else
    INNODB_LOG_SIZE_PCT=""
  fi
else
  INNODB_LOG_SIZE_PCT=""
fi

# InnoDB buffer pool chunk alignment (best-effort; MySQL8 has chunk_size)
chunk=$(num "$INNODB_BP_CHUNK_SIZE")
inst=$(num "$INNODB_BP_INSTANCES")
if [ "$chunk" -gt 0 ] && [ "$inst" -gt 0 ] && [ "$rbp" -gt 0 ]; then
  expected=$((chunk * inst))
  if [ "$expected" -gt 0 ] && [ $((rbp % expected)) -eq 0 ]; then
    INNODB_BP_CHUNK_ALIGNED=yes
  else
    INNODB_BP_CHUNK_ALIGNED=no
  fi
else
  INNODB_BP_CHUNK_ALIGNED=""
fi

# Memory estimate (best-effort)
RAM_TOTAL=$(mem_total_bytes)
ARCH_BITS=$(getconf LONG_BIT 2>/dev/null || echo 0)
ARCH_MACHINE=$(uname -m 2>/dev/null || echo unknown)

GLOBAL_BUFFERS=$(awk -v a="$(num "$KEY_BUFFER_SIZE")" -v b="$(num "$INNODB_BP_SIZE")" -v c="$(num "$QCACHE_SIZE")" -v d="$(num "$MAX_TMP_TABLE_SIZE")" -v e="$(num "$INNODB_LOG_BUFFER_SIZE")" 'BEGIN{printf "%d", a+b+c+d+e}')
PER_THREAD_BUFFERS=$(awk -v a="$(num "$READ_BUFFER_SIZE")" -v b="$(num "$READ_RND_BUFFER_SIZE")" -v c="$(num "$SORT_BUFFER_SIZE")" -v d="$(num "$JOIN_BUFFER_SIZE")" -v e="$(num "$THREAD_STACK")" -v f="$(num "$BINLOG_CACHE_SIZE")" 'BEGIN{printf "%d", a+b+c+d+e+f}')
MAX_MEM=$(awk -v g="$GLOBAL_BUFFERS" -v p="$PER_THREAD_BUFFERS" -v mc="$(num "$MAX_CONNECTIONS")" 'BEGIN{printf "%d", g + (p*mc)}')
MAX_MEM_AT_MAX_USED=$(awk -v g="$GLOBAL_BUFFERS" -v p="$PER_THREAD_BUFFERS" -v mu="$(num "$MAX_USED_CONNECTIONS")" 'BEGIN{printf "%d", g + (p*mu)}')

# Upstream-like memory breakdown
SERVER_BUFFERS=$GLOBAL_BUFFERS
TOTAL_PER_THREAD_BUFFERS=$(awk -v p="$PER_THREAD_BUFFERS" -v mc="$(num "$MAX_CONNECTIONS")" 'BEGIN{printf "%d", p*mc}')
MAX_TOTAL_PER_THREAD_BUFFERS=$(awk -v p="$PER_THREAD_BUFFERS" -v mu="$(num "$MAX_USED_CONNECTIONS")" 'BEGIN{printf "%d", p*mu}')
TOTAL_BUFFERS=$(awk -v s="$SERVER_BUFFERS" -v t="$TOTAL_PER_THREAD_BUFFERS" 'BEGIN{printf "%d", s+t}')
MAX_TOTAL_BUFFERS=$(awk -v s="$SERVER_BUFFERS" -v t="$MAX_TOTAL_PER_THREAD_BUFFERS" 'BEGIN{printf "%d", s+t}')

# Percent of physical memory (best-effort)
if [ "$(num "$RAM_TOTAL")" -gt 0 ]; then
  PCT_MAX_USED_MEMORY=$(pct "$MAX_TOTAL_BUFFERS" "$RAM_TOTAL")
  PCT_MAX_PEAK_MEMORY=$(pct "$TOTAL_BUFFERS" "$RAM_TOTAL")
else
  PCT_MAX_USED_MEMORY=""
  PCT_MAX_PEAK_MEMORY=""
fi

# InnoDB buffer pool vs data size (best-effort)
ibp=$(num "$INNODB_BP_SIZE")
idb=$(num "$INNODB_DATA_BYTES")
if [ "$idb" -gt 0 ]; then
  if [ "$ibp" -gt 0 ]; then
    INNODB_BP_DATA_PCT=$(awk -v bp="$ibp" -v d="$idb" 'BEGIN{printf "%d", (bp*100)/d}')
  else
    INNODB_BP_DATA_PCT=""
  fi
else
  INNODB_BP_DATA_PCT=""
fi

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

# Performance schema memory
PFS_MEMORY_BYTES=$(pfs_memory_bytes)

# Sys schema presence (best-effort)
SYS_SCHEMA_INSTALLED=no
SYS_SCHEMA_VERSION=""
if mysql_query_silent "SHOW DATABASES;" | awk '($1=="sys"){found=1} END{exit(found?0:1)}'; then
  SYS_SCHEMA_INSTALLED=yes
  SYS_SCHEMA_VERSION=$(mysql_query_silent "SELECT sys_version FROM sys.version;" | head -n 1 | tr -d '\r')
fi

# Best-effort replication scan
check_replication

# ---- Output (JSON) ---------------------------------------------------------

mysqltuner_human() {
  # human-readable output; uses info/warn/ok which honor SILENT
  if [ "$SILENT" -eq 0 ]; then
    echo "MySQLTuner POSIX port (WIP)"
    echo "--------------------------------"
  fi
echo "MySQLTuner POSIX port (WIP)"
echo "--------------------------------"

# Uptime note (like upstream): <24h may skew recommendations
[ "$(num "$UPTIME_S")" -lt 86400 ] && warn "MySQL was started within the last 24 hours: recommendations may be inaccurate" || true

# Architecture check (like upstream)
if [ "$(num "$ARCH_BITS")" -eq 32 ] && [ "$(num "$RAM_TOTAL")" -gt 2147483648 ]; then
  warn "Switch to 64-bit OS - MySQL cannot currently use all of your RAM"
elif [ "$(num "$ARCH_BITS")" -gt 0 ]; then
  info "Operating on ${ARCH_BITS}-bit architecture ($ARCH_MACHINE)"
fi

info "Server version:  $SERVER_VERSION"
info "Server flavor:   $SERVER_FLAVOR"
[ -n "$SERVER_COMMENT" ] && info "Version comment: $SERVER_COMMENT"
info "Uptime (s):      $UPTIME"
# Upstream-like: summarize uptime/questions/connections + TX/RX
info "Up for: $(printf "%s" "$UPTIME_S" )s ($QUESTIONS q [${QPS} qps], $CONNECTIONS conn, TX: $(bytes_h "$BYTES_SENT"), RX: $(bytes_h "$BYTES_RECEIVED"))"

section "Storage Engine Statistics"
[ -n "$ENGINES_ENABLED_CSV" ] && info "Enabled engines: $ENGINES_ENABLED_CSV" || true
# Print top engines by size (best-effort)
if printf '%s' "$ENGINE_SIZES_JSON" | jq -e . >/dev/null 2>&1; then
  n=$(printf '%s' "$ENGINE_SIZES_JSON" | jq -r 'length')
  if [ "$(num "$n")" -eq 0 ]; then
    info "No user tables found (information_schema.TABLES is empty for non-system schemas)"
  else
    printf '%s' "$ENGINE_SIZES_JSON" | jq -r '.[] | "[INFO] " + .engine + ": " + (.total_bytes|tostring) + " bytes (tables=" + (.table_count|tostring) + ")"' | head -n 12
  fi
fi

section "Tables"
info "Fragmented tables: $FRAGMENTED_TABLES_COUNT"
if [ "$(num "$FRAGMENTED_TABLES_COUNT")" -gt 0 ]; then
  # show top 10 by data_free
  printf '%s' "$FRAGMENTED_TABLES_JSON" | jq -r '.[:10][] | "[WARN] Fragmented: " + .schema + "." + .table + " engine=" + .engine + " data_free=" + (.data_free_bytes|tostring) + " used=" + (.used_bytes|tostring)'
fi

info "Tables without PRI/UNI key: $TABLES_NO_PK_COUNT"
if [ "$(num "$TABLES_NO_PK_COUNT")" -gt 0 ]; then
  printf '%s' "$TABLES_NO_PK_JSON" | jq -r '.[:10][] | "[WARN] No PK/UK: " + .schema + "." + .table'
fi

info "Large tables without secondary indexes (>1GiB): $LARGE_TABLES_NO_SEC_INDEX_COUNT"
if [ "$(num "$LARGE_TABLES_NO_SEC_INDEX_COUNT")" -gt 0 ]; then
  printf '%s' "$LARGE_TABLES_NO_SEC_INDEX_JSON" | jq -r '.[:10][] | "[WARN] Large no-sec-index: " + .schema + "." + .table + " size=" + (.total_bytes|tostring)'
fi

info "Foreign key type mismatches: $FK_MISMATCHES_COUNT"
if [ "$(num "$FK_MISMATCHES_COUNT")" -gt 0 ]; then
  printf '%s' "$FK_MISMATCHES_JSON" | jq -r '.[:10][] | "[WARN] FK mismatch: " + .mismatch'
fi

info "Non-InnoDB base tables: $NON_INNODB_TABLES_COUNT"
if [ "$(num "$NON_INNODB_TABLES_COUNT")" -gt 0 ]; then
  printf '%s' "$NON_INNODB_TABLES_JSON" | jq -r '.[:10][] | "[WARN] Non-InnoDB: " + .schema + "." + .table + " engine=" + .engine'
fi

info "Unconstrained *_id columns: $UNCONSTRAINED_ID_COUNT"
if [ "$(num "$UNCONSTRAINED_ID_COUNT")" -gt 0 ]; then
  # exclude PKs named ${table}_id (upstream behavior)
  printf '%s' "$UNCONSTRAINED_ID_JSON" | jq -r '.[] | select(.column != (.table + "_id")) | "[WARN] Unconstrained _id: " + .schema + "." + .table + "." + .column' | head -n 10
fi

info "FKs with ON DELETE CASCADE: $FK_CASCADE_COUNT"
if [ "$(num "$FK_CASCADE_COUNT")" -gt 0 ]; then
  printf '%s' "$FK_CASCADE_JSON" | jq -r '.[:10][] | "[INFO] ON DELETE CASCADE: " + .schema + "." + .table + "." + .column + " -> " + .ref_table + "." + .ref_column'
fi

info "Empty or view-only schemas: $EMPTY_SCHEMAS_COUNT"
if [ "$(num "$EMPTY_SCHEMAS_COUNT")" -gt 0 ]; then
  printf '%s' "$EMPTY_SCHEMAS_JSON" | jq -r '.[:10][] | if (.base_tables==0 and .views==0) then "[INFO] Schema " + .schema + " is empty (no tables or views)" else "[INFO] Schema " + .schema + " contains only views (" + (.views|tostring) + " views)" end'
fi

info "Columns with NULL enabled: $NULLABLE_COLS_COUNT"
[ "$(num "$NULLABLE_COLS_COUNT")" -gt 20 ] && warn "There are $NULLABLE_COLS_COUNT columns with NULL enabled. Consider using NOT NULL where possible." || true

section "Naming Conventions"
info "Table naming issues:  $NAMING_TABLE_ISSUES_COUNT"
if [ "$(num "$NAMING_TABLE_ISSUES_COUNT")" -gt 0 ]; then
  printf '%s' "$NAMING_TABLE_ISSUES_JSON" | jq -r '.[:10][] | "[WARN] Table " + .schema + "." + .table + ": " + (if .plural then "plural name" else "" end) + (if (.plural and .camel) then ", " else "" end) + (if .camel then "non-snake_case" else "" end)'
fi
info "Column naming issues: $NAMING_COL_ISSUES_COUNT"
if [ "$(num "$NAMING_COL_ISSUES_COUNT")" -gt 0 ]; then
  printf '%s' "$NAMING_COL_ISSUES_JSON" | jq -r '.[:10][] | "[INFO] Column " + .schema + "." + .table + "." + .column + ": " + (if .camel then "non-snake_case" else "" end) + (if (.camel and .bool_bad) then ", " else "" end) + (if .bool_bad then "bool missing prefix" else "" end) + (if ((.camel or .bool_bad) and .dt_bad) then ", " else "" end) + (if .dt_bad then "datetime missing suffix" else "" end)'
fi

section "Charset / Collation"
info "Non-UTF8 character columns: $NON_UTF8_COLS_COUNT"
if [ "$(num "$NON_UTF8_COLS_COUNT")" -gt 0 ]; then
  printf '%s' "$NON_UTF8_COLS_JSON" | jq -r '.[:10][] | "[WARN] Non-UTF8: " + .schema + "." + .table + "." + .column + " charset=" + (.charset//"") + " collation=" + (.collation//"")'
fi

section "Primary Key Modeling"
info "PK naming issues: $PK_NAMING_ISSUES_COUNT"
if [ "$(num "$PK_NAMING_ISSUES_COUNT")" -gt 0 ]; then
  printf '%s' "$PK_NAMING_ISSUES_JSON" | jq -r '.[:10][] | "[WARN] Table " + .schema + "." + .table + ": PK '" + .column + "' not named id/" + .table + "_id"'
fi
info "UUID PK not optimized (use BINARY(16)): $UUID_PK_ISSUES_COUNT"
if [ "$(num "$UUID_PK_ISSUES_COUNT")" -gt 0 ]; then
  printf '%s' "$UUID_PK_ISSUES_JSON" | jq -r '.[:10][] | "[WARN] UUID PK: " + .schema + "." + .table + "." + .column + " type=" + .column_type'
fi
info "PK not recommended surrogate (BIGINT UNSIGNED AUTO_INCREMENT): $PK_SURROGATE_ISSUES_COUNT"
if [ "$(num "$PK_SURROGATE_ISSUES_COUNT")" -gt 0 ]; then
  printf '%s' "$PK_SURROGATE_ISSUES_JSON" | jq -r '.[:10][] | "[WARN] PK type: " + .schema + "." + .table + "." + .column + " type=" + .column_type'
fi

section "Fulltext"
info "Fulltext columns: $FULLTEXT_COLS_COUNT"
if [ "$(num "$FULLTEXT_COLS_COUNT")" -gt 0 ]; then
  printf '%s' "$FULLTEXT_COLS_JSON" | jq -r '.[:10][] | "[INFO] FULLTEXT: " + .schema + "." + .table + "." + .column'
fi

section "MySQL 8.0+ Modeling"
# JSON indexability check
info "JSON columns without generated cols for indexing: $JSON_NO_GEN_COUNT"
if [ "$(num "$JSON_NO_GEN_COUNT")" -gt 0 ]; then
  printf '%s' "$JSON_NO_GEN_JSON" | jq -r '.[:10][] | "[INFO] JSON without generated cols: " + .schema + "." + .table + "." + .column'
fi

# Invisible indexes
info "Invisible indexes: $INVISIBLE_IDX_COUNT"
if [ "$(num "$INVISIBLE_IDX_COUNT")" -gt 0 ]; then
  printf '%s' "$INVISIBLE_IDX_JSON" | jq -r '.[:10][] | "[INFO] INVISIBLE index: " + .schema + "." + .table + "." + .index'
fi

# CHECK constraints (informational)
if [ "$(num "$CHECK_CONSTRAINTS_COUNT")" -gt 0 ]; then
  info "CHECK constraints: $CHECK_CONSTRAINTS_COUNT"
else
  info "CHECK constraints: 0"
fi

section "Plugins"
info "Active plugins (excluding INFORMATION_SCHEMA): $PLUGINS_ACTIVE_COUNT"
if [ "$(num "$PLUGINS_ACTIVE_COUNT")" -gt 0 ]; then
  printf '%s' "$PLUGINS_ACTIVE_JSON" | jq -r '.[:20][] | "[INFO] Plugin: " + .name + " v" + (.version//"") + " type=" + (.type//"")'
fi

section "Databases"
info "User databases: $DATABASES_COUNT"
info "All user schemas: tables=$DB_TABLES_COUNT views=$DB_VIEWS_COUNT indexes=$DB_INDEXES_COUNT"
info "All user schemas: rows=$DB_TOTAL_ROWS data=$(bytes_h "$DB_DATA_BYTES") index=$(bytes_h "$DB_INDEX_BYTES") total=$(bytes_h "$DB_TOTAL_BYTES")"
info "Charsets: $DB_CHARSETS_COUNT  Collations: $DB_COLLATIONS_COUNT  Engines: $DB_ENGINES_COUNT"
if [ "$(num "$DB_BREAKDOWN_COUNT")" -gt 0 ]; then
  info "Per-database breakdown: $DB_BREAKDOWN_COUNT"
  printf '%s' "$DB_BREAKDOWN_JSON" | jq -r '.[:10][] | "[INFO] DB " + .schema + ": tables=" + (.tables|tostring) + " views=" + (.views|tostring) + " rows=" + (.rows|tostring) + " total=" + (.total_bytes|tostring)'
fi

info "Indexes per database: $DB_INDEX_BREAKDOWN_COUNT"
if [ "$(num "$DB_INDEX_BREAKDOWN_COUNT")" -gt 0 ]; then
  printf '%s' "$DB_INDEX_BREAKDOWN_JSON" | jq -r '.[:10][] | "[INFO] DB " + .schema + ": indexes=" + (.indexes|tostring)'
fi

info "Largest tables (top 20): $LARGEST_TABLES_COUNT"
if [ "$(num "$LARGEST_TABLES_COUNT")" -gt 0 ]; then
  printf '%s' "$LARGEST_TABLES_JSON" | jq -r '.[:10][] | "[INFO] Table " + .schema + "." + .table + " engine=" + (.engine//"") + " rows=" + (.rows|tostring) + " total=" + (.total_bytes|tostring)'
fi

section "Views / Routines / Triggers"
info "Views: $VIEWS_COUNT"
[ "$(num "$VIEWS_COUNT")" -gt 0 ] && printf '%s' "$VIEWS_JSON" | jq -r '.[:10][] | "[INFO] View " + .schema + "." + .view' || true
info "Routines: $ROUTINES_COUNT"
[ "$(num "$ROUTINES_COUNT")" -gt 0 ] && printf '%s' "$ROUTINES_JSON" | jq -r '.[:10][] | "[INFO] Routine " + .schema + "." + .routine + " type=" + .type' || true
info "Triggers: $TRIGGERS_COUNT"
[ "$(num "$TRIGGERS_COUNT")" -gt 0 ] && printf '%s' "$TRIGGERS_JSON" | jq -r '.[:10][] | "[INFO] Trigger " + .schema + "." + .trigger + " on " + .table + " " + .timing + " " + .event' || true

section "Table Column Metrics"
if [ "$TBSTAT" -eq 1 ]; then
  info "Tables (detailed): $TABLE_METRICS_COUNT"
  # print first few only to avoid flooding
  # tree-like per-DB/table output (limited)
  printf '%s' "$TABLE_METRICS_JSON" | jq -r 'group_by(.schema) | map({schema:.[0].schema, tables:.}) | .[] | "Database: " + .schema + "\n" + ( .tables[:50] | map(" +-- TABLE: " + .table + "\n     +-- TYPE: " + (.engine//"") + "\n" + ( if ((.indexes|length)>0) then (.indexes | map("     +-- Index " + .name + " - Cols: " + (.columns|join(",")) + " - Type: " + (.type//"")) | join("\n")) else "[WARN] Table " + .schema + "." + .table + " has no index defined" end ) ) | join("\n") )'
fi

section "Indexes"
info "Indexes: $INDEXES_COUNT"
info "Tables with no indexes: $TABLES_NO_INDEX_COUNT"
[ "$(num "$TABLES_NO_INDEX_COUNT")" -gt 0 ] && printf '%s' "$TABLES_NO_INDEX_JSON" | jq -r '.[:10][] | "[WARN] No index: " + .schema + "." + .table' || true
info "Duplicate indexes (same cols/type/unique): $DUPLICATE_INDEXES_COUNT"
[ "$(num "$DUPLICATE_INDEXES_COUNT")" -gt 0 ] && printf '%s' "$DUPLICATE_INDEXES_JSON" | jq -r '.[:10][] | "[WARN] Duplicate indexes on " + .schema + "." + .table + ": " + (.indexes|join(",")) + " cols=" + (.columns|join(","))' || true

info "Same columns but different uniqueness: $SAME_COLS_DIFF_UNIQ_COUNT"
[ "$(num "$SAME_COLS_DIFF_UNIQ_COUNT")" -gt 0 ] && printf '%s' "$SAME_COLS_DIFF_UNIQ_JSON" | jq -r '.[:10][] | "[WARN] Non-unique index redundant (unique exists) on " + .schema + "." + .table + " cols=" + (.columns|join(",")) + " unique=" + (.unique_indexes|join(",")) + " non_unique=" + (.non_unique_indexes|join(","))' || true

info "Redundant (prefix) indexes: $REDUNDANT_INDEXES_COUNT"
[ "$(num "$REDUNDANT_INDEXES_COUNT")" -gt 0 ] && printf '%s' "$REDUNDANT_INDEXES_JSON" | jq -r '.[:10][] | "[WARN] Redundant index " + .schema + "." + .table + "." + .redundant + " covered by " + .covered_by + (if (.non_unique|tonumber)==0 then " (UNIQUE)" else "" end)' || true

info "UNIQUE index redundant to PRIMARY KEY: $UNIQUE_REDUNDANT_PK_COUNT"
[ "$(num "$UNIQUE_REDUNDANT_PK_COUNT")" -gt 0 ] && printf '%s' "$UNIQUE_REDUNDANT_PK_JSON" | jq -r '.[:10][] | "[WARN] UNIQUE index " + .schema + "." + .table + "." + .unique_index + " duplicates PRIMARY KEY"' || true

# Recommendations
[ "$(num "$TABLES_NO_INDEX_COUNT")" -gt 0 ] && warn "Some tables have no indexes (see warnings above). Add at least a PRIMARY KEY." || true
[ "$(num "$DUPLICATE_INDEXES_COUNT")" -gt 0 ] && warn "Duplicate indexes detected. Consider dropping redundant ones." || true
[ "$(num "$SAME_COLS_DIFF_UNIQ_COUNT")" -gt 0 ] && warn "Non-unique indexes detected where an identical UNIQUE index exists. Consider dropping the non-unique ones." || true
[ "$(num "$REDUNDANT_INDEXES_COUNT")" -gt 0 ] && warn "Redundant prefix indexes detected. Consider dropping narrower ones if covered by wider indexes." || true
[ "$(num "$UNIQUE_REDUNDANT_PK_COUNT")" -gt 0 ] && warn "UNIQUE indexes duplicating PRIMARY KEY detected. Consider dropping them." || true

section "Replication"
info "Galera Synchronous replication: $HAVE_GALERA"
[ "$HAVE_GALERA" = "yes" ] && info "Galera GCache Max memory usage: $(bytes_h "$GCACHE_SIZE_BYTES")" || true
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
info "Questions:   $QUESTIONS (QPS: $QPS)"
info "Connections: $CONNECTIONS (CPS: $CPS)"
info "TX total:    $(bytes_h "$BYTES_SENT") (~${BYTES_SENT_PS} B/s)"
info "RX total:    $(bytes_h "$BYTES_RECEIVED") (~${BYTES_RECEIVED_PS} B/s)"

section "Read / Write"
info "Com_select:  $COM_SELECT"
info "Com_insert:  $COM_INSERT"
info "Com_update:  $COM_UPDATE"
info "Com_delete:  $COM_DELETE"
info "Com_replace: $COM_REPLACE"
if [ -n "${PCT_READS:-}" ]; then
  info "Reads/Writes: ${PCT_READS}% / ${PCT_WRITES}%"
fi

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
if [ "$HAVE_THREADPOOL" = "yes" ]; then
  info "Thread cache not used with thread pool enabled"
else
  if [ "$(num "$THREAD_CACHE_SIZE")" -eq 0 ]; then
    warn "Thread cache is disabled"
    warn "Set thread_cache_size to 4 as a starting value"
  fi
  if [ -n "${THREAD_CACHE_HIT_PCT:-}" ]; then
    info "Thread cache hit rate: ${THREAD_CACHE_HIT_PCT}%"
    [ "$(num "$THREAD_CACHE_SIZE")" -gt 0 ] && [ "$THREAD_CACHE_HIT_PCT" -le 50 ] && warn "Low thread cache hit rate (${THREAD_CACHE_HIT_PCT}%)" || true
  fi
fi
info "Aborted_connects:     $ABORTED_CONNECTS (${ABORT_PCT}%)"
[ "$(num "$ABORTED_CONNECTS")" -gt 0 ] && [ "$ABORT_PCT" -ge 5 ] && warn "High aborted connect rate (${ABORT_PCT}%)"
info "Aborted_clients:      $ABORTED_CLIENTS (${ABORTED_CLIENTS_PCT}%)"
[ "$(num "$ABORTED_CLIENTS")" -gt 0 ] && [ "$ABORTED_CLIENTS_PCT" -ge 5 ] && warn "High aborted clients rate (${ABORTED_CLIENTS_PCT}%)" || true

section "Connection Errors"
info "Connection_errors_accept:          $CONN_ERRORS_ACCEPT"
info "Connection_errors_internal:        $CONN_ERRORS_INTERNAL"
info "Connection_errors_max_connections: $CONN_ERRORS_MAXCONN"
info "Connection_errors_peer_address:    $CONN_ERRORS_PEERADDR"
info "Connection_errors_select:          $CONN_ERRORS_SELECT"
info "Connection_errors_tcpwrap:         $CONN_ERRORS_TCPWRAP"

ce=$(( $(num "$CONN_ERRORS_ACCEPT") + $(num "$CONN_ERRORS_INTERNAL") + $(num "$CONN_ERRORS_MAXCONN") + $(num "$CONN_ERRORS_PEERADDR") + $(num "$CONN_ERRORS_SELECT") + $(num "$CONN_ERRORS_TCPWRAP") ))
[ "$ce" -gt 0 ] && warn "Connection errors detected ($ce total)" || ok "No connection errors detected"

section "Memory"
info "key_buffer_size:         $(bytes_h "$KEY_BUFFER_SIZE")"
info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"
info "query_cache_size:        $(bytes_h "$QCACHE_SIZE")"
info "Global buffers:          $(bytes_h "$GLOBAL_BUFFERS")"
info "  max_tmp_table_size:    $(bytes_h "$MAX_TMP_TABLE_SIZE")"
info "  innodb_log_buffer_size: $(bytes_h "$INNODB_LOG_BUFFER_SIZE")"
info "Per-thread buffers:      $(bytes_h "$PER_THREAD_BUFFERS")"
info "  read_buffer_size:      $(bytes_h "$READ_BUFFER_SIZE")"
info "  read_rnd_buffer_size:  $(bytes_h "$READ_RND_BUFFER_SIZE")"
info "  sort_buffer_size:      $(bytes_h "$SORT_BUFFER_SIZE")"
info "  join_buffer_size:      $(bytes_h "$JOIN_BUFFER_SIZE")"
info "  thread_stack:          $(bytes_h "$THREAD_STACK")"
info "  binlog_cache_size:     $(bytes_h "$BINLOG_CACHE_SIZE")"
info "Max memory estimate:     $(bytes_h "$MAX_MEM") (global + per-thread*max_connections)"
info "Max memory @ max-used:   $(bytes_h "$MAX_MEM_AT_MAX_USED") (global + per-thread*Max_used_connections)"
info "Server buffers:          $(bytes_h "$SERVER_BUFFERS")"
info "Total per-thread buffers: $(bytes_h "$TOTAL_PER_THREAD_BUFFERS")"
info "Max per-thread buffers:   $(bytes_h "$MAX_TOTAL_PER_THREAD_BUFFERS") (at Max_used_connections)"
info "Total buffers:           $(bytes_h "$TOTAL_BUFFERS")"
info "Max total buffers:       $(bytes_h "$MAX_TOTAL_BUFFERS") (at Max_used_connections)"

# Upstream-like memory summary
if [ -n "${PCT_MAX_USED_MEMORY:-}" ]; then
  info "Maximum reached memory usage:  $(bytes_h "$MAX_TOTAL_BUFFERS") (${PCT_MAX_USED_MEMORY}% of installed RAM)"
  [ "$(num "$PCT_MAX_USED_MEMORY")" -gt 85 ] && warn "Maximum reached memory usage is high (${PCT_MAX_USED_MEMORY}% of RAM)" || true
fi
if [ -n "${PCT_MAX_PEAK_MEMORY:-}" ]; then
  info "Maximum possible memory usage: $(bytes_h "$TOTAL_BUFFERS") (${PCT_MAX_PEAK_MEMORY}% of installed RAM)"
  if [ "$(num "$PCT_MAX_PEAK_MEMORY")" -gt 85 ]; then
    warn "Maximum possible memory usage is high (${PCT_MAX_PEAK_MEMORY}% of RAM)"
    warn "Reduce your overall MySQL memory footprint for system stability"
  fi
fi
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
info "Qcache_free_blocks:       $QCACHE_FREE_BLOCKS"
info "Qcache_total_blocks:      $QCACHE_TOTAL_BLOCKS"
if [ -n "${QCACHE_FREE_BLOCKS_PCT:-}" ]; then
  info "Query cache frag (free blocks): ${QCACHE_FREE_BLOCKS_PCT}%"
fi
if [ -n "${QCACHE_USED_PCT:-}" ]; then
  info "Query cache used:          ${QCACHE_USED_PCT}%"
fi
info "Query cache prunes/day:   $QCACHE_PRUNES_PER_DAY"

if [ "$(num "$QCACHE_SIZE")" -gt 0 ]; then
  if [ "$MYSQL_VER_MAJ" -ge 8 ]; then
    warn "query_cache_size > 0 on MySQL 8+ (query cache removed upstream; check compatibility)"
  fi
  if [ -n "${QCACHE_EFF_PCT:-}" ]; then
    info "Query cache efficiency:   ${QCACHE_EFF_PCT}%"
    [ "$(num "$QCACHE_EFF_PCT")" -lt 20 ] && warn "Low query cache efficiency (${QCACHE_EFF_PCT}%)" || true
  fi
  if [ -n "${QCACHE_HIT_PCT:-}" ]; then
    info "Query cache hit/(hit+ins): ${QCACHE_HIT_PCT}%"
  fi
  [ "$(num "$QCACHE_LOWPRUNES")" -gt 0 ] && warn "Query cache prunes detected ($QCACHE_LOWPRUNES)" || true
  if [ -n "${QCACHE_FREE_BLOCKS_PCT:-}" ] && [ "$(num "$QCACHE_FREE_BLOCKS_PCT")" -ge 20 ]; then
    warn "High query cache fragmentation (${QCACHE_FREE_BLOCKS_PCT}% free blocks)"
  fi
else
  ok "Query cache disabled"
fi

section "Sorts"
info "Sort_merge_passes: $SORT_MERGE_PASSES"
info "Sort_scan:         $SORT_SCAN"
info "Sort_range:        $SORT_RANGE"
info "Sort_rows:         $SORT_ROWS"

if [ "$(num "$TOTAL_SORTS")" -eq 0 ]; then
  ok "No sort requiring temporary tables"
elif [ -n "${SORT_MERGE_PCT:-}" ]; then
  info "Sorts requiring temporary tables: ${SORT_MERGE_PCT}% ($SORT_MERGE_PASSES temp sorts / $TOTAL_SORTS sorts)"
  if [ "$(num "$SORT_MERGE_PCT")" -gt 10 ]; then
    warn "High sorts requiring temporary tables (${SORT_MERGE_PCT}%)"
    warn "Consider increasing sort_buffer_size (current: $(bytes_h "$SORT_BUFFER_SIZE"))"
    warn "Consider increasing read_rnd_buffer_size (current: $(bytes_h "$READ_RND_BUFFER_SIZE"))"
  fi
else
  info "Sorts: total=$TOTAL_SORTS"
fi

section "Joins"
info "Select_full_join:       $SELECT_FULL_JOIN"
info "Select_full_range_join: $SELECT_FULL_RANGE_JOIN"
info "Select_range_check:     $SELECT_RANGE_CHECK"
info "Joins without indexes:  $JOINS_WITHOUT_INDEXES (~${JOINS_WO_IDX_PER_DAY}/day)"
if [ "$(num "$JOINS_WO_IDX_PER_DAY")" -gt 250 ]; then
  warn "Joins without indexes per day is high ($JOINS_WO_IDX_PER_DAY/day)"
  [ "$(num "$JOIN_BUFFER_SIZE")" -lt 4194304 ] && warn "Consider increasing join_buffer_size (current: $(bytes_h "$JOIN_BUFFER_SIZE"))" || true
fi
[ "$(num "$SELECT_FULL_JOIN")" -gt 0 ] && warn "Select_full_join > 0 (joins without indexes detected)" || true
[ "$(num "$SELECT_RANGE_CHECK")" -gt 0 ] && warn "Select_range_check > 0 (joins without keys in some cases)" || true

section "Table Locks"
info "Table_locks_immediate: $TABLE_LOCKS_IMMEDIATE"
info "Table_locks_waited:    $TABLE_LOCKS_WAITED"
if [ -n "${TABLE_LOCKS_IMMEDIATE_PCT:-}" ]; then
  info "Table locks immediate: ${TABLE_LOCKS_IMMEDIATE_PCT}%"
  [ "$(num "$TABLE_LOCKS_IMMEDIATE_PCT")" -lt 95 ] && warn "Table locks acquired immediately <95% (${TABLE_LOCKS_IMMEDIATE_PCT}%)" || true
fi
if [ -n "${TABLE_LOCKS_WAITED_PCT:-}" ]; then
  info "Table locks waited:    ${TABLE_LOCKS_WAITED_PCT}%"
  [ "$(num "$TABLE_LOCKS_WAITED_PCT")" -ge 1 ] && warn "Table_locks_waited > 0 (contention detected)" || true
fi

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
info "Slow queries %:   ${SLOW_QUERIES_PCT}%"
info "Slow queries/day: $SLOW_QUERIES_PER_DAY"
[ "$(num "$SLOW_QUERIES_PCT")" -ge 5 ] && warn "High slow query percentage (${SLOW_QUERIES_PCT}%)" || true

section "Temporary Tables"
info "Created_tmp_tables:      $CREATED_TMP_TABLES"
info "Created_tmp_disk_tables: $CREATED_TMP_DISK_TABLES"
info "tmp_table_size:          $(bytes_h "$TMP_TABLE_SIZE")"
info "max_heap_table_size:     $(bytes_h "$MAX_HEAP_TABLE_SIZE")"
info "effective_tmp_table_size: $(bytes_h "$MAX_TMP_TABLE_SIZE") (min of tmp_table_size/max_heap_table_size)"

tmp=$(num "$CREATED_TMP_TABLES")
tmpdisk=$(num "$CREATED_TMP_DISK_TABLES")
if [ "$tmp" -gt 0 ]; then
  TMP_DISK_PCT=$(pct "$tmpdisk" "$tmp")
else
  TMP_DISK_PCT=""
fi

if [ -n "${TMP_DISK_PCT:-}" ]; then
  info "Tmp tables on disk: ${TMP_DISK_PCT}% (${CREATED_TMP_DISK_TABLES}/${CREATED_TMP_TABLES})"
  if [ "$(num "$TMP_DISK_PCT")" -gt 25 ] && [ "$(num "$MAX_TMP_TABLE_SIZE")" -lt 268435456 ]; then
    warn "Temporary tables created on disk high (${TMP_DISK_PCT}%) and effective tmp table size < 256MiB"
  elif [ "$(num "$TMP_DISK_PCT")" -gt 25 ] && [ "$(num "$MAX_TMP_TABLE_SIZE")" -ge 268435456 ]; then
    warn "Temporary tables created on disk high (${TMP_DISK_PCT}%) (tmp table size already large)"
  fi
fi

section "InnoDB"
[ -n "$INNODB_BP_SIZE" ] && info "innodb_buffer_pool_size: $(bytes_h "$INNODB_BP_SIZE")"
[ -n "$INNODB_DATA_BYTES" ] && info "InnoDB data+index size:  $(bytes_h "$INNODB_DATA_BYTES")"
if [ -n "${INNODB_BP_DATA_PCT:-}" ]; then
  info "BP / data size:         ${INNODB_BP_DATA_PCT}%"
  [ "$(num "$INNODB_BP_DATA_PCT")" -lt 100 ] && warn "InnoDB buffer pool is smaller than InnoDB data+index size" || true
fi
[ -n "$INNODB_BP_INSTANCES" ] && info "innodb_buffer_pool_instances: $INNODB_BP_INSTANCES"
# Upstream hint: if BP <= 1GiB then instances should be 1
ibp=$(num "$INNODB_BP_SIZE")
inst=$(num "$INNODB_BP_INSTANCES")
if [ "$ibp" -gt 0 ] && [ "$ibp" -le 1073741824 ] && [ "$inst" -ne 1 ]; then
  warn "InnoDB buffer pool <= 1GiB and innodb_buffer_pool_instances != 1"
fi

[ -n "$INNODB_BP_CHUNK_SIZE" ] && info "innodb_buffer_pool_chunk_size: $(bytes_h "$INNODB_BP_CHUNK_SIZE")"
if [ -n "${INNODB_BP_CHUNK_ALIGNED:-}" ]; then
  [ "$INNODB_BP_CHUNK_ALIGNED" = "yes" ] && ok "innodb_buffer_pool_size aligned with chunk_size * instances" || warn "innodb_buffer_pool_size not aligned with chunk_size * instances"
fi
[ -n "$INNODB_FILE_PER_TABLE" ] && info "innodb_file_per_table: $INNODB_FILE_PER_TABLE"
[ -n "$INNODB_FLUSH_METHOD" ] && info "innodb_flush_method: $INNODB_FLUSH_METHOD"
[ -n "$INNODB_FLUSH_LOG_AT_TRX" ] && info "innodb_flush_log_at_trx_commit: $INNODB_FLUSH_LOG_AT_TRX"
[ -n "$INNODB_LOG_BUFFER_SIZE" ] && info "innodb_log_buffer_size: $(bytes_h "$INNODB_LOG_BUFFER_SIZE")"

if [ "$(num "$INNODB_REDO_LOG_CAPACITY")" -gt 0 ]; then
  info "innodb_redo_log_capacity: $(bytes_h "$INNODB_REDO_LOG_CAPACITY")"
elif [ "$(num "$INNODB_LOG_FILE_SIZE")" -gt 0 ]; then
  info "innodb_log_file_size: $(bytes_h "$INNODB_LOG_FILE_SIZE")"
  [ "$(num "$INNODB_LOG_FILES_IN_GROUP")" -gt 0 ] && info "innodb_log_files_in_group: $INNODB_LOG_FILES_IN_GROUP" || true
fi

if [ -n "${INNODB_LOG_SIZE_PCT:-}" ]; then
  info "InnoDB log size % of BP: ${INNODB_LOG_SIZE_PCT}%"
  if [ "$(num "$INNODB_LOG_SIZE_PCT")" -lt 20 ] || [ "$(num "$INNODB_LOG_SIZE_PCT")" -gt 30 ]; then
    warn "InnoDB log size ratio out of 20-30% range (${INNODB_LOG_SIZE_PCT}%)"
  fi
fi

[ -n "$INNODB_LOG_WRITE_REQ" ] && info "Innodb_log_write_requests: $INNODB_LOG_WRITE_REQ"
[ -n "$INNODB_LOG_WRITES" ] && info "Innodb_log_writes:         $INNODB_LOG_WRITES"
if [ "$lw" -gt "$lwr" ]; then
  info "InnoDB Write Log efficiency: metrics not reliable (writes > write requests)"
else
  if [ -n "${INNODB_LOG_WRITE_EFF_PCT:-}" ]; then
    info "InnoDB log write efficiency: ${INNODB_LOG_WRITE_EFF_PCT}%"
    [ "$(num "$INNODB_LOG_WRITE_EFF_PCT")" -lt 90 ] && warn "Low InnoDB log write efficiency (${INNODB_LOG_WRITE_EFF_PCT}%)" || true
  fi
fi
[ -n "$INNODB_LOG_WAITS" ] && info "Innodb_log_waits:          $INNODB_LOG_WAITS"
[ "$(num "$INNODB_LOG_WAITS")" -gt 0 ] && warn "InnoDB log waits detected ($INNODB_LOG_WAITS) - consider larger innodb_log_buffer_size or faster disk" || true

# buffer pool occupancy
if [ "$(num "$INNODB_BP_PAGES_TOTAL")" -gt 0 ]; then
  info "Innodb_buffer_pool_pages_total: $INNODB_BP_PAGES_TOTAL"
  info "Innodb_buffer_pool_pages_free:  $INNODB_BP_PAGES_FREE (${INNODB_BP_FREE_PCT}% free)"
  [ -n "${INNODB_BP_USED_PCT:-}" ] && info "InnoDB buffer used:            ${INNODB_BP_USED_PCT}%" || true
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
if [ "$bpr" -gt "$bprr" ]; then
  info "InnoDB Read buffer efficiency: metrics not reliable (reads > read requests)"
else
  if [ "$bprr" -gt 0 ]; then
    hit=$((bprr - bpr)); [ "$hit" -lt 0 ] && hit=0
    hp=$(pct "$hit" "$bprr")
    info "InnoDB BP hit rate: ${hp}%"
    [ "$hp" -lt 95 ] && warn "Low InnoDB buffer pool hit rate (${hp}%)" || ok "InnoDB buffer pool hit rate (${hp}%)"
  fi
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
[ -n "$TOTAL_TABLES" ] && info "Total tables (I_S):       $TOTAL_TABLES"

# Like upstream: table_definition_cache should be >= number of tables (or -1 autosizing)
tdc=$(num "$TABLE_DEF_CACHE")
nt=$(num "$TOTAL_TABLES")
if [ "$tdc" -eq -1 ]; then
  info "table_definition_cache is in autosizing mode (-1)"
elif [ "$tdc" -gt 0 ] && [ "$nt" -gt 0 ] && [ "$tdc" -lt "$nt" ]; then
  warn "table_definition_cache ($tdc) is less than number of tables ($nt)"
fi
# crude heuristic: if we open lots of tables per second, cache might be too small
# table cache hit rate (best-effort)
th=$(num "$TABLE_OPEN_CACHE_HITS")
tm=$(num "$TABLE_OPEN_CACHE_MISSES")
if [ "$th" -gt 0 ] || [ "$tm" -gt 0 ]; then
  ttot=$((th + tm))
  if [ "$ttot" -gt 0 ]; then
    TABLE_CACHE_HIT_PCT=$(pct "$th" "$ttot")
    info "Table cache hit rate:    ${TABLE_CACHE_HIT_PCT}% ($th hits / $ttot requests)"
    [ "$TABLE_CACHE_HIT_PCT" -lt 20 ] && warn "Low table cache hit rate (${TABLE_CACHE_HIT_PCT}%)" || true
  fi
else
  # fallback heuristic when hits/misses not available
  ot=$(num "$OPEN_TABLES")
  od=$(num "$OPENED_TABLES")
  if [ "$od" -gt 0 ]; then
    TABLE_CACHE_HIT_PCT=$(pct "$ot" "$od")
    info "Table cache hit rate:    ${TABLE_CACHE_HIT_PCT}% ($ot hits / $od requests)"
  else
    TABLE_CACHE_HIT_PCT=""
  fi
fi

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
if [ "${LOG_BIN:-}" = "OFF" ] || [ "${LOG_BIN:-}" = "0" ]; then
  info "Binary logging is disabled"
else
  # MySQL: gtid_mode; MariaDB: gtid_current_pos
  gtid_note="OFF"
  [ -n "$GTID_MODE" ] && gtid_note="$GTID_MODE"
  [ -n "$GTID_CURRENT_POS" ] && gtid_note="ON"
  info "Binary logging is enabled (GTID MODE: $gtid_note)"
fi

[ -n "$LOG_BIN" ] && info "log_bin: $LOG_BIN"
[ -n "$BINLOG_FORMAT" ] && info "binlog_format: $BINLOG_FORMAT"
[ -n "$SYNC_BINLOG" ] && info "sync_binlog: $SYNC_BINLOG"
[ -n "$GTID_MODE" ] && info "gtid_mode: $GTID_MODE"
[ -n "$GTID_CURRENT_POS" ] && info "gtid_current_pos: $GTID_CURRENT_POS"

[ -n "$BINLOG_CACHE_SIZE" ] && info "binlog_cache_size: $(bytes_h "$BINLOG_CACHE_SIZE")"
[ -n "$BINLOG_CACHE_USE" ] && info "Binlog_cache_use: $BINLOG_CACHE_USE"
[ -n "$BINLOG_CACHE_DISK_USE" ] && info "Binlog_cache_disk_use: $BINLOG_CACHE_DISK_USE"
if [ -n "${BINLOG_CACHE_PCT:-}" ] && [ "$(num "$BINLOG_CACHE_USE")" -gt 0 ]; then
  info "Binlog cache memory access: ${BINLOG_CACHE_PCT}%"
  [ "$(num "$BINLOG_CACHE_PCT")" -lt 90 ] && warn "Low binlog cache memory access (${BINLOG_CACHE_PCT}%) - consider increasing binlog_cache_size" || true
fi

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

section "Performance Schema"
[ -n "$PERFORMANCE_SCHEMA" ] && info "performance_schema: $PERFORMANCE_SCHEMA"
[ "$(num "$PFS_MEMORY_BYTES")" -gt 0 ] && info "Performance_schema Max memory usage: $(bytes_h "$PFS_MEMORY_BYTES")" || true

if [ "$SYS_SCHEMA_INSTALLED" = "yes" ]; then
  info "Sys schema is installed."
  [ -n "$SYS_SCHEMA_VERSION" ] && info "Sys schema Version: $SYS_SCHEMA_VERSION" || true
else
  info "Sys schema is not installed."
fi

section "Security (basic)"
[ -n "$SKIP_NAME_RESOLVE" ] && info "skip_name_resolve: $SKIP_NAME_RESOLVE"
[ -n "$LOCAL_INFILE" ] && info "local_infile: $LOCAL_INFILE"
[ -n "$HAVE_SSL" ] && info "have_ssl: $HAVE_SSL"
[ -n "$REQUIRE_SECURE_TRANSPORT" ] && info "require_secure_transport: $REQUIRE_SECURE_TRANSPORT"

[ "$LOCAL_INFILE" = "ON" ] && warn "local_infile is ON (consider OFF unless required)" || true
[ "$REQUIRE_SECURE_TRANSPORT" = "OFF" ] && warn "require_secure_transport is OFF (consider ON if you require TLS)" || true

ok "Collected: SHOW GLOBAL VARIABLES/STATUS"
warn "Next: implement more MySQLTuner-perl checks for feature parity."
}

mysqltuner_emit_json() {
  # Build recommendation arrays from accumulated warn/ok messages
  # REC_WARN/REC_OK are stored as newline-separated text.
  RECOMMENDATIONS_JSON=$(printf '%s\n' "$REC_WARN" | awk 'NF{print}' | jq -Rsc 'split("\n") | map(select(length>0))')
  NOTES_JSON=$(printf '%s\n' "$REC_OK" | awk 'NF{print}' | jq -Rsc 'split("\n") | map(select(length>0))')

    jq -n \
    --arg version "$SERVER_VERSION" \
    --arg flavor "$SERVER_FLAVOR" \
    --argjson recommendations "$RECOMMENDATIONS_JSON" \
    --argjson notes "$NOTES_JSON" \
    --arg version_comment "$SERVER_COMMENT" \
    --arg uptime "$UPTIME" \
    --arg qps "$QPS" \
    --arg cps "$CPS" \
    --arg bytes_received "$BYTES_RECEIVED" \
    --arg bytes_sent "$BYTES_SENT" \
    --arg bytes_received_per_s "$BYTES_RECEIVED_PS" \
    --arg bytes_sent_per_s "$BYTES_SENT_PS" \
    --arg com_select "$COM_SELECT" \
    --arg com_insert "$COM_INSERT" \
    --arg com_update "$COM_UPDATE" \
    --arg com_delete "$COM_DELETE" \
    --arg com_replace "$COM_REPLACE" \
    --arg pct_reads "${PCT_READS:-}" \
    --arg pct_writes "${PCT_WRITES:-}" \
    --arg max_connections "$MAX_CONNECTIONS" \
    --arg max_used_connections "$MAX_USED_CONNECTIONS" \
    --arg max_used_connections_pct "${mupct:-}" \
    --arg threads_connected "$THREADS_CONNECTED" \
    --arg threads_running "$THREADS_RUNNING" \
    --arg threads_created "$THREADS_CREATED" \
    --arg thread_cache_size "$THREAD_CACHE_SIZE" \
    --arg thread_cache_hit_pct "$THREAD_CACHE_HIT_PCT" \
    --arg aborted_connects "$ABORTED_CONNECTS" \
    --arg aborted_connects_pct "$ABORT_PCT" \
    --arg aborted_clients "$ABORTED_CLIENTS" \
    --arg aborted_clients_pct "$ABORTED_CLIENTS_PCT" \
    --arg connection_errors_accept "$CONN_ERRORS_ACCEPT" \
    --arg connection_errors_internal "$CONN_ERRORS_INTERNAL" \
    --arg connection_errors_max_connections "$CONN_ERRORS_MAXCONN" \
    --arg connection_errors_peer_address "$CONN_ERRORS_PEERADDR" \
    --arg connection_errors_select "$CONN_ERRORS_SELECT" \
    --arg connection_errors_tcpwrap "$CONN_ERRORS_TCPWRAP" \
    --arg opened_tables_per_s "$OPENED_TABLES_PS" \
    --arg open_tables "$OPEN_TABLES" \
    --arg opened_table_definitions "$OPENED_TABLE_DEFS" \
    --arg open_files_limit "$OPEN_FILES_LIMIT" \
    --arg open_files "$OPEN_FILES" \
    --arg table_definition_cache "$TABLE_DEF_CACHE" \
    --arg total_tables "$TOTAL_TABLES" \
    --arg innodb_data_bytes "$INNODB_DATA_BYTES" \
    --arg innodb_bp_data_pct "${INNODB_BP_DATA_PCT:-}" \
    --arg table_open_cache_hits "$TABLE_OPEN_CACHE_HITS" \
    --arg table_open_cache_misses "$TABLE_OPEN_CACHE_MISSES" \
    --arg table_cache_hit_pct "${TABLE_CACHE_HIT_PCT:-}" \
    --arg table_locks_immediate "$TABLE_LOCKS_IMMEDIATE" \
    --arg table_locks_waited "$TABLE_LOCKS_WAITED" \
    --arg table_locks_waited_pct "$TABLE_LOCKS_WAITED_PCT" \
    --arg table_locks_immediate_pct "${TABLE_LOCKS_IMMEDIATE_PCT:-}" \
    --arg slow_query_log "$SLOW_QUERY_LOG" \
    --arg slow_queries "$SLOW_QUERIES" \
    --arg slow_queries_pct "$SLOW_QUERIES_PCT" \
    --arg slow_queries_per_day "$SLOW_QUERIES_PER_DAY" \
    --arg innodb_buffer_pool_size "$INNODB_BP_SIZE" \
    --arg innodb_buffer_pool_instances "$INNODB_BP_INSTANCES" \
    --arg innodb_buffer_pool_chunk_size "$INNODB_BP_CHUNK_SIZE" \
    --arg innodb_buffer_pool_chunk_aligned "${INNODB_BP_CHUNK_ALIGNED:-}" \
    --arg innodb_buffer_pool_read_requests "$INNODB_BP_READ_REQ" \
    --arg innodb_buffer_pool_reads "$INNODB_BP_READS" \
    --arg innodb_flush_log_at_trx_commit "$INNODB_FLUSH_LOG_AT_TRX" \
    --arg innodb_log_buffer_size "$INNODB_LOG_BUFFER_SIZE" \
    --arg innodb_log_file_size "$INNODB_LOG_FILE_SIZE" \
    --arg innodb_log_files_in_group "$INNODB_LOG_FILES_IN_GROUP" \
    --arg innodb_redo_log_capacity "$INNODB_REDO_LOG_CAPACITY" \
    --arg innodb_log_size_pct "${INNODB_LOG_SIZE_PCT:-}" \
    --arg innodb_file_per_table "$INNODB_FILE_PER_TABLE" \
    --arg innodb_flush_method "$INNODB_FLUSH_METHOD" \
    --arg innodb_log_waits "$INNODB_LOG_WAITS" \
    --arg innodb_log_write_requests "$INNODB_LOG_WRITE_REQ" \
    --arg innodb_log_writes "$INNODB_LOG_WRITES" \
    --arg innodb_log_write_efficiency_pct "${INNODB_LOG_WRITE_EFF_PCT:-}" \
    --arg innodb_os_log_fsyncs "$INNODB_OS_LOG_FSYNCS" \
    --arg innodb_os_log_written "$INNODB_OS_LOG_WRITTEN" \
    --arg innodb_buffer_pool_pages_total "$INNODB_BP_PAGES_TOTAL" \
    --arg innodb_buffer_pool_pages_free "$INNODB_BP_PAGES_FREE" \
    --arg innodb_buffer_pool_pages_dirty "$INNODB_BP_PAGES_DIRTY" \
    --arg innodb_buffer_pool_bytes_data "$INNODB_BP_BYTES_DATA" \
    --arg innodb_buffer_pool_bytes_free "$INNODB_BP_BYTES_FREE" \
    --arg innodb_buffer_pool_free_pct "$INNODB_BP_FREE_PCT" \
    --arg innodb_buffer_pool_used_pct "${INNODB_BP_USED_PCT:-}" \
    --arg innodb_buffer_pool_dirty_pct "$INNODB_BP_DIRTY_PCT" \
    --arg bind_address "$BIND_ADDRESS" \
    --arg skip_networking "$SKIP_NETWORKING" \
    --arg port "$PORT_VAR" \
    --arg log_bin "$LOG_BIN" \
    --arg binlog_format "$BINLOG_FORMAT" \
    --arg sync_binlog "$SYNC_BINLOG" \
    --arg binlog_cache_size "$BINLOG_CACHE_SIZE" \
    --arg binlog_cache_use "$BINLOG_CACHE_USE" \
    --arg binlog_cache_disk_use "$BINLOG_CACHE_DISK_USE" \
    --arg binlog_cache_pct "${BINLOG_CACHE_PCT:-}" \
    --arg gtid_mode "$GTID_MODE" \
    --arg gtid_current_pos "$GTID_CURRENT_POS" \
    --arg have_galera "$HAVE_GALERA" \
    --arg galera_gcache_bytes "$GCACHE_SIZE_BYTES" \
    --arg max_connect_errors "$MAX_CONNECT_ERRORS" \
    --arg thread_handling "$THREAD_HANDLING" \
    --arg have_threadpool "$HAVE_THREADPOOL" \
    --arg skip_name_resolve "$SKIP_NAME_RESOLVE" \
    --arg local_infile "$LOCAL_INFILE" \
    --arg require_secure_transport "$REQUIRE_SECURE_TRANSPORT" \
    --arg have_ssl "$HAVE_SSL" \
    --arg performance_schema "$PERFORMANCE_SCHEMA" \
    --arg performance_schema_memory_bytes "$PFS_MEMORY_BYTES" \
    --arg sys_schema_installed "$SYS_SCHEMA_INSTALLED" \
    --arg sys_schema_version "$SYS_SCHEMA_VERSION" \
    --arg engines_enabled_csv "$ENGINES_ENABLED_CSV" \
    --argjson engine_sizes "$ENGINE_SIZES_JSON" \
    --arg fragmented_tables_count "$FRAGMENTED_TABLES_COUNT" \
    --argjson fragmented_tables "$FRAGMENTED_TABLES_JSON" \
    --arg tables_no_pk_count "$TABLES_NO_PK_COUNT" \
    --argjson tables_no_pk "$TABLES_NO_PK_JSON" \
    --arg large_tables_no_sec_index_count "$LARGE_TABLES_NO_SEC_INDEX_COUNT" \
    --argjson large_tables_no_sec_index "$LARGE_TABLES_NO_SEC_INDEX_JSON" \
    --arg fk_mismatches_count "$FK_MISMATCHES_COUNT" \
    --argjson fk_mismatches "$FK_MISMATCHES_JSON" \
    --arg non_innodb_tables_count "$NON_INNODB_TABLES_COUNT" \
    --argjson non_innodb_tables "$NON_INNODB_TABLES_JSON" \
    --arg unconstrained_id_count "$UNCONSTRAINED_ID_COUNT" \
    --argjson unconstrained_id "$UNCONSTRAINED_ID_JSON" \
    --arg fk_cascade_count "$FK_CASCADE_COUNT" \
    --argjson fk_cascade "$FK_CASCADE_JSON" \
    --arg empty_schemas_count "$EMPTY_SCHEMAS_COUNT" \
    --argjson empty_schemas "$EMPTY_SCHEMAS_JSON" \
    --arg nullable_cols_count "$NULLABLE_COLS_COUNT" \
    --arg naming_table_issues_count "$NAMING_TABLE_ISSUES_COUNT" \
    --argjson naming_table_issues "$NAMING_TABLE_ISSUES_JSON" \
    --arg naming_col_issues_count "$NAMING_COL_ISSUES_COUNT" \
    --argjson naming_col_issues "$NAMING_COL_ISSUES_JSON" \
    --arg non_utf8_cols_count "$NON_UTF8_COLS_COUNT" \
    --argjson non_utf8_cols "$NON_UTF8_COLS_JSON" \
    --arg pk_naming_issues_count "$PK_NAMING_ISSUES_COUNT" \
    --argjson pk_naming_issues "$PK_NAMING_ISSUES_JSON" \
    --arg uuid_pk_issues_count "$UUID_PK_ISSUES_COUNT" \
    --argjson uuid_pk_issues "$UUID_PK_ISSUES_JSON" \
    --arg pk_surrogate_issues_count "$PK_SURROGATE_ISSUES_COUNT" \
    --argjson pk_surrogate_issues "$PK_SURROGATE_ISSUES_JSON" \
    --arg fulltext_cols_count "$FULLTEXT_COLS_COUNT" \
    --argjson fulltext_cols "$FULLTEXT_COLS_JSON" \
    --arg json_no_gen_count "$JSON_NO_GEN_COUNT" \
    --argjson json_no_gen "$JSON_NO_GEN_JSON" \
    --arg invisible_idx_count "$INVISIBLE_IDX_COUNT" \
    --argjson invisible_idx "$INVISIBLE_IDX_JSON" \
    --arg check_constraints_count "$CHECK_CONSTRAINTS_COUNT" \
    --argjson check_constraints "$CHECK_CONSTRAINTS_JSON" \
    --arg plugins_active_count "$PLUGINS_ACTIVE_COUNT" \
    --argjson plugins_active "$PLUGINS_ACTIVE_JSON" \
    --arg databases_count "$DATABASES_COUNT" \
    --argjson databases_list "$DATABASES_LIST_JSON" \
    --arg db_tables_count "$DB_TABLES_COUNT" \
    --arg db_views_count "$DB_VIEWS_COUNT" \
    --arg db_indexes_count "$DB_INDEXES_COUNT" \
    --arg db_total_rows "$DB_TOTAL_ROWS" \
    --arg db_data_bytes "$DB_DATA_BYTES" \
    --arg db_index_bytes "$DB_INDEX_BYTES" \
    --arg db_total_bytes "$DB_TOTAL_BYTES" \
    --arg db_charsets_count "$DB_CHARSETS_COUNT" \
    --argjson db_charsets "$DB_CHARSETS_JSON" \
    --arg db_collations_count "$DB_COLLATIONS_COUNT" \
    --argjson db_collations "$DB_COLLATIONS_JSON" \
    --arg db_engines_count "$DB_ENGINES_COUNT" \
    --argjson db_engines "$DB_ENGINES_JSON" \
    --arg db_breakdown_count "$DB_BREAKDOWN_COUNT" \
    --argjson db_breakdown "$DB_BREAKDOWN_JSON" \
    --arg db_index_breakdown_count "$DB_INDEX_BREAKDOWN_COUNT" \
    --argjson db_index_breakdown "$DB_INDEX_BREAKDOWN_JSON" \
    --arg largest_tables_count "$LARGEST_TABLES_COUNT" \
    --argjson largest_tables "$LARGEST_TABLES_JSON" \
    --arg views_count "$VIEWS_COUNT" \
    --argjson views "$VIEWS_JSON" \
    --arg routines_count "$ROUTINES_COUNT" \
    --argjson routines "$ROUTINES_JSON" \
    --arg triggers_count "$TRIGGERS_COUNT" \
    --argjson triggers "$TRIGGERS_JSON" \
    --arg indexes_count "$INDEXES_COUNT" \
    --argjson indexes "$INDEXES_JSON" \
    --arg tables_no_index_count "$TABLES_NO_INDEX_COUNT" \
    --argjson tables_no_index "$TABLES_NO_INDEX_JSON" \
    --arg duplicate_indexes_count "$DUPLICATE_INDEXES_COUNT" \
    --argjson duplicate_indexes "$DUPLICATE_INDEXES_JSON" \
    --arg same_cols_diff_uniq_count "$SAME_COLS_DIFF_UNIQ_COUNT" \
    --argjson same_cols_diff_uniq "$SAME_COLS_DIFF_UNIQ_JSON" \
    --arg redundant_indexes_count "$REDUNDANT_INDEXES_COUNT" \
    --argjson redundant_indexes "$REDUNDANT_INDEXES_JSON" \
    --arg unique_redundant_pk_count "$UNIQUE_REDUNDANT_PK_COUNT" \
    --argjson unique_redundant_pk "$UNIQUE_REDUNDANT_PK_JSON" \
    --arg table_metrics_count "$TABLE_METRICS_COUNT" \
    --argjson table_metrics "$TABLE_METRICS_JSON" \
    --arg schema_dir "$SCHEMA_DIR" \
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
    --arg qcache_efficiency_pct "${QCACHE_EFF_PCT:-}" \
    --arg qcache_hit_pct "$QCACHE_HIT_PCT" \
    --arg qcache_free_blocks_pct "$QCACHE_FREE_BLOCKS_PCT" \
    --arg qcache_used_pct "$QCACHE_USED_PCT" \
    --arg qcache_prunes_per_day "$QCACHE_PRUNES_PER_DAY" \
    --arg sort_merge_pct "${SORT_MERGE_PCT:-}" \
    --arg joins_without_indexes "$JOINS_WITHOUT_INDEXES" \
    --arg joins_without_indexes_per_day "$JOINS_WO_IDX_PER_DAY" \
    --arg tmp_disk_pct "${TMP_DISK_PCT:-}" \
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
    --arg arch_bits "$ARCH_BITS" \
    --arg arch_machine "$ARCH_MACHINE" \
    --arg global_buffers_bytes "$GLOBAL_BUFFERS" \
    --arg max_tmp_table_size "$MAX_TMP_TABLE_SIZE" \
    --arg innodb_log_buffer_size "$INNODB_LOG_BUFFER_SIZE" \
    --arg per_thread_buffers_bytes "$PER_THREAD_BUFFERS" \
    --arg max_memory_estimate_bytes "$MAX_MEM" \
    --arg max_memory_at_max_used_bytes "$MAX_MEM_AT_MAX_USED" \
    --arg server_buffers_bytes "$SERVER_BUFFERS" \
    --arg total_per_thread_buffers_bytes "$TOTAL_PER_THREAD_BUFFERS" \
    --arg max_total_per_thread_buffers_bytes "$MAX_TOTAL_PER_THREAD_BUFFERS" \
    --arg total_buffers_bytes "$TOTAL_BUFFERS" \
    --arg max_total_buffers_bytes "$MAX_TOTAL_BUFFERS" \
    --arg pct_max_used_memory "${PCT_MAX_USED_MEMORY:-}" \
    --arg pct_max_peak_memory "${PCT_MAX_PEAK_MEMORY:-}" \
    --arg max_used_memory_bytes "$MAX_TOTAL_BUFFERS" \
    --arg max_peak_memory_bytes "$TOTAL_BUFFERS" \
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
      recommendations:$recommendations,
      notes:$notes,
      version_comment:$version_comment,
      uptime:$uptime,
      qps:$qps,
      cps:$cps,
      bytes_received:$bytes_received,
      bytes_sent:$bytes_sent,
      bytes_received_per_s:$bytes_received_per_s,
      bytes_sent_per_s:$bytes_sent_per_s,
      com_select:$com_select,
      com_insert:$com_insert,
      com_update:$com_update,
      com_delete:$com_delete,
      com_replace:$com_replace,
      pct_reads:$pct_reads,
      pct_writes:$pct_writes,
      max_connections:$max_connections,
      max_used_connections:$max_used_connections,
      max_used_connections_pct:$max_used_connections_pct,
      threads_connected:$threads_connected,
      threads_running:$threads_running,
      threads_created:$threads_created,
      thread_cache_size:$thread_cache_size,
      thread_cache_hit_pct:$thread_cache_hit_pct,
      aborted_connects:$aborted_connects,
      aborted_connects_pct:$aborted_connects_pct,
      aborted_clients:$aborted_clients,
      aborted_clients_pct:$aborted_clients_pct,
      connection_errors:{
        accept:$connection_errors_accept,
        internal:$connection_errors_internal,
        max_connections:$connection_errors_max_connections,
        peer_address:$connection_errors_peer_address,
        select:$connection_errors_select,
        tcpwrap:$connection_errors_tcpwrap
      },
      opened_tables_per_s:$opened_tables_per_s,
      open_tables:$open_tables,
      opened_table_definitions:$opened_table_definitions,
      open_files_limit:$open_files_limit,
      open_files:$open_files,
      table_definition_cache:$table_definition_cache,
      total_tables:$total_tables,
      innodb_data_bytes:$innodb_data_bytes,
      innodb_bp_data_pct:$innodb_bp_data_pct,
      table_open_cache_hits:$table_open_cache_hits,
      table_open_cache_misses:$table_open_cache_misses,
      table_cache_hit_pct:$table_cache_hit_pct,
      table_locks_immediate:$table_locks_immediate,
      table_locks_waited:$table_locks_waited,
      table_locks_waited_pct:$table_locks_waited_pct,
      table_locks_immediate_pct:$table_locks_immediate_pct,
      slow_query_log:$slow_query_log,
      slow_queries:$slow_queries,
      slow_queries_pct:$slow_queries_pct,
      slow_queries_per_day:$slow_queries_per_day,
      innodb_buffer_pool_size:$innodb_buffer_pool_size,
      innodb_buffer_pool_instances:$innodb_buffer_pool_instances,
      innodb_buffer_pool_chunk_size:$innodb_buffer_pool_chunk_size,
      innodb_buffer_pool_chunk_aligned:$innodb_buffer_pool_chunk_aligned,
      innodb_buffer_pool_read_requests:$innodb_buffer_pool_read_requests,
      innodb_buffer_pool_reads:$innodb_buffer_pool_reads,
      innodb_flush_log_at_trx_commit:$innodb_flush_log_at_trx_commit,
      innodb_log_buffer_size:$innodb_log_buffer_size,
      innodb_log_file_size:$innodb_log_file_size,
      innodb_log_files_in_group:$innodb_log_files_in_group,
      innodb_redo_log_capacity:$innodb_redo_log_capacity,
      innodb_log_size_pct:$innodb_log_size_pct,
      innodb_file_per_table:$innodb_file_per_table,
      innodb_flush_method:$innodb_flush_method,
      innodb_log_waits:$innodb_log_waits,
      innodb_log_write_requests:$innodb_log_write_requests,
      innodb_log_writes:$innodb_log_writes,
      innodb_log_write_efficiency_pct:$innodb_log_write_efficiency_pct,
      innodb_os_log_fsyncs:$innodb_os_log_fsyncs,
      innodb_os_log_written:$innodb_os_log_written,
      innodb_buffer_pool_pages_total:$innodb_buffer_pool_pages_total,
      innodb_buffer_pool_pages_free:$innodb_buffer_pool_pages_free,
      innodb_buffer_pool_pages_dirty:$innodb_buffer_pool_pages_dirty,
      innodb_buffer_pool_bytes_data:$innodb_buffer_pool_bytes_data,
      innodb_buffer_pool_bytes_free:$innodb_buffer_pool_bytes_free,
      innodb_buffer_pool_free_pct:$innodb_buffer_pool_free_pct,
      innodb_buffer_pool_used_pct:$innodb_buffer_pool_used_pct,
      innodb_buffer_pool_dirty_pct:$innodb_buffer_pool_dirty_pct,
      bind_address:$bind_address,
      skip_networking:$skip_networking,
      port:$port,
      log_bin:$log_bin,
      binlog_format:$binlog_format,
      sync_binlog:$sync_binlog,
      binlog_cache_size:$binlog_cache_size,
      binlog_cache_use:$binlog_cache_use,
      binlog_cache_disk_use:$binlog_cache_disk_use,
      binlog_cache_pct:$binlog_cache_pct,
      gtid_mode:$gtid_mode,
      gtid_current_pos:$gtid_current_pos,
      have_galera:$have_galera,
      galera_gcache_bytes:$galera_gcache_bytes,
      max_connect_errors:$max_connect_errors,
      thread_handling:$thread_handling,
      have_threadpool:$have_threadpool,
      skip_name_resolve:$skip_name_resolve,
      local_infile:$local_infile,
      require_secure_transport:$require_secure_transport,
      have_ssl:$have_ssl,
      performance_schema:$performance_schema,
      performance_schema_memory_bytes:$performance_schema_memory_bytes,
      sys_schema_installed:$sys_schema_installed,
      sys_schema_version:$sys_schema_version,
      engines_enabled_csv:$engines_enabled_csv,
      engine_sizes:$engine_sizes,
      fragmented_tables_count:$fragmented_tables_count,
      fragmented_tables:$fragmented_tables,
      tables_no_pk_count:$tables_no_pk_count,
      tables_no_pk:$tables_no_pk,
      large_tables_no_sec_index_count:$large_tables_no_sec_index_count,
      large_tables_no_sec_index:$large_tables_no_sec_index,
      fk_mismatches_count:$fk_mismatches_count,
      fk_mismatches:$fk_mismatches,
      non_innodb_tables_count:$non_innodb_tables_count,
      non_innodb_tables:$non_innodb_tables,
      unconstrained_id_count:$unconstrained_id_count,
      unconstrained_id:$unconstrained_id,
      fk_cascade_count:$fk_cascade_count,
      fk_cascade:$fk_cascade,
      empty_schemas_count:$empty_schemas_count,
      empty_schemas:$empty_schemas,
      nullable_cols_count:$nullable_cols_count,
      naming_table_issues_count:$naming_table_issues_count,
      naming_table_issues:$naming_table_issues,
      naming_col_issues_count:$naming_col_issues_count,
      naming_col_issues:$naming_col_issues,
      non_utf8_cols_count:$non_utf8_cols_count,
      non_utf8_cols:$non_utf8_cols,
      pk_naming_issues_count:$pk_naming_issues_count,
      pk_naming_issues:$pk_naming_issues,
      uuid_pk_issues_count:$uuid_pk_issues_count,
      uuid_pk_issues:$uuid_pk_issues,
      pk_surrogate_issues_count:$pk_surrogate_issues_count,
      pk_surrogate_issues:$pk_surrogate_issues,
      fulltext_cols_count:$fulltext_cols_count,
      fulltext_cols:$fulltext_cols,
      json_no_gen_count:$json_no_gen_count,
      json_no_gen:$json_no_gen,
      invisible_idx_count:$invisible_idx_count,
      invisible_idx:$invisible_idx,
      check_constraints_count:$check_constraints_count,
      check_constraints:$check_constraints,
      plugins_active_count:$plugins_active_count,
      plugins_active:$plugins_active,
      databases_count:$databases_count,
      databases_list:$databases_list,
      db_tables_count:$db_tables_count,
      db_views_count:$db_views_count,
      db_indexes_count:$db_indexes_count,
      db_total_rows:$db_total_rows,
      db_data_bytes:$db_data_bytes,
      db_index_bytes:$db_index_bytes,
      db_total_bytes:$db_total_bytes,
      db_charsets_count:$db_charsets_count,
      db_charsets:$db_charsets,
      db_collations_count:$db_collations_count,
      db_collations:$db_collations,
      db_engines_count:$db_engines_count,
      db_engines:$db_engines,
      db_breakdown_count:$db_breakdown_count,
      db_breakdown:$db_breakdown,
      db_index_breakdown_count:$db_index_breakdown_count,
      db_index_breakdown:$db_index_breakdown,
      largest_tables_count:$largest_tables_count,
      largest_tables:$largest_tables,
      views_count:$views_count,
      views:$views,
      routines_count:$routines_count,
      routines:$routines,
      triggers_count:$triggers_count,
      triggers:$triggers,
      indexes_count:$indexes_count,
      indexes:$indexes,
      tables_no_index_count:$tables_no_index_count,
      tables_no_index:$tables_no_index,
      duplicate_indexes_count:$duplicate_indexes_count,
      duplicate_indexes:$duplicate_indexes,
      same_cols_diff_uniq_count:$same_cols_diff_uniq_count,
      same_cols_diff_uniq:$same_cols_diff_uniq,
      redundant_indexes_count:$redundant_indexes_count,
      redundant_indexes:$redundant_indexes,
      unique_redundant_pk_count:$unique_redundant_pk_count,
      unique_redundant_pk:$unique_redundant_pk,
      table_metrics_count:$table_metrics_count,
      table_metrics:$table_metrics,
      schema_dir:$schema_dir,
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
      qcache_efficiency_pct:$qcache_efficiency_pct,
      qcache_hit_pct:$qcache_hit_pct,
      qcache_free_blocks_pct:$qcache_free_blocks_pct,
      qcache_used_pct:$qcache_used_pct,
      qcache_prunes_per_day:$qcache_prunes_per_day,
      sort_merge_pct:$sort_merge_pct,
      joins_without_indexes:$joins_without_indexes,
      joins_without_indexes_per_day:$joins_without_indexes_per_day,
      tmp_disk_pct:$tmp_disk_pct,
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
      arch_bits:$arch_bits,
      arch_machine:$arch_machine,
      global_buffers_bytes:$global_buffers_bytes,
      max_tmp_table_size:$max_tmp_table_size,
      innodb_log_buffer_size:$innodb_log_buffer_size,
      per_thread_buffers_bytes:$per_thread_buffers_bytes,
      max_memory_estimate_bytes:$max_memory_estimate_bytes,
      max_memory_at_max_used_bytes:$max_memory_at_max_used_bytes,
      server_buffers_bytes:$server_buffers_bytes,
      total_per_thread_buffers_bytes:$total_per_thread_buffers_bytes,
      max_total_per_thread_buffers_bytes:$max_total_per_thread_buffers_bytes,
      total_buffers_bytes:$total_buffers_bytes,
      max_total_buffers_bytes:$max_total_buffers_bytes,
      pct_max_used_memory:$pct_max_used_memory,
      pct_max_peak_memory:$pct_max_peak_memory,
      max_used_memory_bytes:$max_used_memory_bytes,
      max_peak_memory_bytes:$max_peak_memory_bytes,
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
}

# ---- Output routing --------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  # Run human phase to populate REC_WARN/REC_OK, but suppress ALL output
  mysqltuner_human >/dev/null
  mysqltuner_emit_json
fi

mysqltuner_human
exit 0
