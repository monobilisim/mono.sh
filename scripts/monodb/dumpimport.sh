#!/usr/bin/env bash
#
# dumpimport.sh — MySQL/MariaDB to MariaDB migration tool
#
# Supported versions:
#   Source DB:  MySQL/MariaDB 5.5 and later
#   Target DB:  MariaDB 11.8 and later
#   mydumper:   0.14.0 and later (recommended: 0.16.0+)
#
# Why mydumper >= 0.14.0:
#   - 0.12.x introduced a backwards-incompatible dump file format change vs 0.11.x;
#     dumps from one major version cannot be loaded with the other.
#   - 0.14.0 stabilized config file support, session variables, and the modern
#     lock-mode options (--sync-thread-lock-mode) used by this script.
#   - 0.14.0+ also brings reliable MariaDB compatibility for CHARSET handling.
#   - Older versions (<= 0.11.x) are missing several CLI flags this script relies on.
#   - 0.16.0+ is recommended for additional MariaDB fixes and performance work.
#
# Strategy:
#   - Schema phase: mydumper for dump, mysql client for import using SOURCE charset.
#     This keeps DDL string literals (COMMENTs, defaults) parseable, which would
#     otherwise fail with "ERROR 1300: Invalid utf8mb3 character string" on MariaDB
#     11.x when COMMENTs contain non-UTF-8 bytes (e.g. latin5 in a MySQL 5.5 source).
#   - Data phase: mydumper/myloader with --set-names=binary for byte-perfect transfer.
#     Verified by row-level MD5 comparison: every byte of every row is preserved.
#     PER_TABLE=1 (default): tables are processed one at a time — dump -> load ->
#     exact row-count check (target COUNT(*) vs rows recorded in mydumper metadata)
#     -> delete that table's dump. Peak disk usage is one table's dump, not the
#     whole database. A failed or unverified table keeps its dump and stops the DB;
#     --resume continues from the first table that is not marked done.
#   - Objects phase: mydumper for triggers/routines/events.
#     We use mydumper here (not mysqldump) because the system-installed mysqldump
#     is mariadb-dump 11.x, which queries information_schema columns
#     (e.g. generation_expression) that don't exist on MySQL 5.5 sources, causing
#     silent empty dumps. mydumper is 5.5-compatible and shares the rest of the
#     pipeline's tooling.
#   - Pre-flight discovery: source/target version + flavor + charset detection.
#
# Usage:
#   ./dumpimport.sh                       # all databases
#   ./dumpimport.sh --only HYS_OTOHASAR   # single database
#   ./dumpimport.sh --only DB1,DB2        # multiple databases
#   ./dumpimport.sh --resume              # skip databases marked complete
#   ./dumpimport.sh --dry-run             # log commands without executing
#   ./dumpimport.sh --skip-verify         # skip post-migration row count verification
#   ./dumpimport.sh --skip-version-check  # bypass minimum version checks (risky)
#   ./dumpimport.sh --only-objects        # skip schema and data phases; run objects only
#   ./dumpimport.sh --help

set -o errexit
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true

### ===========================================================================
### --- TUNING & CONFIGURATION (edit these at the top) ----------------------
### ===========================================================================

# --- Connection settings ----------------------------------------------------
# The script runs ON the source server (chat-app-staging-db-01, 10.100.0.79).
# Source mysqld binds to 10.100.0.79 only, so "localhost" (unix socket) is used.
readonly SRC_HOST="src.x.x.x"
readonly SRC_USER="src_username"
readonly SRC_PASS="src_password"
# Target: MariaDB Galera node mysql1.stage (chat-app-node-05-db-01). root there is
# localhost-only; use a user that can connect from 10.100.0.79 with ALL on lila_*.
readonly DST_HOST="dst.x.x.x"
readonly DST_USER="dst_username"
readonly DST_PASS="dst_password"

# --- Paths ------------------------------------------------------------------
readonly LOCAL_DIR="/data/aktarim"
readonly STATE_DIR="${LOCAL_DIR}/.state"
readonly LOG_DIR="/var/log/dumpimport"

# --- Database list ----------------------------------------------------------
# Smaller DB first.
readonly DB_LIST=(
    "db1"
    "db2"
    "db3"
)

# --- Performance tuning (mydumper / myloader) -------------------------------
# Schema dump threads (small, CPU-bound parsing work). Note: schema IMPORT
# is sequential via mysql client (charset-aware), not parallel via myloader.
readonly SCHEMA_THREADS=2

# Data dump/import threads (parallel I/O — main throughput knob)
# Rule of thumb: equal to or slightly less than the smaller of (source CPU, target CPU)
readonly DATA_THREADS=2   # source has 2 vCPU; also keeps Galera flow control calm

# Rows per dump file chunk. Larger = fewer files but bigger files; smaller =
# more parallelism but more overhead. 100k is a balanced default.
readonly DUMP_ROWS=100000

# myloader queue size (-q): batches of rows per single INSERT statement on import.
# Increasing helps throughput, but raises memory pressure and can hit max_allowed_packet.
readonly LOADER_QUEUE=1000

# Lock mode used by mydumper for thread synchronization.
# Valid values: AUTO, SAFE_NO_LOCK, FTWRL, LOCK_ALL, GTID, NO_LOCK
#   AUTO         = mydumper picks based on server flavor (default)
#   FTWRL        = FLUSH TABLES WITH READ LOCK (fastest sync but blocks writes briefly)
#   LOCK_ALL     = LOCK TABLES on every table (use when FTWRL is denied, e.g. RDS)
#   SAFE_NO_LOCK = Percona/MariaDB GTID-based sync without FTWRL (best for HA setups)
#   GTID         = Strict GTID-based sync (requires GTID)
#   NO_LOCK      = no locking at all (use only when source has no concurrent writes)
readonly DUMP_LOCK_MODE="AUTO"

# If 1, forces --sync-thread-lock-mode=NO_LOCK (overriding DUMP_LOCK_MODE above).
# Use when source is read-only during migration OR you don't care about strict
# cross-thread consistency.
# WARNING: With concurrent writes this WILL produce an inconsistent backup.
readonly NO_LOCKS_FLAG=1

# DDL locks are separate from the thread-sync lock above: even with NO_LOCK,
# mydumper sends LOCK INSTANCE FOR BACKUP (MySQL 8) / BACKUP STAGE START (MariaDB)
# when the user has BACKUP_ADMIN. That blocks DDL, TRUNCATE, OPTIMIZE, REPAIR and
# account management on the SOURCE for the duration of each dump.
# 1 = pass --skip-ddl-locks (no locks on source at all). Trade-off: DDL on a table
# while it is being dumped can make that table's dump fail (per-table mode stops
# and keeps state; re-run with --resume).
readonly SKIP_DDL_LOCKS=1

# Long query guard (seconds): mydumper aborts if any query in PROCESSLIST has been
# running longer than this. Default mydumper value is 60s, too aggressive for
# production sources with reporting queries. With NO_LOCK we don't actually need
# this safeguard — set high (86400s = 1 day = effectively disabled).
readonly LONG_QUERY_GUARD=86400

# If 1, mydumper will KILL long-running queries on the source. Invasive — leave 0.
readonly KILL_LONG_QUERIES=0

# Verbosity for mydumper/myloader (-v): 0=silent, 1=err, 2=warn, 3=info, 4=debug
readonly MYDUMPER_VERBOSITY=3

# --- Schema import charset --------------------------------------------------
# When importing CREATE TABLE statements, MariaDB 11.x parses string literals in
# COMMENT clauses against the session character set (defaults to utf8mb3). If the
# source DB stored COMMENTs in a non-UTF-8 charset (e.g. latin5 in MySQL 5.5),
# importing with utf8mb3 fails: "ERROR 1300: Invalid utf8mb3 character string".
#
# This setting controls the --default-character-set passed to the mysql client
# during schema import. The schema's per-column CHARSET= clauses are independent
# of session charset, so each column still gets the charset declared in the DDL.
#
# Special value "auto" uses the source server's @@character_set_server detected
# during version discovery. Override with a literal value (e.g. "latin5", "utf8mb4")
# if discovery returns the wrong charset for your data.
readonly SCHEMA_IMPORT_CHARSET="auto"

# --- Disk space safety ------------------------------------------------------
# Free disk space must be at least source_db_size * DISK_SAFETY_FACTOR
readonly DISK_SAFETY_FACTOR="1.3"

