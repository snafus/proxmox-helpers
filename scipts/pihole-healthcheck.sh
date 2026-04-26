#!/bin/bash
# =============================================================================
# Proxmox LXC Pi-hole Health Check
# Discovers containers via Proxmox tag, checks each one independently.
#
# Setup: tag any Pi-hole LXC in the Proxmox UI (Options > Tags) or via:
#   pct set 101 --tags pihole
#
# Add script to: /usr/local/bin/pihole-healthcheck.sh
#
# set crontab as: 
# */10 * * * * /usr/local/bin/pihole-healthcheck.sh >/dev/null 2>&1
#
# Usage: ./pihole-healthcheck.sh [--tag <tag>] [--dry-run]
#   --tag     Override the tag to search for (default: pihole)
#   --dry-run Report container status only; no exec or recovery actions taken
# =============================================================================

# Ensure consistent PATH regardless of how the script is invoked (cron, shell, etc.)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Strict mode — see inline comments for intentional non-zero guard patterns
set -euo pipefail

# --- Configuration -----------------------------------------------------------
VERSION="1.0.0"
PIHOLE_TAG="pihole"
FTL_PROCESS_NAME="pihole-FTL"          # update if Pi-hole renames this
FTL_SERVICE_NAME="pihole-FTL"          # update if service name changes
PIHOLE_LOG_PATHS=(                     # update if log paths move (v5 vs v6+)
    /var/log/pihole/pihole.log
    /var/log/pihole/FTL.log
    /var/log/pihole.log
    /var/log/lighttpd/access.log
    /var/log/lighttpd/error.log
)
TEST_DOMAINS=("google.com" "cloudflare.com" "github.com")
DNS_SERVER="127.0.0.1"
LOG_FILE="/var/log/pihole-healthcheck.log"
MAX_LOG_SIZE_MB=10
DNS_TIMEOUT=5
DNS_RETRIES=2
START_WAIT=15
RESTART_WAIT=20
FTL_RESTART_WAIT=5
PCT_STOP_TIMEOUT=30                    # seconds before pct stop is considered hung
LOCK_FILE="/tmp/pihole-healthcheck.lock"
LOCK_TIMEOUT=300                       # stale lock age (seconds) before removal
DISK_WARN_PCT=80                       # warn when any mountpoint exceeds this %
DISK_CRITICAL_PCT=95                   # attempt log cleanup above this %
DRY_RUN=false

_HEALTHY=0
_RECOVERED=0
_FAILED=0
_SKIPPED=0

# --- Argument Parsing --------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)
                # Bug fix: guard against --tag with no following value
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: --tag requires a value" >&2; exit 2
                fi
                PIHOLE_TAG="$2"; shift 2
                ;;
            --dry-run) DRY_RUN=true; shift ;;
            *) echo "Unknown argument: $1" >&2; exit 2 ;;
        esac
    done
}

# --- Logging -----------------------------------------------------------------
CTID="GLOBAL"
JOURNALD_IDENTIFIER="pihole-healthcheck"

# Map our levels to systemd priorities for journald:
#   journalctl -t pihole-healthcheck -p warning   (WARN + ERROR only)
#   journalctl -t pihole-healthcheck              (everything)
_journal_priority() {
    case "$1" in
        ERROR) echo "err"     ;;
        WARN)  echo "warning" ;;
        *)     echo "info"    ;;
    esac
}

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local prefix="${ts} [${level}]"
    [[ "$CTID" != "GLOBAL" ]] && prefix+=" CT${CTID}"
    local line="${prefix}: ${msg}"

    # Write directly to file and stderr — never via stdout.
    # stdout is reserved for data (CTIDs from discover_ctids) so that
    # mapfile never captures log lines as container IDs.
    echo "$line" >> "$LOG_FILE" || true   # non-fatal if log write fails
    echo "$line" >&2

    # Write to systemd journal with correct priority (optional dependency)
    if command -v systemd-cat &>/dev/null; then
        echo "$line" | systemd-cat -t "$JOURNALD_IDENTIFIER" \
            -p "$(_journal_priority "$level")" || true
    fi
}

rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size_mb
    size_mb=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1) || return 0
    if (( size_mb >= MAX_LOG_SIZE_MB )); then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log INFO "Log rotated (was ${size_mb}MB)"
    fi
}

# --- Preflight Checks --------------------------------------------------------
check_log_writable() {
    # Verify log file is writable before anything else — a bad log path would
    # cause every log() call to silently fail under set -e and kill the script
    local log_dir; log_dir="$(dirname "$LOG_FILE")"
    if [[ ! -d "$log_dir" ]]; then
        echo "Error: log directory ${log_dir} does not exist" >&2; exit 2
    fi
    if ! touch "$LOG_FILE" 2>/dev/null; then
        echo "Error: cannot write to log file ${LOG_FILE}" >&2; exit 2
    fi
}

check_dependencies() {
    local missing=()
    for cmd in pct awk grep dig stat du; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "Missing required commands: ${missing[*]}"
        exit 2
    fi
    # systemd-cat is optional — warn but continue
    if ! command -v systemd-cat &>/dev/null; then
        log WARN "systemd-cat not found — journal logging disabled."
    fi
}

# --- Lock Management ---------------------------------------------------------
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local locked_pid
        locked_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)

        # Check if the locking PID is actually still alive
        if [[ "$locked_pid" =~ ^[0-9]+$ ]] && kill -0 "$locked_pid" 2>/dev/null; then
            log WARN "Another instance is running (PID ${locked_pid}). Exiting."
            exit 0
        fi

        # PID is dead — stale lock, remove it
        local lock_age now mtime
        now=$(date +%s) || now=0
        mtime=$(stat -c %Y "$LOCK_FILE" 2>/dev/null) || mtime=0
        lock_age=$(( now - mtime )) || lock_age=0
        log WARN "Removing stale lock (dead PID ${locked_pid}, age: ${lock_age}s)"
        rm -f "$LOCK_FILE"
    fi

    # Use noclobber to make lock creation atomic — prevents race condition
    # between two simultaneous invocations both passing the existence check
    (set -o noclobber; echo $$ > "$LOCK_FILE") 2>/dev/null || {
        log WARN "Lock race detected — another instance just acquired the lock. Exiting."
        exit 0
    }
}

release_lock() { rm -f "$LOCK_FILE" || true; }

