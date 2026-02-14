#!/bin/sh
# mysqltuner.sh - POSIX shell port (derived from MySQLTuner-perl)
# License: GPLv3 (see LICENSE.GPLv3)

# Keep strict mode, but avoid set -e (we want controlled error handling)
set -u

VERSION="0.1.1-devel"

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

Notes:
  This is an in-progress POSIX shell port. The core engine (connection +
  variable/status collection) is implemented; feature parity checks follow.
USAGE
}

die() {
  echo "ERROR: $*" 1>&2
  exit 1
}

need_cmd() {
  # $1: command
  command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"
}

mktemp_dir() {
  # POSIX-ish mktemp fallback
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
  # $1: SQL
  mysql_query "$1" 2>/dev/null
}

# ---- KV helpers ------------------------------------------------------------
kv_get() {
  # $1: file (tab-separated key \t value)
  # $2: key
  awk -F"\t" -v k="$2" '($1==k){sub(/^[^\t]*\t/, ""); print; exit}' "$1"
}

kv_dump_file() {
  # $1: SQL that returns 2 columns (key, value)
  # $2: output file
  mysql_query_silent "$1" | awk 'NF>=2{print $1"\t"$2}' >"$2"
}

# ---- Core collection -------------------------------------------------------
WORKDIR="$(mktemp_dir)" || die "unable to create temp dir"
trap cleanup EXIT HUP INT TERM

VARS_TSV="$WORKDIR/variables.tsv"
STATUS_TSV="$WORKDIR/status.tsv"

# Ensure connection works
if ! mysql_query_silent "SELECT 1;" >/dev/null 2>&1; then
  die "unable to connect (check credentials/host/socket)"
fi

# Collect key/value tables
kv_dump_file "SHOW GLOBAL VARIABLES" "$VARS_TSV"
kv_dump_file "SHOW GLOBAL STATUS" "$STATUS_TSV"

# Basic server identity
SERVER_VERSION=$(mysql_query_silent "SELECT VERSION();" | head -n 1 | tr -d '\r')
SERVER_COMMENT=$(kv_get "$VARS_TSV" version_comment | tr -d '\r')
SERVER_FLAVOR="mysql"
case "$SERVER_VERSION" in
  *MariaDB*) SERVER_FLAVOR="mariadb" ;;
esac

UPTIME=$(kv_get "$STATUS_TSV" Uptime | tr -d '\r')

# ---- Output ---------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  # Use jq for correct JSON string escaping
  jq -n \
    --arg version "$SERVER_VERSION" \
    --arg flavor "$SERVER_FLAVOR" \
    --arg version_comment "$SERVER_COMMENT" \
    --arg uptime "$UPTIME" \
    '{version:$version, flavor:$flavor, version_comment:$version_comment, uptime:$uptime}'
  exit 0
fi

if [ "$SILENT" -eq 0 ]; then
  echo "MySQLTuner POSIX port (WIP)"
  echo "--------------------------------"
  echo "Server version:  $SERVER_VERSION"
  echo "Server flavor:   $SERVER_FLAVOR"
  if [ -n "$SERVER_COMMENT" ]; then
    echo "Version comment: $SERVER_COMMENT"
  fi
  if [ -n "$UPTIME" ]; then
    echo "Uptime (s):      $UPTIME"
  fi
  echo
  echo "Collected: SHOW GLOBAL VARIABLES/STATUS"
  echo "Next: implement checks/recommendations for feature parity."
fi

exit 0
