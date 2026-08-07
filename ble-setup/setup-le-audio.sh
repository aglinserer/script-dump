#!/usr/bin/env bash
#
# setup-le-audio.sh — configure an Ubuntu 26.04 host for Bluetooth LE Audio
# (BAP/CAP, LC3) via PipeWire/WirePlumber + BlueZ.
#
# Usage:
#   ./setup-le-audio.sh <subcommand> [role]
#
# Roles:
#   central     Source: this machine streams audio OUT to an LE Audio
#               earbud/speaker (a2dp_source + bap_source). This is the default.
#   peripheral  Sink: this machine acts AS an LE Audio speaker/acceptor that
#               other devices stream to (a2dp_sink + bap_sink).
#   (Only 'configure_pipewire' and 'configure_advertising' use the role.)
#
# Subcommands:
#   configure_pipewire [role]    Write WirePlumber/PipeWire LE Audio fragments
#                                (LC3/BAP roles) under /etc, per role.
#   configure_bluetooth          Enable BlueZ 'Experimental' D-Bus interfaces and
#                                the ISO-Socket experimental kernel feature only.
#   restart_audio                Restart the user pipewire, pipewire-pulse and
#                                wireplumber services (runs as the login user).
#   restart_bluetooth            Restart the system bluetooth service.
#   configure_advertising [role] Drive bluetoothctl to advertise/prepare for the
#                                chosen role (peripheral advertises; central scans).
#   print_uuids                  Print the controller's own UUIDs and the UUIDs of
#                                every currently connected device.
#   all [role]                   Run the configure steps then restart services.
#   help                         Show this help.
#
# Examples:
#   # 1) Set up this machine as the SOURCE (stream out to LE Audio earbuds):
#   ./setup-le-audio.sh all central
#
#   # 2) Set up this machine as the SINK (act as an LE Audio speaker/acceptor):
#   ./setup-le-audio.sh all peripheral
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# BlueZ experimental kernel feature UUID for the ISO Socket (LE Audio).
readonly ISO_SOCKET_UUID="6fbaf188-05e0-496a-9885-d6ddfdb4e03e"

readonly BLUETOOTH_MAIN_CONF="/etc/bluetooth/main.conf"
readonly WIREPLUMBER_FRAGMENT="/etc/wireplumber/wireplumber.conf.d/51-bluez-le-audio.conf"
readonly PIPEWIRE_FRAGMENT="/etc/pipewire/pipewire.conf.d/51-bluez-le-audio.conf"

# Original invocation, preserved so we can re-exec under sudo cleanly.
readonly ORIG_ARGS=("$@")

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

info() { printf '\033[1;32m[*]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Privilege helpers
# ---------------------------------------------------------------------------

# Re-exec the whole script under sudo if we are not already root.
require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || die "This step needs root and sudo is not available."
        info "Elevating privileges with sudo..."
        exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
    fi
}