# --- Tag-based Discovery -----------------------------------------------------
discover_ctids() {
    local -a found=()
    local conf ctid

    if [[ ! -d /etc/pve/lxc ]]; then
        log ERROR "/etc/pve/lxc not found — is this running on a Proxmox host?"
        exit 2
    fi

    for conf in /etc/pve/lxc/*.conf; do
        [[ -f "$conf" ]] || continue
        # Proxmox stores tags semicolon-separated: "tags: foo;pihole;bar"
        if grep -qiE "^tags:.*(\b|;)${PIHOLE_TAG}(\b|;|$)" "$conf" 2>/dev/null; then
            ctid="${conf##*/}"; ctid="${ctid%.conf}"
            found+=("$ctid")
        fi
    done

    if [[ ${#found[@]} -eq 0 ]]; then
        log ERROR "No containers tagged '${PIHOLE_TAG}' found. Nothing to do."
        log ERROR "Tag a container with: pct set <CTID> --tags ${PIHOLE_TAG}"
        exit 2
    fi

    log INFO "Discovered ${#found[@]} container(s) tagged '${PIHOLE_TAG}': ${found[*]}"
    # Only data goes to stdout — log() above writes to file+stderr only
    printf '%s\n' "${found[@]}"
}

# --- Helpers (all operate on the current $CTID) ------------------------------
get_status() {
    # Return empty string (not error) if pct status fails — callers check the value
    pct status "$CTID" 2>/dev/null | awk '{print $2}' || echo ""
}

container_exists() { pct status "$CTID" &>/dev/null; }

exec_in_ct() {
    if $DRY_RUN; then
        log INFO "[dry-run] would exec in CT${CTID}: $*"
        return 0
    fi
    # Explicit PATH — pct exec uses a minimal environment that omits
    # /usr/local/bin where the pihole binary lives
    pct exec "$CTID" -- \
        env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

pct_action() {
    if $DRY_RUN; then
        log INFO "[dry-run] would run: pct $*"
        return 0
    fi
    # Write pct output to log file and stderr only — not stdout
    pct "$@" >> "$LOG_FILE" 2>&1
}

wait_for_running() {
    local wait_secs="$1" elapsed=0
    $DRY_RUN && return 0
    while (( elapsed < wait_secs )); do
        [[ "$(get_status)" == "running" ]] && return 0
        sleep 2
        (( elapsed += 2 )) || true   # (( n += 2 )) returns 1 when result is 0; guard with || true
    done
    return 1
}

# --- Health Checks -----------------------------------------------------------
# All check_* functions are called with `if !` or `|| disk_status=$?` guards
# so set -e does not misfire on an expected non-zero return.

check_dns() {
    local successes=0
    for domain in "${TEST_DOMAINS[@]}"; do
        if exec_in_ct dig @"$DNS_SERVER" "$domain" +short \
               +time="$DNS_TIMEOUT" +tries=1 > /dev/null 2>&1; then
            (( successes++ )) || true   # arithmetic increment guarded: 0+1 is truthy but guard is safe
            [[ $successes -ge $DNS_RETRIES ]] && return 0
        fi
    done
    return 1
}

check_ftl() {
    exec_in_ct pgrep -x "$FTL_PROCESS_NAME" > /dev/null 2>&1 || return 1
}

check_web_interface() {
    exec_in_ct pgrep -x lighttpd > /dev/null 2>&1 || return 1
}

check_disk() {
    # Returns: 0=ok  1=critical (>=DISK_CRITICAL_PCT)  2=warning (>=DISK_WARN_PCT)
    # Callers must use:  check_disk || disk_status=$?
    # to avoid set -e aborting on the non-zero warning return code
    local worst=0
    local line use_pct mount

    while IFS= read -r line; do
        use_pct=$(echo "$line" | awk '{gsub(/%/,"",$5); print $5}') || continue
        mount=$(echo "$line"   | awk '{print $6}') || continue
        [[ "$use_pct" =~ ^[0-9]+$ ]] || continue

        if (( use_pct >= DISK_CRITICAL_PCT )); then
            log WARN "Disk critical: ${mount} is ${use_pct}% full — attempting log cleanup."
            worst=1
        elif (( use_pct >= DISK_WARN_PCT )); then
            log WARN "Disk warning: ${mount} is ${use_pct}% full (threshold: ${DISK_WARN_PCT}%)."
            (( worst < 1 )) && worst=2 || true
        fi
    done < <(exec_in_ct df -P 2>/dev/null | \
             awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs|udev)/' || true)

    return $worst
}

cleanup_disk() {
    # Truncate Pi-hole logs to recover space — never touches the FTL database.
    log WARN "Attempting log cleanup to recover disk space..."
    local freed=false
    local size  # declared outside loop — 'local' inside a loop masks assignment errors

    for f in "${PIHOLE_LOG_PATHS[@]}"; do
        if exec_in_ct test -f "$f" 2>/dev/null; then
            size=$(exec_in_ct du -sh "$f" 2>/dev/null | awk '{print $1}') || size="unknown"
            if exec_in_ct truncate -s 0 "$f" 2>/dev/null; then
                log INFO "Truncated ${f} (was ${size})."
                freed=true
            fi
        fi
    done

    # Remove compressed logs older than 7 days — handle missing dirs gracefully
    # Count deleted files so we only log if something was actually removed
    local gz_count=0
    local found_gz  # declared outside loop — local inside a loop masks assignment errors
    for logdir in /var/log/pihole /var/log; do
        if exec_in_ct test -d "$logdir" 2>/dev/null; then
            found_gz=$(exec_in_ct find "$logdir" -maxdepth 1 \
                -name "*.gz" -mtime +7 2>/dev/null | wc -l) || found_gz=0
            if (( found_gz > 0 )); then
                exec_in_ct find "$logdir" -maxdepth 1 \
                    -name "*.gz" -mtime +7 -delete 2>/dev/null || true
                (( gz_count += found_gz )) || true
            fi
        fi
    done
    (( gz_count > 0 )) && log INFO "Removed ${gz_count} compressed log(s) older than 7 days." || true

    if $freed; then
        log INFO "Log cleanup complete."
        return 0
    fi

    log ERROR "Log cleanup found nothing to truncate."
    return 1
}

# --- Actions -----------------------------------------------------------------
start_container() {
    log INFO "Container is stopped. Starting..."
    if ! pct_action start "$CTID"; then
        log ERROR "pct start failed."
        return 1
    fi
    if wait_for_running "$START_WAIT"; then
        log INFO "Container started successfully."
        return 0
    fi
    log ERROR "Container did not reach running state within ${START_WAIT}s."
    return 1
}

restart_container() {
    log WARN "Restarting container..."
    # 'pct restart' unavailable on all Proxmox versions — use stop + start.
    # --timeout prevents pct stop hanging indefinitely on a stuck container.
    if ! pct_action stop "$CTID" --timeout "$PCT_STOP_TIMEOUT"; then
        log ERROR "pct stop failed."
        return 1
    fi
    $DRY_RUN || sleep 3
    if ! pct_action start "$CTID"; then
        log ERROR "pct start failed."
        return 1
    fi
    if wait_for_running "$RESTART_WAIT"; then
        log INFO "Container restarted successfully. Waiting ${RESTART_WAIT}s for services..."
        $DRY_RUN || sleep "$RESTART_WAIT"
        return 0
    fi
    log ERROR "Container did not reach running state within ${RESTART_WAIT}s."
    return 1
}

restart_ftl() {
    log WARN "Attempting to restart ${FTL_SERVICE_NAME}..."
    # Use service directly — works across Pi-hole v5 and v6+
    # (pihole restartdns was removed in v6)
    # Capture output through log() so it gets timestamps and prefixes
    local svc_output
    svc_output=$(exec_in_ct service "$FTL_SERVICE_NAME" restart 2>&1) || {
        log ERROR "${FTL_SERVICE_NAME} service restart command failed."
        [[ -n "$svc_output" ]] && log ERROR "Output: ${svc_output}"
        return 1
    }
    [[ -n "$svc_output" ]] && log INFO "Service output: ${svc_output}"
    sleep "$FTL_RESTART_WAIT"
    if check_ftl; then
        log INFO "${FTL_SERVICE_NAME} restarted successfully."
        return 0
    fi
    log ERROR "${FTL_SERVICE_NAME} still not running after restart."
    return 1
}

# --- Per-container Health Check ----------------------------------------------
# Returns 0 = healthy or recovered, 1 = unrecoverable
check_container() {
    local ctid="$1"
    CTID="$ctid"
    local something_was_wrong=false

    log INFO "--- Starting health check ---"

    # 1. Verify container exists on this host
    if ! container_exists; then
        log ERROR "Container does not exist on this host. Skipping."
        (( _FAILED++ )) || true
        return 1
    fi

    # 2. Ensure container is running
    local status; status="$(get_status)"
    # Default status label if get_status returns empty
    local status_label="${status:-unknown}"
    if [[ "$status" != "running" ]]; then
        log WARN "Container status is '${status_label}'."
        something_was_wrong=true
        if ! start_container; then
            log ERROR "Failed to start container. Manual intervention required."
            (( _FAILED++ )) || true
            return 1
        fi
        log INFO "Waiting ${START_WAIT}s for services to initialise..."
        $DRY_RUN || sleep "$START_WAIT"
        status="running"
        status_label="running"
    fi

    # Dry-run stops here — container status above is real, but we won't
    # exec into the container or take any recovery action
    if $DRY_RUN; then
        log INFO "[dry-run] CT${CTID} is ${status_label} — would check disk, FTL, DNS, and lighttpd"
        log INFO "--- CT${CTID} not checked (dry-run) ---"
        (( _SKIPPED++ )) || true
        return 0
    fi

    # 3. Check disk space first — a full disk is the most likely root cause of
    #    FTL dying or DNS failing. Fix it before chasing symptoms.
    # check_disk returns 2 for warning (non-zero), so must use || pattern
    local disk_status=0
    check_disk || disk_status=$?
    if (( disk_status == 1 )); then
        something_was_wrong=true
        local post_cleanup_status=0
        if cleanup_disk; then
            check_disk || post_cleanup_status=$?
            if (( post_cleanup_status == 1 )); then
                log ERROR "Disk still critical after cleanup. Manual intervention required."
                (( _FAILED++ )) || true
                return 1
            else
                log INFO "Disk space recovered after log cleanup."
            fi
        else
            log ERROR "Disk critical and cleanup failed. Manual intervention required."
            (( _FAILED++ )) || true
            return 1
        fi
    fi

    # 4. Check FTL process (fast check before DNS)
    if ! check_ftl; then
        log WARN "${FTL_PROCESS_NAME} is not running."
        something_was_wrong=true
        if ! restart_ftl; then
            log WARN "FTL restart failed — escalating to container restart."
            if ! restart_container; then
                log ERROR "Container restart failed. Manual intervention required."
                (( _FAILED++ )) || true
                return 1
            fi
            sleep "$FTL_RESTART_WAIT"
        fi
    fi

    # 5. Check DNS resolution
    if ! check_dns; then
        log WARN "DNS resolution failed for all ${#TEST_DOMAINS[@]} test domains."
        something_was_wrong=true

        if check_ftl; then
            log WARN "FTL is running but DNS is broken — restarting DNS service."
            if restart_ftl; then
                sleep "$FTL_RESTART_WAIT"
                if ! check_dns; then
                    log WARN "DNS still failing after FTL restart — escalating to container restart."
                    if ! restart_container; then
                        log ERROR "Container restart failed. Manual intervention required."
                        (( _FAILED++ )) || true
                        return 1
                    fi
                else
                    log INFO "DNS recovered after FTL restart."
                fi
            else
                log WARN "FTL restart failed — escalating to container restart."
                if ! restart_container; then
                    log ERROR "Container restart failed. Manual intervention required."
                    (( _FAILED++ )) || true
                    return 1
                fi
            fi
        else
            if ! restart_container; then
                log ERROR "Container restart failed. Manual intervention required."
                (( _FAILED++ )) || true
                return 1
            fi
        fi
    fi

    # 6. Warn if web interface is down (non-fatal — DNS still works without it)
    if ! check_web_interface; then
        log WARN "lighttpd (web interface) not running. DNS is OK; check manually."
    fi

    if $something_was_wrong; then
        log INFO "--- CT${CTID} recovered ---"
        (( _RECOVERED++ )) || true
    else
        log INFO "--- CT${CTID} healthy ---"
        (( _HEALTHY++ )) || true
    fi
    return 0
}

# --- Main --------------------------------------------------------------------
main() {
    parse_args "$@"

    # Check log is writable before anything else — a bad log path would cause
    # every log() call to silently fail and kill the script under set -e
    check_log_writable

    rotate_log
    check_dependencies
    acquire_lock
    # trap is registered AFTER acquire_lock. Any exit before this point
    # (parse_args, check_log_writable, rotate_log, check_dependencies,
    # acquire_lock itself) never held the lock, so skipping release is correct.
    trap release_lock EXIT

    $DRY_RUN && log INFO "=== DRY-RUN MODE: no changes will be made ==="
    log INFO "=== Pi-hole health check v${VERSION} started (tag: ${PIHOLE_TAG}) ==="

    mapfile -t CTIDS < <(discover_ctids)

    # Check each container independently — failure in one does not abort the rest
    for ctid in "${CTIDS[@]}"; do
        check_container "$ctid" || true
    done

    CTID="GLOBAL"
    log INFO "=== Run complete: healthy=${_HEALTHY}  recovered=${_RECOVERED}  failed=${_FAILED}  skipped(dry-run)=${_SKIPPED} ==="

    # Bug fix: (( 0 > 0 )) returns exit code 1 under set -e — use if/then instead
    if (( _FAILED > 0 )); then
        exit 1
    fi
    exit 0
}

main "$@"