# --- Per-table mode ---------------------------------------------------------
# 1 = dump/load/verify one table at a time (disk need = largest table's dump).
# 0 = original behaviour: dump the whole DB, then load it.
readonly PER_TABLE=0
# Delete a table's dump right after its rows are loaded and verified.
readonly DELETE_DUMP_AFTER_LOAD=0
# If mydumper metadata has no row count for a table, the load cannot be verified.
# 0 = keep the dump and stop the DB (safe default); 1 = delete it anyway.
readonly DELETE_UNVERIFIED_DUMPS=0
# Free space required before dumping a table: data_length * factor
# (indexes are not dumped; text encoding can exceed data_length).
readonly TABLE_DISK_SAFETY_FACTOR="1.5"

# --- Verification -----------------------------------------------------------
# Tolerated row-count drift percentage during verification (0 = strict).
# information_schema.table_rows is an estimate for InnoDB, so small drift is normal.
readonly ROW_COUNT_TOLERANCE_PCT=0

# --- Alarm integration ------------------------------------------------------
readonly MONOKIT_BIN="/usr/local/bin/monokit"
# Empty topic disables alarms. Fill both to enable.
readonly MONOKIT_STREAM=""
readonly MONOKIT_TOPIC=""

# --- Version requirements ---------------------------------------------------
# DB versions: encoded as major*100 + minor (5.5 -> 505, 11.8 -> 1108)
readonly MIN_SRC_VERSION_INT=505     # MySQL/MariaDB 5.5
readonly MIN_DST_VERSION_INT=1108    # MariaDB 11.8

# mydumper version: encoded as major*10000 + minor*100 + patch (0.14.0 -> 1400)
readonly MIN_MYDUMPER_VERSION_INT=1400   # 0.14.0 minimum
readonly REC_MYDUMPER_VERSION_INT=1600   # 0.16.0 recommended

### ===========================================================================
### --- INTERNALS (you should not need to edit below this line) -------------
### ===========================================================================

declare -A DURATION_SCHEMA DURATION_DATA DURATION_OBJECTS DURATION_TOTAL
declare -A DB_STATUS DB_FAIL_REASON
declare -a SELECTED_DBS

SRC_VERSION_RAW=""; SRC_FLAVOR=""; SRC_VERSION_INT=0
SRC_CHARSET=""; SRC_COLLATION=""; SRC_CLIENT_SSL_FLAG=""

DST_VERSION_RAW=""; DST_FLAVOR=""; DST_VERSION_INT=0
DST_CHARSET=""; DST_COLLATION=""; DST_CLIENT_SSL_FLAG=""

MYDUMPER_VERSION_RAW=""
MYDUMPER_VERSION_INT=0

DRY_RUN=0
RESUME=0
SKIP_VERIFY=0
SKIP_VERSION_CHECK=0
ONLY_OBJECTS=0
SCRIPT_NAME="$(basename "$0")"
LOG_FILE=""
TEE_PID=""

### --- Helpers --------------------------------------------------------------

# Signal handling: Ctrl+C, SIGTERM cleanly abort.
# Without this, child processes (mydumper/myloader) may hang because tee subprocess
# in setup_logging keeps stdout open, and bash with `set -e` doesn't always
# propagate signals correctly to background pipes.
INTERRUPTED=0
CHILD_PIDS=()

cleanup_on_signal() {
    local sig="$1"
    INTERRUPTED=1
    log_err "Received SIG${sig}, cleaning up child processes and exiting..."

    # Kill any tracked child PIDs (mydumper/myloader started via run())
    local pid
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    # Best-effort: kill any active mydumper/myloader spawned by us
    pkill -TERM -P $$ 2>/dev/null || true

    # Give them a moment to exit gracefully
    sleep 1

    # Force kill anything still running
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    pkill -KILL -P $$ 2>/dev/null || true

    alarm "Migration ABORTED by SIG${sig}"
    log_err "Migration aborted."

    # Close tee subprocess so the shell prompt returns immediately
    if [[ -n "$TEE_PID" ]] && kill -0 "$TEE_PID" 2>/dev/null; then
        # Restore original stdout/stderr first so further writes don't block
        exec 1>&2 2>/dev/tty 2>/dev/null || true
        kill -TERM "$TEE_PID" 2>/dev/null || true
    fi

    exit 130   # 128 + SIGINT(2)
}

trap 'cleanup_on_signal INT'  INT
trap 'cleanup_on_signal TERM' TERM
trap 'cleanup_on_signal HUP'  HUP

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log()      { printf '%s [INFO]  %s\n'  "$(timestamp)" "$*"; }
log_warn() { printf '%s [WARN]  %s\n'  "$(timestamp)" "$*" >&2; }
log_err()  { printf '%s [ERROR] %s\n'  "$(timestamp)" "$*" >&2; }
log_step() { printf '\n%s ===== %s =====\n' "$(timestamp)" "$*"; }

die() {
    log_err "$*"
    alarm "FATAL: $*"
    exit 1
}

alarm() {
    local message="$1"
    [[ -x "$MONOKIT_BIN" && -n "$MONOKIT_STREAM" && -n "$MONOKIT_TOPIC" ]] || return 0
    if (( DRY_RUN )); then
        log "[dry-run] alarm: $message"
        return 0
    fi
    "$MONOKIT_BIN" alarm send \
        --stream "$MONOKIT_STREAM" \
        --topic "$MONOKIT_TOPIC" \
        --message "$(timestamp) | $message" \
        >/dev/null 2>&1 || log_warn "Failed to send alarm: $message"
}

run() {
    if (( DRY_RUN )); then
        # Never write credentials to the log.
        local a shown=()
        for a in "$@"; do
            [[ "$a" == --password=* ]] && a="--password=****"
            shown+=("$a")
        done
        log "[dry-run] ${shown[*]}"
        return 0
    fi
    # Run command in foreground but track its PID so signal handler can kill it.
    # Using `&` + `wait` instead of direct exec, so that bash receives signals
    # while the child runs and the trap can fire mid-execution.
    "$@" &
    local child_pid=$!
    CHILD_PIDS+=("$child_pid")
    local rc=0
    wait "$child_pid" || rc=$?
    # Remove this PID from tracker (best-effort cleanup)
    local i
    for i in "${!CHILD_PIDS[@]}"; do
        [[ "${CHILD_PIDS[$i]}" == "$child_pid" ]] && unset 'CHILD_PIDS[i]'
    done
    return $rc
}

human_seconds() {
    local s="$1"
    printf '%dm %ds' $((s / 60)) $((s % 60))
}

# DB version: "5.5.58-log" -> 505, "11.8.2-MariaDB" -> 1108
db_version_to_int() {
    local raw="$1" major minor
    if [[ "$raw" =~ ^([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        printf '%d' $((major * 100 + minor))
    else
        printf '0'
    fi
}

format_db_version_int() {
    local v="$1"
    printf '%d.%d' $((v / 100)) $((v % 100))
}

# mydumper version: "0.14.5" -> 1405, "0.16.0-1" -> 1600
mydumper_version_to_int() {
    local raw="$1" major minor patch
    if [[ "$raw" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"
        printf '%d' $((major * 10000 + minor * 100 + patch))
    else
        printf '0'
    fi
}

format_mydumper_version_int() {
    local v="$1"
    printf '%d.%d.%d' $((v / 10000)) $(((v / 100) % 100)) $((v % 100))
}

### --- Client wrappers (version-aware) --------------------------------------

src_client() {
    local bin
    if command -v mysql >/dev/null 2>&1; then bin="mysql"; else bin="mariadb"; fi
    # shellcheck disable=SC2086
    "$bin" -h "$SRC_HOST" -u "$SRC_USER" -p"$SRC_PASS" \
        $SRC_CLIENT_SSL_FLAG \
        --default-character-set=binary "$@"
}

dst_client() {
    local bin
    if command -v mariadb >/dev/null 2>&1; then bin="mariadb"; else bin="mysql"; fi
    # shellcheck disable=SC2086
    "$bin" -h "$DST_HOST" -u "$DST_USER" -p"$DST_PASS" \
        $DST_CLIENT_SSL_FLAG \
        --default-character-set=binary "$@"
}

### --- CLI parsing ----------------------------------------------------------

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

MySQL/MariaDB to MariaDB migration tool.
  Supported source DB: MySQL/MariaDB 5.5+
  Target DB         : MariaDB 11.8+
  mydumper required : 0.14.0+ (0.16.0+ recommended)

OPTIONS:
  --only DB[,DB...]      Process only the specified databases
  --resume               Skip databases marked complete in state directory
  --dry-run              Log commands without executing
  --skip-verify          Skip post-migration row count verification
  --skip-version-check   Bypass minimum version requirements (risky)
  --only-objects         Skip schema and data phases; run only objects phase.
                         Useful when schema/data already migrated and only
                         triggers/routines/events need to be (re-)imported.
  --help, -h             Show this message

Configured databases:
EOF
    printf '  - %s\n' "${DB_LIST[@]}"
}

parse_args() {
    SELECTED_DBS=("${DB_LIST[@]}")
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)
                IFS=',' read -ra SELECTED_DBS <<< "$2"
                shift 2 ;;
            --resume)              RESUME=1;             shift ;;
            --dry-run)             DRY_RUN=1;            shift ;;
            --skip-verify)         SKIP_VERIFY=1;        shift ;;
            --skip-version-check)  SKIP_VERSION_CHECK=1; shift ;;
            --only-objects)        ONLY_OBJECTS=1;       shift ;;
            --help|-h)             usage; exit 0 ;;
            *)
                log_err "Unknown argument: $1"
                usage
                exit 2 ;;
        esac
    done

    local db
    for db in "${SELECTED_DBS[@]}"; do
        local found=0 cfg
        for cfg in "${DB_LIST[@]}"; do
            [[ "$db" == "$cfg" ]] && { found=1; break; }
        done
        (( found )) || die "Database '$db' is not in the configured list. See --help."
    done
}