# Ensure the current command runs as the login user (needed for systemctl --user).
# If invoked via sudo/as root, drop back down to \$SUDO_USER with a working
# user session bus.
require_login_user() {
    if [[ ${EUID} -eq 0 ]]; then
        local u="${SUDO_USER:-}"
        [[ -n "${u}" ]] || die "restart_audio must be run as your normal user, not root."
        local uid
        uid="$(id -u "${u}")"
        info "Dropping to login user '${u}' for --user services..."
        exec sudo -u "${u}" \
            XDG_RUNTIME_DIR="/run/user/${uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            bash "$0" restart_audio
    fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------

# Timestamped backup of a file, if it exists.
backup_file() {
    local f="$1"
    if [[ -f "${f}" ]]; then
        local b
        b="${f}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "${f}" "${b}"
        info "Backed up ${f} -> ${b}"
    fi
}

# Idempotently set 'key = value' under [section] in an INI file.
# Replaces an existing (or commented-out) key in that section, otherwise
# appends it; creates the section/file if missing.
ensure_ini_kv() {
    local file="$1" section="$2" key="$3" value="$4"
    if [[ ! -f "${file}" ]]; then
        mkdir -p "$(dirname "${file}")"
        : > "${file}"
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v section="${section}" -v key="${key}" -v value="${value}" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        BEGIN { in_section = 0; done = 0; sect_found = 0 }
        {
            t = trim($0)
            if (t ~ /^\[.*\]$/) {
                # About to leave a section header: if we were in the target
                # section and never wrote the key, write it before this header.
                if (in_section == 1 && done == 0) { print key " = " value; done = 1 }
                if (t == "[" section "]") { in_section = 1; sect_found = 1 }
                else { in_section = 0 }
                print $0
                next
            }
            if (in_section == 1) {
                kt = t
                sub(/^#[ \t]*/, "", kt)           # tolerate commented key
                if (kt ~ ("^" key "[ \t]*=")) {
                    if (done == 0) { print key " = " value; done = 1 }
                    next                           # drop old/commented line
                }
            }
            print $0
        }
        END {
            if (sect_found == 0) {
                print "[" section "]"
                print key " = " value
            } else if (in_section == 1 && done == 0) {
                print key " = " value
            }
        }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
    info "Set [${section}] ${key} = ${value} in ${file}"
}

# ---------------------------------------------------------------------------
# Role helpers
# ---------------------------------------------------------------------------

# Normalise/validate the role argument (default: central).
normalize_role() {
    local role="${1:-central}"
    case "${role}" in
        central|peripheral) printf '%s' "${role}" ;;
        *) die "Invalid role: '${role}' (expected 'central' or 'peripheral')." ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. configure_pipewire — WirePlumber/PipeWire LE Audio fragments
# ---------------------------------------------------------------------------

configure_pipewire() {
    require_root
    local role
    role="$(normalize_role "${1:-central}")"

    local roles
    case "${role}" in
        central)    roles='[ a2dp_source bap_source hfp_ag ]' ;;
        peripheral) roles='[ a2dp_sink bap_sink hfp_hf ]' ;;
    esac

    mkdir -p "$(dirname "${WIREPLUMBER_FRAGMENT}")"
    cat > "${WIREPLUMBER_FRAGMENT}" <<EOF
# Managed by setup-le-audio.sh — Bluetooth LE Audio (role: ${role})
# WirePlumber 0.5+ SPA-JSON configuration fragment.
monitor.bluez.properties = {
  # LE Audio (BAP) is enabled purely via the bap_* roles below. There is no
  # "enable-lc3" property and lc3 is not an A2DP codec, so neither is set here.
  bluez5.enable-sbc-xq    = true
  bluez5.enable-msbc      = true
  bluez5.enable-hw-volume = true
  bluez5.roles            = ${roles}
}
EOF
    info "Wrote ${WIREPLUMBER_FRAGMENT}"

    mkdir -p "$(dirname "${PIPEWIRE_FRAGMENT}")"
    cat > "${PIPEWIRE_FRAGMENT}" <<EOF
# Managed by setup-le-audio.sh — Bluetooth LE Audio (role: ${role})
# The BlueZ monitor's codec/role settings live in the WirePlumber fragment:
#   ${WIREPLUMBER_FRAGMENT}
# This file is kept so both config trees are managed together.
EOF
    info "Wrote ${PIPEWIRE_FRAGMENT}"
    info "PipeWire/WirePlumber configured for LE Audio (${role}). Run 'restart_audio' to apply."
}

# ---------------------------------------------------------------------------
# 2. configure_bluetooth — Experimental + ISO-Socket kernel feature
# ---------------------------------------------------------------------------

configure_bluetooth() {
    require_root
    backup_file "${BLUETOOTH_MAIN_CONF}"
    # Experimental userspace/D-Bus interfaces required by LE Audio.
    ensure_ini_kv "${BLUETOOTH_MAIN_CONF}" "General" "Experimental" "true"
    # Scope experimental *kernel* features to ONLY the ISO Socket (LE Audio),
    # rather than enabling all kernel experimental features.
    ensure_ini_kv "${BLUETOOTH_MAIN_CONF}" "General" "KernelExperimental" "${ISO_SOCKET_UUID}"
    info "BlueZ configured. Run 'restart_bluetooth' to apply."
}

# ---------------------------------------------------------------------------
# 3. restart_audio — pipewire + pipewire-pulse + wireplumber
# ---------------------------------------------------------------------------

restart_audio() {
    require_login_user
    need_cmd systemctl
    info "Restarting user audio services (pipewire, pipewire-pulse, wireplumber)..."
    systemctl --user restart pipewire pipewire-pulse wireplumber
    info "Audio services restarted."
}