### --- Pre-flight checks ----------------------------------------------------

check_dependencies() {
    local cmd missing=()
    # mysqldump no longer required: objects phase uses mydumper.
    for cmd in mydumper myloader awk numfmt df sed; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
        missing+=("mysql/mariadb client")
    fi
    (( ${#missing[@]} == 0 )) || die "Missing commands: ${missing[*]}"
}

check_credentials() {
    local v
    for v in SRC_PASS DST_USER DST_PASS; do
        [[ -n "${!v}" && "${!v}" != "__DOLDUR__" ]] || \
            die "$v is not set (edit the connection settings at the top of $SCRIPT_NAME)"
    done
}

discover_mydumper_version() {
    local raw_output
    raw_output="$(mydumper --version 2>/dev/null | head -n1)" || \
        die "Cannot run 'mydumper --version'"

    if [[ "$raw_output" =~ mydumper[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        MYDUMPER_VERSION_RAW="${BASH_REMATCH[1]}"
    else
        MYDUMPER_VERSION_RAW="$raw_output"
    fi

    MYDUMPER_VERSION_INT="$(mydumper_version_to_int "$MYDUMPER_VERSION_RAW")"
}

validate_mydumper_version() {
    log "mydumper version: $MYDUMPER_VERSION_RAW"

    if (( SKIP_VERSION_CHECK )); then
        log_warn "--skip-version-check is set: bypassing mydumper version check"
        return 0
    fi

    if (( MYDUMPER_VERSION_INT == 0 )); then
        log_warn "Could not parse mydumper version; proceeding anyway"
        return 0
    fi

    if (( MYDUMPER_VERSION_INT < MIN_MYDUMPER_VERSION_INT )); then
        die "mydumper version too old: $MYDUMPER_VERSION_RAW (minimum: $(format_mydumper_version_int "$MIN_MYDUMPER_VERSION_INT"))"
    fi

    if (( MYDUMPER_VERSION_INT < REC_MYDUMPER_VERSION_INT )); then
        log_warn "mydumper $MYDUMPER_VERSION_RAW works but $(format_mydumper_version_int "$REC_MYDUMPER_VERSION_INT")+ is recommended"
    fi
}

# Detect version + flavor + charset for a DB endpoint.
# Also discovers the SSL flag: tries --skip-ssl first, falls back to no flag
# (MySQL 5.5/5.6 do not recognize --skip-ssl).
discover_endpoint() {
    local side="$1"
    local host user pass client_bin
    if [[ "$side" == "SRC" ]]; then
        host="$SRC_HOST"; user="$SRC_USER"; pass="$SRC_PASS"
        if command -v mysql >/dev/null 2>&1; then client_bin="mysql"; else client_bin="mariadb"; fi
    else
        host="$DST_HOST"; user="$DST_USER"; pass="$DST_PASS"
        if command -v mariadb >/dev/null 2>&1; then client_bin="mariadb"; else client_bin="mysql"; fi
    fi

    local raw_output ssl_flag=""

    if raw_output="$("$client_bin" -h "$host" -u "$user" -p"$pass" --skip-ssl -N -B \
        -e "SELECT VERSION(); SELECT @@character_set_server; SELECT @@collation_server;" 2>/dev/null)"; then
        ssl_flag="--skip-ssl"
    elif raw_output="$("$client_bin" -h "$host" -u "$user" -p"$pass" -N -B \
        -e "SELECT VERSION(); SELECT @@character_set_server; SELECT @@collation_server;" 2>/dev/null)"; then
        ssl_flag=""
    else
        die "$side ($host): cannot connect or VERSION() query failed"
    fi

    local version charset collation
    version="$(awk 'NR==1' <<< "$raw_output")"
    charset="$(awk 'NR==2' <<< "$raw_output")"
    collation="$(awk 'NR==3' <<< "$raw_output")"

    local flavor="MySQL"
    if [[ "$version" == *MariaDB* ]] || [[ "$version" == *mariadb* ]]; then
        flavor="MariaDB"
    elif [[ "$version" == *Percona* ]] || [[ "$version" == *percona* ]]; then
        flavor="Percona"
    fi

    local version_int
    version_int="$(db_version_to_int "$version")"

    if [[ "$side" == "SRC" ]]; then
        SRC_VERSION_RAW="$version"
        SRC_FLAVOR="$flavor"
        SRC_VERSION_INT="$version_int"
        SRC_CHARSET="$charset"
        SRC_COLLATION="$collation"
        SRC_CLIENT_SSL_FLAG="$ssl_flag"
    else
        DST_VERSION_RAW="$version"
        DST_FLAVOR="$flavor"
        DST_VERSION_INT="$version_int"
        DST_CHARSET="$charset"
        DST_COLLATION="$collation"
        DST_CLIENT_SSL_FLAG="$ssl_flag"
    fi
}

discover_and_validate() {
    log_step "Version discovery"

    discover_mydumper_version
    validate_mydumper_version

    discover_endpoint SRC
    log "Source DB: $SRC_HOST"
    log "  Version  : $SRC_VERSION_RAW"
    log "  Flavor   : $SRC_FLAVOR"
    log "  Charset  : $SRC_CHARSET / $SRC_COLLATION"
    log "  SSL flag : ${SRC_CLIENT_SSL_FLAG:-<none>}"

    discover_endpoint DST
    log "Target DB: $DST_HOST"
    log "  Version  : $DST_VERSION_RAW"
    log "  Flavor   : $DST_FLAVOR"
    log "  Charset  : $DST_CHARSET / $DST_COLLATION"
    log "  SSL flag : ${DST_CLIENT_SSL_FLAG:-<none>}"

    if (( SKIP_VERSION_CHECK )); then
        log_warn "--skip-version-check is set: bypassing minimum DB version checks"
        return 0
    fi

    if (( SRC_VERSION_INT < MIN_SRC_VERSION_INT )); then
        die "Source DB version not supported: $SRC_VERSION_RAW (minimum: $(format_db_version_int "$MIN_SRC_VERSION_INT"))"
    fi

    if [[ "$DST_FLAVOR" != "MariaDB" ]]; then
        die "Target must be MariaDB, found: $DST_FLAVOR ($DST_VERSION_RAW)"
    fi
    if (( DST_VERSION_INT < MIN_DST_VERSION_INT )); then
        die "Target MariaDB version not supported: $DST_VERSION_RAW (minimum: $(format_db_version_int "$MIN_DST_VERSION_INT"))"
    fi

    if [[ "$SRC_FLAVOR" == "MariaDB" ]] && (( SRC_VERSION_INT >= DST_VERSION_INT )); then
        log_warn "Source MariaDB version is equal to or greater than target — downgrade or same-version migration?"
    fi
    if [[ "$SRC_CHARSET" != "$DST_CHARSET" ]]; then
        log_warn "Source and target default charsets differ: $SRC_CHARSET vs $DST_CHARSET"
        log_warn "  Strategy: data uses --set-names=binary (byte-perfect); schema uses source charset for parsing."
    fi

    log "Version discovery: OK"
}

get_db_size_bytes() {
    local db="$1"
    src_client -N -B -e "
        SELECT IFNULL(SUM(data_length + index_length), 0)
        FROM information_schema.tables
        WHERE table_schema = '$db';
    " 2>/dev/null
}

check_disk_space() {
    local db="$1"
    local src_bytes
    src_bytes="$(get_db_size_bytes "$db")"
    [[ -n "$src_bytes" && "$src_bytes" -gt 0 ]] || {
        log_warn "$db: cannot determine source size, skipping disk check"
        return 0
    }

    local needed_bytes
    needed_bytes="$(awk -v s="$src_bytes" -v f="$DISK_SAFETY_FACTOR" 'BEGIN{printf "%.0f", s*f}')"

    local avail_bytes
    avail_bytes="$(df -B1 --output=avail "$LOCAL_DIR" | tail -n1 | tr -d ' ')"

    local src_human needed_human avail_human
    src_human="$(numfmt --to=iec --suffix=B "$src_bytes")"
    needed_human="$(numfmt --to=iec --suffix=B "$needed_bytes")"
    avail_human="$(numfmt --to=iec --suffix=B "$avail_bytes")"

    log "$db: source=$src_human, required=$needed_human (x$DISK_SAFETY_FACTOR), available=$avail_human"

    if (( avail_bytes < needed_bytes )); then
        return 1
    fi
    return 0
}

# Returns 1 if LOCAL_DIR has less free space than bytes * factor.
check_disk_for_bytes() {
    local bytes="$1" factor="$2" label="$3"
    local needed avail
    needed="$(awk -v s="$bytes" -v f="$factor" 'BEGIN{printf "%.0f", s*f}')"
    avail="$(df -B1 --output=avail "$LOCAL_DIR" | tail -n1 | tr -d ' ')"
    log "$label: required=$(numfmt --to=iec --suffix=B "$needed") (x$factor), available=$(numfmt --to=iec --suffix=B "$avail")"
    (( avail >= needed ))
}

### --- State management -----------------------------------------------------

state_file_for() { printf '%s/%s.done' "$STATE_DIR" "$1"; }
mark_done() {
    local db="$1"
    (( DRY_RUN )) && return 0
    mkdir -p "$STATE_DIR"
    date '+%Y-%m-%d %H:%M:%S' > "$(state_file_for "$db")"
}
is_done() { [[ -f "$(state_file_for "$1")" ]]; }
table_state_file()  { printf '%s/%s/%s.done' "$STATE_DIR" "$1" "$2"; }
schema_state_file() { printf '%s/%s/.schema.done' "$STATE_DIR" "$1"; }

### --- Logging --------------------------------------------------------------

setup_logging() {
    # Logs and dumps contain credentials/data: owner-only from here on.
    umask 077
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/dumpimport-$(date '+%Y%m%d-%H%M%S').log"

    # Use process substitution for tee, but capture its PID so we can clean up
    # on signal. Without this, Ctrl+C may leave tee blocking on stdout.
    exec > >(tee -a -i "$LOG_FILE")
    TEE_PID=$!
    exec 2>&1
    sleep 0.1
    log "Log file: $LOG_FILE"
}

### --- Schema phase ---------------------------------------------------------

# Resolve SCHEMA_IMPORT_CHARSET: "auto" -> source's @@character_set_server.
resolve_schema_charset() {
    if [[ "$SCHEMA_IMPORT_CHARSET" == "auto" ]]; then
        if [[ -n "$SRC_CHARSET" ]]; then
            printf '%s' "$SRC_CHARSET"
        else
            printf 'binary'
        fi
    else
        printf '%s' "$SCHEMA_IMPORT_CHARSET"
    fi
}

# Drop existing tables/views in target DB (idempotency for re-runs).
drop_existing_tables() {
    local db="$1"
    log "$db: dropping existing tables/views in target before schema import"
    if (( DRY_RUN )); then
        log "[dry-run] would drop all tables/views in $db"
        return 0
    fi

    dst_client -e "CREATE DATABASE IF NOT EXISTS \`$db\`;"

    local drops
    drops="$(dst_client -N -B -e "
        SELECT CONCAT('DROP TABLE IF EXISTS \`$db\`.\`', table_name, '\`;')
        FROM information_schema.tables
        WHERE table_schema='$db' AND table_type='BASE TABLE';
        SELECT CONCAT('DROP VIEW IF EXISTS \`$db\`.\`', table_name, '\`;')
        FROM information_schema.views
        WHERE table_schema='$db';
    " 2>/dev/null)"

    if [[ -n "$drops" ]]; then
        dst_client -e "SET FOREIGN_KEY_CHECKS=0; $drops SET FOREIGN_KEY_CHECKS=1;"
    fi
}

# Import schema files using the mysql/mariadb client with the source charset.
# We bypass myloader for schema import because myloader uses --set-names=binary,
# which makes MariaDB 11.x reject CREATE TABLE statements whose COMMENT clauses
# contain non-UTF-8 bytes (e.g. latin5).
# Per-column CHARSET= clauses in the DDL are honored regardless of session charset.
# Order: tables -> views -> post-files (FKs).
import_schema_with_client() {
    local db="$1"
    local outdir="$2"
    local charset="$3"

    local client_bin
    if command -v mariadb >/dev/null 2>&1; then client_bin="mariadb"; else client_bin="mysql"; fi

    shopt -s nullglob

    local table_count=0 table_failed=0 view_count=0 view_failed=0 post_count=0 post_failed=0
    local f rc

    # 1) Tables
    for f in "$outdir"/*-schema.sql; do
        case "$(basename "$f")" in
            *-schema-create.sql|*-schema-post.sql|*-schema-view.sql|*-schema-triggers.sql) continue ;;
        esac
        rc=0
        # shellcheck disable=SC2086
        "$client_bin" -h "$DST_HOST" -u "$DST_USER" -p"$DST_PASS" \
            $DST_CLIENT_SSL_FLAG \
            --default-character-set="$charset" "$db" < "$f" || rc=$?
        if (( rc != 0 )); then
            ((table_failed++)) || true
            log_err "$db: failed to import $(basename "$f") (exit=$rc)"
        else
            ((table_count++)) || true
        fi
    done
    log "$db: imported $table_count table schemas (failed: $table_failed)"
    if (( table_failed > 0 )); then
        log_err "$db: $table_failed table schemas failed to import — aborting this DB"
        shopt -u nullglob
        return 1
    fi

    # 2) Views (after referenced tables)
    for f in "$outdir"/*-schema-view.sql; do
        [[ -f "$f" ]] || continue
        rc=0
        # shellcheck disable=SC2086
        "$client_bin" -h "$DST_HOST" -u "$DST_USER" -p"$DST_PASS" \
            $DST_CLIENT_SSL_FLAG \
            --default-character-set="$charset" "$db" < "$f" || rc=$?
        if (( rc != 0 )); then
            ((view_failed++)) || true
            log_warn "$db: failed to import view $(basename "$f") (exit=$rc) — continuing"
        else
            ((view_count++)) || true
        fi
    done
    if (( view_count > 0 || view_failed > 0 )); then
        log "$db: imported $view_count views (failed: $view_failed)"
    fi
    # Views often fail when underlying tables/columns differ; treat as warning, not fatal.

    # 3) Post-files (foreign keys, etc.)
    for f in "$outdir"/*-schema-post.sql; do
        [[ -f "$f" ]] || continue
        rc=0
        # shellcheck disable=SC2086
        "$client_bin" -h "$DST_HOST" -u "$DST_USER" -p"$DST_PASS" \
            $DST_CLIENT_SSL_FLAG \
            --default-character-set="$charset" "$db" < "$f" || rc=$?
        if (( rc != 0 )); then
            ((post_failed++)) || true
            log_err "$db: failed to import post-file $(basename "$f") (exit=$rc)"
        else
            ((post_count++)) || true
        fi
    done
    if (( post_count > 0 || post_failed > 0 )); then
        log "$db: imported $post_count post files (failed: $post_failed)"
    fi
    if (( post_failed > 0 )); then
        log_err "$db: $post_failed post files failed — aborting this DB"
        shopt -u nullglob
        return 1
    fi

    shopt -u nullglob
    return 0
}

phase_schema() {
    local db="$1"
    local outdir="$LOCAL_DIR/backup/$db-schema"

    log_step "$db | Step 1/3: Schema"
    alarm "$db - Step 1/3: Schema started"

    mkdir -p "$outdir"

    log "$db: schema dump"
    local src_flags=()
    (( KILL_LONG_QUERIES )) && src_flags+=(--kill-long-queries)
    (( SKIP_DDL_LOCKS )) && src_flags+=(--skip-ddl-locks)
    local lock_mode
    if (( NO_LOCKS_FLAG )); then lock_mode="NO_LOCK"; else lock_mode="$DUMP_LOCK_MODE"; fi
    # NOTE: Schema dump deliberately omits --set-names so mydumper uses the source
    # server's default charset (e.g. latin5). This makes the SET NAMES line that
    # mydumper writes at the top of each schema file consistent with the actual
    # byte content of COMMENTs and other string literals in the DDL. The data
    # phase still uses --set-names=binary for byte-perfect transfer.
    run mydumper \
        --host="$SRC_HOST" --user="$SRC_USER" --password="$SRC_PASS" \
        --database="$db" --outputdir="$outdir" \
        --clear --no-data \
        --threads="$SCHEMA_THREADS" \
        --sync-thread-lock-mode="$lock_mode" \
        --long-query-guard="$LONG_QUERY_GUARD" \
        "${src_flags[@]}" \
        --trx-tables=0 \
        -v "$MYDUMPER_VERBOSITY"

    log "$db: schema sed adjustments"
    if ! (( DRY_RUN )); then
        sed -i \
            -e 's/ENGINE=MyISAM/ENGINE=InnoDB/g' \
            -e 's/ROW_FORMAT=FIXED/ROW_FORMAT=DYNAMIC/g' \
            -e 's/ROW_FORMAT=REDUNDANT/ROW_FORMAT=DYNAMIC/g' \
            -e 's/ROW_FORMAT=COMPACT/ROW_FORMAT=DYNAMIC/g' \
          -e 's/ENCRYPTION=[^ ]*//g' \
            -e 's/ TYPE=InnoDB/ ENGINE=InnoDB/g' \
            -e 's/ TYPE=MyISAM/ ENGINE=InnoDB/g' \
            -E -e 's/DEFINER=`[^`]+`@`[^`]+`//g' \
            "$outdir"/*.sql 2>/dev/null || true
        sed -i -E "s/DEFINER='[^']+'@'[^']+'//g" "$outdir"/*.sql 2>/dev/null || true

        # Strip mydumper's SET NAMES line so our --default-character-set takes effect.
        # mydumper writes "/*!40101 SET NAMES <charset>*/;" at the top of each schema
        # file based on its --set-names setting (or default). When this differs from
        # what the parser needs to interpret COMMENT bytes, MariaDB 11.x rejects the
        # CREATE TABLE with "ERROR 1300: Invalid utf8mb3 character string". Removing
        # this line lets the client's --default-character-set control the session.
        sed -i -E 's|/\*![0-9]+ +SET NAMES +[a-zA-Z0-9_]+ *\*/;||g' "$outdir"/*.sql 2>/dev/null || true
        sed -i -E 's|^SET NAMES +[a-zA-Z0-9_]+; *$||g' "$outdir"/*.sql 2>/dev/null || true
    fi

    local schema_charset
    schema_charset="$(resolve_schema_charset)"
    log "$db: schema import using --default-character-set=$schema_charset"

    if (( DRY_RUN )); then
        log "[dry-run] would drop existing tables and import schema files via $schema_charset"
        return 0
    fi

    drop_existing_tables "$db"
    import_schema_with_client "$db" "$outdir" "$schema_charset"
}

### --- Data phase -----------------------------------------------------------

phase_data() {
    local db="$1"
    local outdir="$LOCAL_DIR/backup/$db"

    log_step "$db | Step 2/3: Data"
    alarm "$db - Step 2/3: Data started"

    mkdir -p "$outdir"

    local lock_mode
    if (( NO_LOCKS_FLAG )); then lock_mode="NO_LOCK"; else lock_mode="$DUMP_LOCK_MODE"; fi
    log "$db: data dump (rows=$DUMP_ROWS, threads=$DATA_THREADS, lock_mode=$lock_mode)"
    local src_flags=()
    (( KILL_LONG_QUERIES )) && src_flags+=(--kill-long-queries)
    (( SKIP_DDL_LOCKS )) && src_flags+=(--skip-ddl-locks)
    run mydumper \
        --host="$SRC_HOST" --user="$SRC_USER" --password="$SRC_PASS" \
        --database="$db" --outputdir="$outdir" \
        --no-schemas \
        --rows="$DUMP_ROWS" \
        --threads="$DATA_THREADS" \
        --sync-thread-lock-mode="$lock_mode" \
        --long-query-guard="$LONG_QUERY_GUARD" \
        "${src_flags[@]}" \
        --clear \
        --set-names=binary \
        --trx-tables=0 \
        -v "$MYDUMPER_VERBOSITY"

    log "$db: data import (queue=$LOADER_QUEUE)"
    run myloader \
        --host="$DST_HOST" --user="$DST_USER" --password="$DST_PASS" \
        --database="$db" --directory="$outdir" \
        --threads="$DATA_THREADS" \
        -q "$LOADER_QUEUE" \
        --set-names=binary \
        -v "$MYDUMPER_VERBOSITY"
}

# Rows mydumper wrote for a table, from the "rows = N" line under the table's
# section in the dump's metadata file. The header is compared with quotes
# stripped, so both [`db`.`table`] and [`db.table`] forms match.
# Prints nothing if absent.
dumped_row_count() {
    local dir="$1" db="$2" tbl="$3"
    [[ -f "$dir/metadata" ]] || return 0
    awk -v hdr="[$db.$tbl]" '
        /^\[/ { h = $0; gsub(/[`"]/, "", h); in_sec = (h == hdr); next }
        in_sec && /^rows[[:space:]]*=/ { sub(/^rows[[:space:]]*=[[:space:]]*/, ""); print; exit }
    ' "$dir/metadata"
}

# Per-table data phase: for each table, smallest first:
#   disk check -> dump -> TRUNCATE target -> load -> exact COUNT(*) check -> delete dump.
# Any failure keeps that table's dump on disk and stops this DB (later tables are
# not attempted); --resume skips tables already marked done.
phase_data_per_table() {
    local db="$1"
    local base="$LOCAL_DIR/data/$db"

    log_step "$db | Step 2/3: Data (per table)"
    alarm "$db - Step 2/3: Data (per table) started"

    local lock_mode
    if (( NO_LOCKS_FLAG )); then lock_mode="NO_LOCK"; else lock_mode="$DUMP_LOCK_MODE"; fi
    local src_flags=()
    (( KILL_LONG_QUERIES )) && src_flags+=(--kill-long-queries)
    (( SKIP_DDL_LOCKS )) && src_flags+=(--skip-ddl-locks)

    local tables
    tables="$(src_client -N -B -e "
        SELECT table_name, data_length
        FROM information_schema.tables
        WHERE table_schema = '$db' AND table_type = 'BASE TABLE'
        ORDER BY data_length, table_name;
    " </dev/null)" || { log_err "$db: cannot list source tables"; return 1; }

    local total
    total="$(grep -c . <<< "$tables" || true)"
    mkdir -p "$base" "$STATE_DIR/$db"
    log "$db: $total tables (dump rows=$DUMP_ROWS, threads=$DATA_THREADS, lock_mode=$lock_mode, delete_after_load=$DELETE_DUMP_AFTER_LOAD)"

    local tbl size outdir expected actual idx=0 loaded=0 skipped=0
    while IFS=$'\t' read -r tbl size; do
        [[ -z "$tbl" ]] && continue
        ((idx++)) || true
        outdir="$base/$tbl"

        if (( RESUME )) && [[ -f "$(table_state_file "$db" "$tbl")" ]]; then
            ((skipped++)) || true
            continue
        fi

        log "$db.$tbl [$idx/$total]: data_length=$(numfmt --to=iec --suffix=B "$size")"
        if ! check_disk_for_bytes "$size" "$TABLE_DISK_SAFETY_FACTOR" "$db.$tbl"; then
            log_err "$db.$tbl: not enough free space in $LOCAL_DIR for this table's dump — stopping $db"
            return 1
        fi

        if (( DRY_RUN )); then
            log "[dry-run] $db.$tbl: dump -> TRUNCATE target -> load -> verify -> delete $outdir"
            continue
        fi

        rm -rf "$outdir"
        mkdir -p "$outdir"

        run mydumper \
            --host="$SRC_HOST" --user="$SRC_USER" --password="$SRC_PASS" \
            --database="$db" --tables-list="$db.$tbl" --outputdir="$outdir" \
            --no-schemas \
            --rows="$DUMP_ROWS" \
            --threads="$DATA_THREADS" \
            --sync-thread-lock-mode="$lock_mode" \
            --long-query-guard="$LONG_QUERY_GUARD" \
            "${src_flags[@]}" \
            --clear \
            --set-names=binary \
            --trx-tables=0 \
            -v "$MYDUMPER_VERBOSITY" \
            || { log_err "$db.$tbl: dump failed (kept: $outdir)"; return 1; }

        expected="$(dumped_row_count "$outdir" "$db" "$tbl")"

        # A previous attempt may have died mid-load; never append to partial data.
        dst_client -e "SET FOREIGN_KEY_CHECKS=0; TRUNCATE TABLE \`$db\`.\`$tbl\`;" </dev/null \
            || { log_err "$db.$tbl: TRUNCATE on target failed (kept: $outdir)"; return 1; }

        run myloader \
            --host="$DST_HOST" --user="$DST_USER" --password="$DST_PASS" \
            --database="$db" --directory="$outdir" \
            --threads="$DATA_THREADS" \
            -q "$LOADER_QUEUE" \
            --set-names=binary \
            -v "$MYDUMPER_VERBOSITY" \
            || { log_err "$db.$tbl: load failed (kept: $outdir)"; return 1; }

        actual="$(dst_client -N -B -e "SELECT COUNT(*) FROM \`$db\`.\`$tbl\`;" </dev/null)" \
            || { log_err "$db.$tbl: COUNT(*) on target failed (kept: $outdir)"; return 1; }

        if [[ -z "$expected" ]]; then
            if (( DELETE_UNVERIFIED_DUMPS )); then
                log_warn "$db.$tbl: no row count in dump metadata; target has $actual rows — continuing (DELETE_UNVERIFIED_DUMPS=1)"
            else
                log_err "$db.$tbl: no row count in dump metadata; target has $actual rows — cannot verify, kept: $outdir"
                return 1
            fi
        elif [[ "$expected" != "$actual" ]]; then
            log_err "$db.$tbl: row count mismatch (dump=$expected, target=$actual) — kept: $outdir"
            return 1
        else
            log "$db.$tbl: $actual rows loaded and verified"
        fi

        date '+%Y-%m-%d %H:%M:%S' > "$(table_state_file "$db" "$tbl")"
        ((loaded++)) || true

        if (( DELETE_DUMP_AFTER_LOAD )); then
            rm -rf "$outdir"
            log "$db.$tbl: dump deleted, free in $LOCAL_DIR: $(df -h --output=avail "$LOCAL_DIR" | tail -n1 | tr -d ' ')"
        fi
    done <<< "$tables"

    log "$db: per-table data phase done — loaded=$loaded skipped(resume)=$skipped total=$total"
}

### --- Object counting (trigger/routine/event) -----------------------------

# Counts triggers/routines/events in a schema on a given side ("SRC" or "DST").
# Outputs three lines: triggers, routines, events.
count_db_objects() {
    local side="$1" db="$2"
    local sql="
        SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='$db';
        SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema='$db';
        SELECT COUNT(*) FROM information_schema.events   WHERE event_schema='$db';
    "
    if [[ "$side" == "SRC" ]]; then
        src_client -N -B -e "$sql" 2>/dev/null
    else
        dst_client -N -B -e "$sql" 2>/dev/null
    fi
}

### --- Objects phase --------------------------------------------------------

# Drop existing triggers/routines/events in the target so re-runs are idempotent.
drop_existing_objects() {
    local db="$1"
    log "$db: dropping existing triggers/routines/events in target"
    if (( DRY_RUN )); then
        log "[dry-run] would drop existing triggers/routines/events in $db"
        return 0
    fi

    local drops
    drops="$(dst_client -N -B -e "
        SELECT CONCAT('DROP TRIGGER IF EXISTS \`$db\`.\`', trigger_name, '\`;')
          FROM information_schema.triggers WHERE trigger_schema='$db';
        SELECT CONCAT('DROP ', routine_type, ' IF EXISTS \`$db\`.\`', routine_name, '\`;')
          FROM information_schema.routines WHERE routine_schema='$db';
        SELECT CONCAT('DROP EVENT IF EXISTS \`$db\`.\`', event_name, '\`;')
          FROM information_schema.events WHERE event_schema='$db';
    " 2>/dev/null)"

    if [[ -n "$drops" ]]; then
        dst_client -e "$drops" || log_warn "$db: some drops failed (may be harmless)"
    fi
}

# Returns 0 if the directory contains at least one .sql file with substantive
# content (DDL or non-trivial statements). 1 otherwise.
#
# We check for the presence of CREATE/DROP/DELIMITER statements specifically
# rather than trying to filter out every kind of comment, because mydumper
# files contain SET, /*! ... */ directives, and other boilerplate that aren't
# DDL but aren't pure comments either. If a file has at least one CREATE,
# DROP, or DELIMITER, it's considered to have real content.
objects_dir_has_content() {
    local outdir="$1"
    shopt -s nullglob
    local f
    local found=1
    for f in "$outdir"/*.sql; do
        [[ -f "$f" ]] || continue
        if grep -q -i -E '^[[:space:]]*(CREATE|DROP|DELIMITER)[[:space:]]' "$f" 2>/dev/null; then
            found=0
            break
        fi
    done
    shopt -u nullglob
    return $found
}

# Wrap each CREATE TRIGGER/FUNCTION/PROCEDURE/EVENT block in DELIMITER ;;
# directives, so the mariadb client can parse the BEGIN..END; bodies correctly.
#
# Why: mydumper emits these blocks WITHOUT DELIMITER directives. The default
# mariadb client treats the first `;` it sees as a statement terminator, which
# splits the block mid-body. Wrapping with DELIMITER ;; tells the client to
# only treat `;;` as a terminator. We rewrite the trailing `END;` (must be
# `END` followed by `;` on its own line — not `END IF;`, `END WHILE;`, etc.)
# as `END;;`. After the block we restore DELIMITER ; for any tail content.
#
# This is conservative: it only acts on lines that BEGIN with CREATE and
# the block-closing `END;` line — body content stays untouched.
add_delimiters_to_object_file() {
    local infile="$1"
    local outfile="$2"

    awk '
        BEGIN { in_block = 0 }

        # Detect start of a routine/trigger/event block.
        # mydumper writes these with leading whitespace stripped, but be lenient.
        /^[[:space:]]*CREATE[[:space:]]+([^(]*[[:space:]]+)?(TRIGGER|FUNCTION|PROCEDURE|EVENT)[^A-Z_]/ {
            if (!in_block) {
                print "DELIMITER ;;"
                in_block = 1
            }
            print
            next
        }

        # Closing END; on its own line (allowing optional whitespace).
        # NOT END IF;, END WHILE;, END LOOP; etc — those have a keyword between.
        in_block && /^END[[:space:]]*;[[:space:]]*$/ {
            sub(/;[[:space:]]*$/, ";;")
            print
            print "DELIMITER ;"
            in_block = 0
            next
        }

        { print }
    ' "$infile" > "$outfile"
}

# Import object files using the mariadb/mysql client with the source charset.
# Object files from mydumper:
#   *-schema-triggers.sql  -> triggers
#   *-schema-post.sql      -> routines + events (in mydumper 0.14+)
#
# Each file is first processed by add_delimiters_to_object_file to wrap
# CREATE blocks in DELIMITER ;; directives (mydumper does not emit these).
import_objects_with_client() {
    local db="$1"
    local outdir="$2"
    local charset="$3"

    local client_bin
    if command -v mariadb >/dev/null 2>&1; then client_bin="mariadb"; else client_bin="mysql"; fi

    shopt -s nullglob

    local f rc wrapped
    local trig_count=0 trig_failed=0
    local post_count=0 post_failed=0

    # 1) Triggers
    for f in "$outdir"/*-schema-triggers.sql; do
        [[ -f "$f" ]] || continue
        wrapped="${f}.delim"
        log "$db: wrapping DELIMITERs and importing $(basename "$f")"
        add_delimiters_to_object_file "$f" "$wrapped"
        rc=0
        # shellcheck disable=SC2086
        "$client_bin" -h "$DST_HOST" -u "$DST_USER" -p"$DST_PASS" \
            $DST_CLIENT_SSL_FLAG \
            --default-character-set="$charset" "$db" < "$wrapped" || rc=$?
        if (( rc != 0 )); then
            ((trig_failed++)) || true
            log_err "$db: failed to import trigger file $(basename "$f") (exit=$rc)"
        else
            ((trig_count++)) || true
        fi
    done

    # 2) Post (routines + events)
    for f in "$outdir"/*-schema-post.sql; do
        [[ -f "$f" ]] || continue
        wrapped="${f}.delim"
        log "$db: wrapping DELIMITERs and importing $(basename "$f")"
        add_delimiters_to_object_file "$f" "$wrapped"
        rc=0
        # shellcheck disable=SC2086
        "$client_bin" -h "$DST_HOST" -u "$DST_USER" -p"$DST_PASS" \
            $DST_CLIENT_SSL_FLAG \
            --default-character-set="$charset" "$db" < "$wrapped" || rc=$?
        if (( rc != 0 )); then
            ((post_failed++)) || true
            log_err "$db: failed to import post file $(basename "$f") (exit=$rc)"
        else
            ((post_count++)) || true
        fi
    done

    log "$db: imported $trig_count trigger files (failed: $trig_failed), $post_count post files (failed: $post_failed)"

    shopt -u nullglob

    if (( trig_failed > 0 || post_failed > 0 )); then
        return 1
    fi
    return 0
}

phase_objects() {
    local db="$1"
    local outdir="$LOCAL_DIR/backup/$db-objects"

    log_step "$db | Step 3/3: Objects (triggers + routines + events)"
    alarm "$db - Step 3/3: Objects started"

    # Get baseline counts from source for later verification
    local src_counts src_trig src_routines src_events
    if ! (( DRY_RUN )); then
        src_counts="$(count_db_objects SRC "$db")"
        src_trig="$(awk 'NR==1' <<< "$src_counts")"
        src_routines="$(awk 'NR==2' <<< "$src_counts")"
        src_events="$(awk 'NR==3' <<< "$src_counts")"
        log "$db: source has triggers=$src_trig routines=$src_routines events=$src_events"

        if (( src_trig == 0 && src_routines == 0 && src_events == 0 )); then
            log "$db: no triggers/routines/events in source — skipping objects phase"
            return 0
        fi
    fi

    mkdir -p "$outdir"
    # Wipe the output directory so old/partial dumps don't get re-imported
    if ! (( DRY_RUN )); then
        rm -f "$outdir"/*.sql 2>/dev/null || true
    fi

    log "$db: object dump (mydumper --triggers --routines --events)"
    local src_flags=()
    (( KILL_LONG_QUERIES )) && src_flags+=(--kill-long-queries)
    (( SKIP_DDL_LOCKS )) && src_flags+=(--skip-ddl-locks)
    local lock_mode
    if (( NO_LOCKS_FLAG )); then lock_mode="NO_LOCK"; else lock_mode="$DUMP_LOCK_MODE"; fi

    # mydumper deliberately omits --set-names so source charset is used.
    # --no-data: don't dump table rows
    # --no-schemas: don't dump CREATE TABLE statements (we already have them)
    # --triggers/--routines/--events: extract these object types
    run mydumper \
        --host="$SRC_HOST" --user="$SRC_USER" --password="$SRC_PASS" \
        --database="$db" --outputdir="$outdir" \
        --clear --no-data --no-schemas \
        --triggers --routines --events \
        --threads="$SCHEMA_THREADS" \
        --sync-thread-lock-mode="$lock_mode" \
        --long-query-guard="$LONG_QUERY_GUARD" \
        "${src_flags[@]}" \
        --trx-tables=0 \
        -v "$MYDUMPER_VERBOSITY"

    if (( DRY_RUN )); then
        log "[dry-run] would verify dump, drop existing objects, and import"
        return 0
    fi

    # Sanity check: did mydumper actually produce non-empty SQL files?
    if ! objects_dir_has_content "$outdir"; then
        log_err "$db: mydumper produced no usable object files in $outdir"
        log_err "$db: directory contents:"
        ls -la "$outdir" >&2 || true
        return 1
    fi

    # Strip mydumper's SET NAMES line (same reason as schema phase)
    sed -i -E 's|/\*![0-9]+ +SET NAMES +[a-zA-Z0-9_]+ *\*/;||g' "$outdir"/*.sql 2>/dev/null || true
    sed -i -E 's|^SET NAMES +[a-zA-Z0-9_]+; *$||g' "$outdir"/*.sql 2>/dev/null || true

    # Strip DEFINER clauses — target user may not exist on destination
    sed -i -E 's/DEFINER=`[^`]+`@`[^`]+`//g' "$outdir"/*.sql 2>/dev/null || true
    sed -i -E "s/DEFINER='[^']+'@'[^']+'//g" "$outdir"/*.sql 2>/dev/null || true

    drop_existing_objects "$db"

    local schema_charset
    schema_charset="$(resolve_schema_charset)"
    log "$db: importing objects using --default-character-set=$schema_charset"

    if ! import_objects_with_client "$db" "$outdir" "$schema_charset"; then
        log_err "$db: object import failed"
        return 1
    fi

    # Post-import verification
    local dst_counts dst_trig dst_routines dst_events
    dst_counts="$(count_db_objects DST "$db")"
    dst_trig="$(awk 'NR==1' <<< "$dst_counts")"
    dst_routines="$(awk 'NR==2' <<< "$dst_counts")"
    dst_events="$(awk 'NR==3' <<< "$dst_counts")"

    log "$db: target has triggers=$dst_trig routines=$dst_routines events=$dst_events"
    log "$db: source had  triggers=$src_trig routines=$src_routines events=$src_events"

    local diff_trig=$(( src_trig - dst_trig ))
    local diff_routines=$(( src_routines - dst_routines ))
    local diff_events=$(( src_events - dst_events ))

    if (( diff_trig != 0 || diff_routines != 0 || diff_events != 0 )); then
        log_warn "$db: object count mismatch — triggers diff=$diff_trig routines diff=$diff_routines events diff=$diff_events"
        return 2   # non-fatal warning, propagated to migrate_db
    fi

    log "$db: object counts match source — OK"
    return 0
}

### --- Verification ---------------------------------------------------------

verify_row_counts() {
    local db="$1"

    if (( SKIP_VERIFY )); then
        log "$db: verification skipped (--skip-verify)"
        return 0
    fi
    if (( DRY_RUN )); then
        log "[dry-run] $db: row count verification skipped"
        return 0
    fi

    log_step "$db | Verification: row count comparison"

    local src_counts dst_counts
    src_counts="$(src_client -N -B -e "
        SELECT table_name, table_rows
        FROM information_schema.tables
        WHERE table_schema = '$db' AND table_type = 'BASE TABLE'
        ORDER BY table_name;
    ")"
    dst_counts="$(dst_client -N -B -e "
        SELECT table_name, table_rows
        FROM information_schema.tables
        WHERE table_schema = '$db' AND table_type = 'BASE TABLE'
        ORDER BY table_name;
    ")"

    local mismatch_count=0 total_tables=0 report=""

    while IFS=$'\t' read -r tbl src_rows; do
        [[ -z "$tbl" ]] && continue
        ((total_tables++)) || true
        local dst_rows
        dst_rows="$(awk -v t="$tbl" '$1==t {print $2}' <<< "$dst_counts")"
        dst_rows="${dst_rows:-MISSING}"

        if [[ "$dst_rows" == "MISSING" ]]; then
            ((mismatch_count++)) || true
            report+=$(printf '\n  MISSING: %s (source=%s)' "$tbl" "$src_rows")
        elif [[ "$src_rows" != "$dst_rows" ]]; then
            local diff=$(( src_rows > dst_rows ? src_rows - dst_rows : dst_rows - src_rows ))
            local allowed=0
            if (( ROW_COUNT_TOLERANCE_PCT > 0 && src_rows > 0 )); then
                allowed=$(( src_rows * ROW_COUNT_TOLERANCE_PCT / 100 ))
            fi
            if (( diff > allowed )); then
                ((mismatch_count++)) || true
                report+=$(printf '\n  DRIFT:   %s (source=%s, target=%s, diff=%s)' \
                    "$tbl" "$src_rows" "$dst_rows" "$diff")
            fi
        fi
    done <<< "$src_counts"

    if (( mismatch_count > 0 )); then
        log_warn "$db: $mismatch_count of $total_tables tables have mismatches:$report"
        log_warn "$db: NOTE — information_schema.table_rows is an estimate for InnoDB; small differences may be normal"
        return 1
    fi

    log "$db: $total_tables tables verified, row counts match"
    return 0
}

### --- Per-DB orchestration -------------------------------------------------

migrate_db() {
    local db="$1"
    local db_start db_end

    if (( RESUME )) && is_done "$db"; then
        log "$db: already complete (--resume), skipping"
        DB_STATUS["$db"]="SKIPPED"
        return 0
    fi

    log_step "$db | MIGRATION STARTING"
    alarm "$db - Migration started"

    db_start="$(date +%s)"
    local phase_start phase_end

    if (( ONLY_OBJECTS )); then
        log "$db: --only-objects mode — skipping schema and data phases"
        DURATION_SCHEMA["$db"]=0
        DURATION_DATA["$db"]=0
    else
        # Per-table mode checks space per table; the whole-DB check would demand
        # data+index of the entire DB even though only one table is on disk at a time.
        if ! (( PER_TABLE )) && ! check_disk_space "$db"; then
            DB_STATUS["$db"]="FAILED"
            DB_FAIL_REASON["$db"]="Insufficient disk space"
            log_err "$db: insufficient disk space, skipping"
            alarm "$db - ERROR: Insufficient disk space"
            return 1
        fi

        # Per-table --resume must not re-run the schema phase: it drops every
        # target table, including ones already loaded and verified.
        if (( PER_TABLE && RESUME )) && [[ -f "$(schema_state_file "$db")" ]]; then
            log "$db: schema already imported (--resume), keeping loaded tables"
            DURATION_SCHEMA["$db"]=0
        else
            phase_start="$(date +%s)"
            if ! phase_schema "$db"; then
                DB_STATUS["$db"]="FAILED"
                DB_FAIL_REASON["$db"]="Schema phase failed"
                log_err "$db: schema phase failed, moving to next database"
                alarm "$db - ERROR: Schema phase failed"
                return 1
            fi
            phase_end="$(date +%s)"
            DURATION_SCHEMA["$db"]=$((phase_end - phase_start))
            if (( PER_TABLE )) && ! (( DRY_RUN )); then
                # Fresh schema = empty tables: forget per-table progress of earlier runs.
                mkdir -p "$STATE_DIR/$db"
                rm -f "$STATE_DIR/$db"/*.done
                date '+%Y-%m-%d %H:%M:%S' > "$(schema_state_file "$db")"
            fi
        fi

        phase_start="$(date +%s)"
        local data_rc=0
        if (( PER_TABLE )); then
            phase_data_per_table "$db" || data_rc=$?
        else
            phase_data "$db" || data_rc=$?
        fi
        if (( data_rc != 0 )); then
            DB_STATUS["$db"]="FAILED"
            DB_FAIL_REASON["$db"]="Data phase failed"
            log_err "$db: data phase failed, moving to next database"
            alarm "$db - ERROR: Data phase failed"
            return 1
        fi
        phase_end="$(date +%s)"
        DURATION_DATA["$db"]=$((phase_end - phase_start))
    fi

    phase_start="$(date +%s)"
    local objects_rc=0
    phase_objects "$db" || objects_rc=$?
    phase_end="$(date +%s)"
    DURATION_OBJECTS["$db"]=$((phase_end - phase_start))

    if (( objects_rc == 1 )); then
        DB_STATUS["$db"]="FAILED"
        DB_FAIL_REASON["$db"]="Objects phase failed"
        log_err "$db: objects phase failed"
        alarm "$db - ERROR: Objects phase failed"
        return 1
    elif (( objects_rc == 2 )); then
        DB_STATUS["$db"]="WARNING"
        DB_FAIL_REASON["$db"]="Object count mismatch (manual review recommended)"
        alarm "$db - WARNING: Object count mismatch, manual review needed"
    fi

    db_end="$(date +%s)"
    DURATION_TOTAL["$db"]=$((db_end - db_start))

    if (( ONLY_OBJECTS )); then
        # In --only-objects mode, skip row count verification (data wasn't touched).
        # Do NOT mark_done — schema/data still need a complete OK from a full run.
        if [[ "${DB_STATUS[$db]:-}" != "WARNING" ]]; then
            DB_STATUS["$db"]="OK"
        fi
    elif (( PER_TABLE )); then
        # Every table was already checked with an exact COUNT(*) against its dump;
        # the information_schema estimate comparison would only add false alarms.
        if [[ "${DB_STATUS[$db]:-}" != "WARNING" ]]; then
            DB_STATUS["$db"]="OK"
            mark_done "$db"
        fi
    else
        if ! verify_row_counts "$db"; then
            DB_STATUS["$db"]="WARNING"
            DB_FAIL_REASON["$db"]="Row count mismatch (data migrated, manual review recommended)"
            alarm "$db - WARNING: Row count mismatch, manual review needed"
        else
            if [[ "${DB_STATUS[$db]:-}" != "WARNING" ]]; then
                DB_STATUS["$db"]="OK"
                mark_done "$db"
            fi
        fi
    fi

    log "$db: migration complete ($(human_seconds "${DURATION_TOTAL[$db]}"))"
    alarm "$db - Migration complete, duration: $(human_seconds "${DURATION_TOTAL[$db]}")"

    return 0
}

### --- Reporting ------------------------------------------------------------

print_summary() {
    local total_time="$1"
    local ok=0 failed=0 warning=0 skipped=0
    local db status

    for db in "${SELECTED_DBS[@]}"; do
        status="${DB_STATUS[$db]:-NOT_RUN}"
        case "$status" in
            OK)       ((ok++))      || true ;;
            FAILED)   ((failed++))  || true ;;
            WARNING)  ((warning++)) || true ;;
            SKIPPED)  ((skipped++)) || true ;;
        esac
    done

    echo
    echo "==================== SUMMARY ===================="
    echo "Source DB : $SRC_VERSION_RAW ($SRC_FLAVOR)"
    echo "Target DB : $DST_VERSION_RAW ($DST_FLAVOR)"
    echo "mydumper  : $MYDUMPER_VERSION_RAW"
    echo "-------------------------------------------------"
    printf '%-20s %-10s %12s %12s %12s %12s\n' \
        "Database" "Status" "Schema" "Data" "Objects" "Total"
    printf '%-20s %-10s %12s %12s %12s %12s\n' \
        "--------------------" "----------" "------------" "------------" "------------" "------------"

    for db in "${SELECTED_DBS[@]}"; do
        printf '%-20s %-10s %12s %12s %12s %12s\n' \
            "$db" \
            "${DB_STATUS[$db]:-NOT_RUN}" \
            "$(human_seconds "${DURATION_SCHEMA[$db]:-0}")" \
            "$(human_seconds "${DURATION_DATA[$db]:-0}")" \
            "$(human_seconds "${DURATION_OBJECTS[$db]:-0}")" \
            "$(human_seconds "${DURATION_TOTAL[$db]:-0}")"

        if [[ -n "${DB_FAIL_REASON[$db]:-}" ]]; then
            printf '%22s└─ %s\n' "" "${DB_FAIL_REASON[$db]}"
        fi
    done

    echo "-------------------------------------------------"
    printf 'OK: %d | WARNING: %d | FAILED: %d | SKIPPED: %d\n' \
        "$ok" "$warning" "$failed" "$skipped"
    printf 'Total runtime: %s\n' "$(human_seconds "$total_time")"
    echo "================================================="
    echo

    if (( failed > 0 )); then
        return 1
    fi
    return 0
}

### --- Main -----------------------------------------------------------------

main() {
    parse_args "$@"
    setup_logging

    log "=============================================="
    log "MySQL/MariaDB to MariaDB migration tool"
    log "  Source host : $SRC_HOST"
    log "  Target host : $DST_HOST"
    log "  Directory   : $LOCAL_DIR"
    log "  Databases   : ${SELECTED_DBS[*]}"
    log "  Tuning      : schema_threads=$SCHEMA_THREADS data_threads=$DATA_THREADS rows=$DUMP_ROWS queue=$LOADER_QUEUE lock_mode=$DUMP_LOCK_MODE no_locks=$NO_LOCKS_FLAG long_query_guard=${LONG_QUERY_GUARD}s kill_long_queries=$KILL_LONG_QUERIES schema_charset=$SCHEMA_IMPORT_CHARSET"
    log "  Per-table   : per_table=$PER_TABLE delete_after_load=$DELETE_DUMP_AFTER_LOAD delete_unverified=$DELETE_UNVERIFIED_DUMPS table_disk_factor=$TABLE_DISK_SAFETY_FACTOR"
    log "  Flags       : dry-run=$DRY_RUN | resume=$RESUME | skip-verify=$SKIP_VERIFY | skip-version-check=$SKIP_VERSION_CHECK | only-objects=$ONLY_OBJECTS"
    log "=============================================="

    check_dependencies
    check_credentials
    discover_and_validate

    mkdir -p "$LOCAL_DIR" "$STATE_DIR"
    cd "$LOCAL_DIR"
    log "Changed working directory to $LOCAL_DIR"

    alarm "Migration started: ${SELECTED_DBS[*]} | $SRC_VERSION_RAW -> $DST_VERSION_RAW"

    local total_start total_end total_dur
    total_start="$(date +%s)"

    local db
    for db in "${SELECTED_DBS[@]}"; do
        migrate_db "$db" || true
    done

    total_end="$(date +%s)"
    total_dur=$((total_end - total_start))

    if print_summary "$total_dur"; then
        alarm "Migration complete (SUCCESS), duration: $(human_seconds "$total_dur")"
        log "Migration complete: SUCCESS"
        exit 0
    else
        alarm "Migration complete (WITH ERRORS), duration: $(human_seconds "$total_dur")"
        log_err "Migration complete: SOME DATABASES FAILED"
        exit 1
    fi
}

main "$@"