# ---------------------------------------------------------------------------
# 4. restart_bluetooth — the system bluetooth service
# ---------------------------------------------------------------------------

restart_bluetooth() {
    require_root
    need_cmd systemctl
    info "Restarting bluetooth service..."
    systemctl restart bluetooth
    info "Bluetooth service restarted."
}

# ---------------------------------------------------------------------------
# 5. configure_advertising — bluetoothctl advertising setup
# ---------------------------------------------------------------------------

configure_advertising() {
    local role
    role="$(normalize_role "${1:-central}")"
    need_cmd bluetoothctl

    if [[ "${role}" == "peripheral" ]]; then
        info "Configuring bluetoothctl to advertise as an LE Audio peripheral..."
        # LE Audio service UUIDs advertised by an acceptor/sink:
        #   0x1850 PACS  (Published Audio Capabilities Service)
        #   0x184E ASCS  (Audio Stream Control Service)
        #   0x1853 CAS   (Common Audio Service)
        bluetoothctl <<'EOF'
power on
pairable on
agent on
default-agent
menu advertise
appearance 0x0941
name le-audio-sink
uuids 0x1850 0x184E 0x1853
discoverable on
back
advertise peripheral
EOF
        info "Peripheral advertising enabled (LE Audio acceptor)."
    else
        info "Configuring bluetoothctl for LE Audio central/source role..."
        bluetoothctl <<'EOF'
power on
pairable on
agent on
default-agent
discoverable off
EOF
        info "Central role ready. To find peripherals run: bluetoothctl scan le"
    fi
}

# ---------------------------------------------------------------------------
# 6. print_uuids — controller + connected-device UUIDs
# ---------------------------------------------------------------------------

print_uuids() {
    need_cmd bluetoothctl

    printf '\n=== Controller (self) UUIDs ===\n'
    if ! bluetoothctl show | grep -E 'UUID:' || true; then
        warn "No controller UUIDs found (is the adapter powered on?)"
    fi

    printf '\n=== Connected device UUIDs ===\n'
    local devices mac name
    devices="$(bluetoothctl devices Connected 2>/dev/null || true)"
    if [[ -z "${devices}" ]]; then
        info "No connected devices."
        return 0
    fi

    while read -r _ mac name; do
        [[ -n "${mac}" ]] || continue
        printf '\n--- %s (%s) ---\n' "${mac}" "${name:-unknown}"
        bluetoothctl info "${mac}" | grep -E 'UUID:' || info "  (no UUIDs reported)"
    done <<< "${devices}"
}

# ---------------------------------------------------------------------------
# Convenience: run everything in order
# ---------------------------------------------------------------------------

run_all() {
    local role
    role="$(normalize_role "${1:-central}")"
    configure_pipewire "${role}"
    configure_bluetooth
    restart_bluetooth
    configure_advertising "${role}"
    # restart_audio last: it must run as the login user, so invoke a fresh,
    # non-root instance rather than calling the function under sudo.
    if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
        info "Restarting audio as ${SUDO_USER}..."
        local uid
        uid="$(id -u "${SUDO_USER}")"
        sudo -u "${SUDO_USER}" \
            XDG_RUNTIME_DIR="/run/user/${uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            bash "$0" restart_audio
    else
        restart_audio
    fi
    info "All LE Audio setup steps complete (role: ${role})."
}

# ---------------------------------------------------------------------------
# Usage / dispatcher
# ---------------------------------------------------------------------------

usage() {
    # Print the contiguous comment header (after the shebang), stripping '# '.
    awk 'NR == 1 { next }
         /^#/   { sub(/^# ?/, ""); print; next }
         { exit }' "$0"
}

main() {
    local subcommand="${1:-help}"
    shift || true

    case "${subcommand}" in
        configure_pipewire)    configure_pipewire "$@" ;;
        configure_bluetooth)   configure_bluetooth ;;
        restart_audio)         restart_audio ;;
        restart_bluetooth)     restart_bluetooth ;;
        configure_advertising) configure_advertising "$@" ;;
        print_uuids)           print_uuids ;;
        all)                   run_all "$@" ;;
        help|-h|--help)        usage ;;
        *)                     err "Unknown subcommand: ${subcommand}"; usage; exit 2 ;;
    esac
}

main "$@"
