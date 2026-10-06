#!/usr/bin/env bash
#
# RustDesk Client Updater - Linux (Bash)
# Version: 2.0.0
# Author:  https://github.com/Leproide
#
# Copyright (C) 2026  https://github.com/Leproide
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# ---------------------------------------------------------------------------
# Publishes the latest RustDesk clients for Windows, macOS and Linux in a
# directory (typically a web root):
#   - Windows executables carry the server configuration in their file name
#     (the only platform where RustDesk reads it from the file name);
#   - macOS/Linux packages get stable names, and the server configuration is
#     exported in a JSON manifest (rustdesk.json) used by the download page,
#     which tells users how to import it.
# See README.md or run with --help.
#
# Exit codes:
#   0  Success (updated, already up to date, or another run in progress)
#   1  Runtime error (network, verification, file replacement, ...)
#   2  Configuration error (invalid or missing options, missing dependency)
#   3  Updated, but some platforms were skipped (asset not found)
#
# Requirements: bash 4+, curl, jq, coreutils (sha256sum, mktemp, tail, od).
# Optional:     flock (util-linux) to prevent concurrent runs.
# ---------------------------------------------------------------------------

set -Eeuo pipefail
umask 022

readonly SCRIPT_NAME="${0##*/}"
readonly USER_AGENT="rustdesk-client-updater"
readonly VER='[0-9]+(\.[0-9]+)*'

# ---------------------------------------------------------------------------
# Platform catalog
#   ASSET_RX: regex on GitHub asset names
#   FILE:     published file name (empty = generated Windows name)
#   WIN_PREFIX: file name prefix for Windows targets
# ---------------------------------------------------------------------------
readonly CATALOG_ORDER=(windows-x64 windows-arm64 macos-arm64 macos-x64
    linux-x64-deb linux-arm64-deb linux-x64-rpm linux-arm64-rpm
    linux-x64-suse-rpm linux-arm64-suse-rpm linux-x64-appimage linux-arm64-appimage)
declare -A ASSET_RX=(
    [windows-x64]="^rustdesk-${VER}-x86_64\\.exe\$"
    [windows-arm64]="^rustdesk-${VER}-aarch64\\.exe\$"
    [macos-arm64]="^rustdesk-${VER}-aarch64\\.dmg\$"
    [macos-x64]="^rustdesk-${VER}-x86_64\\.dmg\$"
    [linux-x64-deb]="^rustdesk-${VER}-x86_64\\.deb\$"
    [linux-arm64-deb]="^rustdesk-${VER}-aarch64\\.deb\$"
    [linux-x64-rpm]="^rustdesk-${VER}-[0-9]+\\.x86_64\\.rpm\$"
    [linux-arm64-rpm]="^rustdesk-${VER}-[0-9]+\\.aarch64\\.rpm\$"
    [linux-x64-suse-rpm]="^rustdesk-${VER}-[0-9]+\\.x86_64-suse\\.rpm\$"
    [linux-arm64-suse-rpm]="^rustdesk-${VER}-[0-9]+\\.aarch64-suse\\.rpm\$"
    [linux-x64-appimage]="^rustdesk-${VER}-x86_64\\.AppImage\$"
    [linux-arm64-appimage]="^rustdesk-${VER}-aarch64\\.AppImage\$"
)
declare -A FILE=(
    [windows-x64]="" [windows-arm64]=""
    [macos-arm64]="rustdesk-macos-arm64.dmg" [macos-x64]="rustdesk-macos-x64.dmg"
    [linux-x64-deb]="rustdesk-linux-x64.deb" [linux-arm64-deb]="rustdesk-linux-arm64.deb"
    [linux-x64-rpm]="rustdesk-linux-x64.rpm" [linux-arm64-rpm]="rustdesk-linux-arm64.rpm"
    [linux-x64-suse-rpm]="rustdesk-linux-x64-suse.rpm" [linux-arm64-suse-rpm]="rustdesk-linux-arm64-suse.rpm"
    [linux-x64-appimage]="rustdesk-linux-x64.AppImage" [linux-arm64-appimage]="rustdesk-linux-arm64.AppImage"
)
declare -A WIN_PREFIX=([windows-x64]="rustdesk" [windows-arm64]="rustdesk-arm64")

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TARGET_DIR=""
SERVER_HOST=""
KEY=""
RELAY_SERVER=""
CONFIG_RELAY=""
API_SERVER=""
PLATFORMS="windows-x64,macos-arm64,macos-x64,linux-x64-deb,linux-x64-rpm,linux-x64-appimage"
NAME_STYLE="auto"
REPOSITORY="rustdesk/rustdesk"
STATE_DIR=""
KEEP_BACKUPS=1
WRITE_UPDATE_LOG=true
UPDATE_LOG_NAME="update.log"
MANIFEST_NAME="rustdesk.json"
FILE_MODE="0644"
OWNER=""
FORCE=false
QUIET=false

# Runtime globals
INSTANCE_ID="-"
LOG_FILE=""
TMP_DIR=""
STAGING_FILE=""
SELECTED=()
PARTIAL=false
declare -A PUBLISH_NAME=()

# ---------------------------------------------------------------------------
# Help and argument handling
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME --target-dir DIR --server-host HOST --key KEY [options]

Publishes the latest RustDesk clients (Windows, macOS, Linux) in DIR, with the
server configuration embedded in the Windows file names and exported in a JSON
manifest for the download page.

Server:
  -d, --target-dir DIR       Directory where the clients are published (required)
  -s, --server-host HOST     RustDesk ID server (hbbs) host or IP (required)
  -k, --key KEY              RustDesk server public key, id_ed25519.pub (required)
      --relay HOST[:PORT]    Relay server (hbbr). Default: ID server host in the
                             macOS/Linux configuration, omitted in Windows names
      --api URL              API server URL (Server Pro / compatible)

Publishing:
  -P, --platforms LIST       Comma-separated platforms (default: $PLATFORMS)
                             Available: ${CATALOG_ORDER[*]}
      --name-style STYLE     Windows file names: auto|plain|encoded (default: $NAME_STYLE)
  -r, --repository OWNER/REPO  GitHub repository (default: $REPOSITORY)
      --manifest-name NAME   JSON manifest file name (default: $MANIFEST_NAME)
      --mode MODE            Permissions of published files (default: $FILE_MODE)
      --owner USER[:GROUP]   Owner of published files (requires privileges)

Behaviour:
      --state-dir DIR        State, log and backups directory
                             (default: /var/lib/rustdesk-client-updater as root,
                              \$XDG_STATE_HOME/rustdesk-client-updater otherwise)
      --keep-backups N       Previous releases to keep, 0 = none (default: $KEEP_BACKUPS)
      --update-log BOOL      Append to a public update log in DIR: true|false (default: $WRITE_UPDATE_LOG)
      --update-log-name NAME Public update log file name (default: $UPDATE_LOG_NAME)
  -f, --force                Publish even if nothing changed
  -q, --quiet                Print only warnings and errors (useful with cron)
  -h, --help                 Show this help

Environment:
  GITHUB_TOKEN               Optional token to raise the GitHub API rate limit

Exit codes: 0 success, 1 runtime error, 2 configuration error, 3 partial update.
EOF
}

usage_error() {
    printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
    printf "Try '%s --help' for more information.\n" "$SCRIPT_NAME" >&2
    exit 2
}

# Ensures option $1 has a non-empty value in $2
need_value() {
    [[ $# -ge 2 && -n "$2" ]] || usage_error "Option '$1' requires a value."
}

# Normalizes a boolean string to "true"/"false"
parse_bool() {
    case "${1,,}" in
        true|1|yes|on)  echo true ;;
        false|0|no|off) echo false ;;
        *) usage_error "Invalid boolean value '$1' (use true or false)." ;;
    esac
}

# True if $1 is a plain file name (no path components)
is_plain_name() {
    [[ -n "$1" && "$1" != */* && "$1" != "." && "$1" != ".." ]]
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--target-dir)    need_value "$@"; TARGET_DIR="$2"; shift 2 ;;
            -s|--server-host)   need_value "$@"; SERVER_HOST="$2"; shift 2 ;;
            -k|--key)           need_value "$@"; KEY="$2"; shift 2 ;;
            --relay)            need_value "$@"; RELAY_SERVER="$2"; shift 2 ;;
            --api)              need_value "$@"; API_SERVER="$2"; shift 2 ;;
            -P|--platforms)     need_value "$@"; PLATFORMS="$2"; shift 2 ;;
            --name-style)       need_value "$@"; NAME_STYLE="${2,,}"; shift 2 ;;
            -r|--repository)    need_value "$@"; REPOSITORY="$2"; shift 2 ;;
            --manifest-name)    need_value "$@"; MANIFEST_NAME="$2"; shift 2 ;;
            --state-dir)        need_value "$@"; STATE_DIR="$2"; shift 2 ;;
            --keep-backups)     need_value "$@"; KEEP_BACKUPS="$2"; shift 2 ;;
            --update-log)       need_value "$@"; WRITE_UPDATE_LOG="$(parse_bool "$2")"; shift 2 ;;
            --update-log-name)  need_value "$@"; UPDATE_LOG_NAME="$2"; shift 2 ;;
            --mode)             need_value "$@"; FILE_MODE="$2"; shift 2 ;;
            --owner)            need_value "$@"; OWNER="$2"; shift 2 ;;
            -f|--force)         FORCE=true; shift ;;
            -q|--quiet)         QUIET=true; shift ;;
            -h|--help)          usage; exit 0 ;;
            *)                  usage_error "Unknown option '$1'." ;;
        esac
    done
}

check_dependencies() {
    local cmd
    for cmd in curl jq sha256sum mktemp od tail; do
        command -v "$cmd" >/dev/null 2>&1 || usage_error "Missing dependency: $cmd"
    done
}

validate_config() {
    local v p found

    [[ -n "$TARGET_DIR" ]] || usage_error "--target-dir is required."
    [[ -d "$TARGET_DIR" ]] || usage_error "Target directory not found: $TARGET_DIR"
    TARGET_DIR="$(cd -- "$TARGET_DIR" && pwd -P)"
    [[ -n "$SERVER_HOST" ]] || usage_error "--server-host is required."
    [[ -n "$KEY" ]] || usage_error "--key is required."
    API_SERVER="${API_SERVER%/}"

    for v in "$SERVER_HOST" "$KEY" "$RELAY_SERVER" "$API_SERVER"; do
        [[ "$v" != *[,[:space:]\"]* ]] || usage_error "Server values must not contain commas, spaces or quotes."
    done

    # Platforms: keep catalog order, reject unknown names
    IFS=', ' read -r -a requested <<<"${PLATFORMS,,}"
    for p in "${requested[@]}"; do
        [[ -z "$p" || -n "${ASSET_RX[$p]+x}" ]] || usage_error "Unknown platform '$p'. Available: ${CATALOG_ORDER[*]}"
    done
    SELECTED=()
    for p in "${CATALOG_ORDER[@]}"; do
        for found in "${requested[@]}"; do
            if [[ "$found" == "$p" ]]; then SELECTED+=("$p"); break; fi
        done
    done
    [[ ${#SELECTED[@]} -gt 0 ]] || usage_error "No platform selected."

    [[ "$NAME_STYLE" =~ ^(auto|plain|encoded)$ ]] || usage_error "--name-style must be auto, plain or encoded."
    is_plain_name "$UPDATE_LOG_NAME" || usage_error "Invalid update log name '$UPDATE_LOG_NAME'."
    is_plain_name "$MANIFEST_NAME" || usage_error "Invalid manifest name '$MANIFEST_NAME'."
    [[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_error "Invalid repository '$REPOSITORY'."
    [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || usage_error "--keep-backups must be a non-negative integer."
    [[ "$FILE_MODE" =~ ^[0-7]{3,4}$ ]] || usage_error "--mode must be an octal mode (e.g. 0644)."

    if [[ -z "$STATE_DIR" ]]; then
        if [[ $EUID -eq 0 ]]; then
            STATE_DIR="/var/lib/rustdesk-client-updater"
        else
            STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rustdesk-client-updater"
        fi
    fi
    mkdir -p -- "$STATE_DIR" 2>/dev/null || usage_error "Cannot create state directory '$STATE_DIR'."
}

# ---------------------------------------------------------------------------
# Server configuration encoding and file names
# ---------------------------------------------------------------------------

# Same format as RustDesk "Export server config": reversed, URL-safe base64 (no padding)
# of {"host","relay","api","key"}. Leading JSON whitespace is added when needed so the
# result contains no "--" and does not start/end with "-", which would break the
# "--" delimited file-name parser of RustDesk.
encode_config() {
    local pad enc
    for pad in $(seq 0 32); do
        enc="$(jq -rn --arg h "$SERVER_HOST" --arg r "$CONFIG_RELAY" --arg a "$API_SERVER" \
            --arg k "$KEY" --argjson pad "$pad" '
            ("{" + ([range($pad)] | map(" ") | join(""))
                 + ({host: $h, relay: $r, api: $a, key: $k} | tojson | .[1:]))
            | @base64 | gsub("\\+"; "-") | gsub("/"; "_") | gsub("="; "")
            | explode | reverse | implode')"
        if [[ "$enc" != *--* && "$enc" != -* && "$enc" != *- ]]; then
            printf '%s' "$enc"
            return 0
        fi
    done
    return 1
}

# host=<host>,key=<key>[,relay=<relay>][,api=<api>]
plain_config() {
    local s="host=${SERVER_HOST},key=${KEY}"
    [[ -n "$RELAY_SERVER" ]] && s+=",relay=${RELAY_SERVER}"
    [[ -n "$API_SERVER" ]] && s+=",api=${API_SERVER}"
    printf '%s' "$s"
}

build_names() {
    local style="$NAME_STYLE" p plain_safe=true

    # Relay written in the macOS/Linux configuration: explicit relay, or the ID server host
    # (same server RustDesk would use anyway, but visible in the imported settings).
    # Windows plain file names keep only an explicit --relay.
    CONFIG_RELAY="${RELAY_SERVER:-$SERVER_HOST}"

    ENCODED_CONFIG="$(encode_config)" || usage_error "Unable to encode the server configuration."
    PLAIN_CONFIG="$(plain_config)"

    # Plain names are readable but every value must be valid in a Windows file name
    [[ "$PLAIN_CONFIG" == *[\\/:*?\"\<\>\|]* ]] && plain_safe=false
    if [[ "$style" == auto ]]; then
        if [[ "$plain_safe" == true ]]; then style=plain; else style=encoded; fi
    fi
    if [[ "$style" == plain && "$plain_safe" != true ]]; then
        usage_error "A value contains characters invalid in Windows file names (\\ / : * ? \" < > |). Use --name-style encoded or auto."
    fi

    for p in "${SELECTED[@]}"; do
        if [[ -n "${FILE[$p]}" ]]; then
            PUBLISH_NAME[$p]="${FILE[$p]}"
        elif [[ "$style" == plain ]]; then
            # Trailing comma: keeps the key intact if the browser appends " (1)" to duplicates
            PUBLISH_NAME[$p]="${WIN_PREFIX[$p]}-${PLAIN_CONFIG},.exe"
        else
            PUBLISH_NAME[$p]="${WIN_PREFIX[$p]}--${ENCODED_CONFIG}--.exe"
        fi
    done
}

# ---------------------------------------------------------------------------
# Logging and cleanup
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] [$INSTANCE_ID] $*"
    if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
    if [[ "$level" != INFO ]]; then
        printf '%s\n' "$line" >&2
    elif [[ "$QUIET" != true ]]; then
        printf '%s\n' "$line"
    fi
}

die() {
    log ERROR "$*"
    exit 1
}

# shellcheck disable=SC2329  # invoked through "trap cleanup EXIT"
cleanup() {
    [[ -n "$STAGING_FILE" && -e "$STAGING_FILE" ]] && rm -f -- "$STAGING_FILE"
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
    return 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Hex of $3 bytes at offset $2 (negative = from end of file); empty if out of range
hex_at() {
    local file="$1" offset="$2" count="$3" size
    size="$(wc -c <"$file")"; size="${size//[[:space:]]/}"
    (( offset < 0 )) && offset=$(( size + offset ))
    (( offset >= 0 && offset + count <= size )) || return 0
    od -An -tx1 -j "$offset" -N "$count" -- "$file" | tr -d ' \n'
}

# True if the file signature matches its extension (unknown extensions pass)
check_magic() {
    local file="$1" ext="${1##*.}"
    case "${ext,,}" in
        exe)      [[ "$(hex_at "$file" 0 2)" == 4d5a ]] ;;
        msi)      [[ "$(hex_at "$file" 0 8)" == d0cf11e0a1b11ae1 ]] ;;
        deb)      [[ "$(hex_at "$file" 0 8)" == 213c617263683e0a ]] ;;
        rpm)      [[ "$(hex_at "$file" 0 4)" == edabeedb ]] ;;
        appimage) [[ "$(hex_at "$file" 0 4)" == 7f454c46 ]] ;;
        dmg)      [[ "$(hex_at "$file" -512 4)" == 6b6f6c79 ]] ;;
        *)        return 0 ;;
    esac
}

# Stages a file inside TARGET_DIR and atomically renames it over the destination
install_file() {
    local source="$1" dest="$2"
    STAGING_FILE="$TARGET_DIR/.${dest##*/}.partial"
    cp -- "$source" "$STAGING_FILE"
    chmod -- "$FILE_MODE" "$STAGING_FILE"
    if [[ -n "$OWNER" ]]; then
        chown -- "$OWNER" "$STAGING_FILE" || die "chown '$OWNER' failed."
    fi
    mv -f -- "$STAGING_FILE" "$dest"
    STAGING_FILE=""
}

# Plain file names listed in the manifest at $1
managed_files() {
    [[ -f "$1" ]] || return 0
    jq -r '.files // {} | to_entries[] | .value.file // empty' -- "$1" 2>/dev/null \
        | while IFS= read -r f; do is_plain_name "$f" && printf '%s\n' "$f"; done
    return 0
}

# Copies the currently published files into BACKUP_ROOT/<timestamp>_<version>
backup_published() {
    local manifest="$1" label dir f any=false
    [[ "$KEEP_BACKUPS" -gt 0 ]] || return 0

    label="$(jq -r '.version // "unknown"' -- "$manifest" 2>/dev/null || echo unknown)"
    dir="$BACKUP_ROOT/$(date '+%Y%m%d%H%M%S')_${label}"
    while IFS= read -r f; do
        [[ -f "$TARGET_DIR/$f" ]] || continue
        mkdir -p -- "$dir"
        cp -p -- "$TARGET_DIR/$f" "$dir/$f"
        any=true
    done < <(managed_files "$manifest")
    [[ "$any" == true ]] || return 0

    # Folder names start with a timestamp, so reverse name order is newest first
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | sort -r \
        | tail -n +"$((KEEP_BACKUPS + 1))" \
        | while IFS= read -r f; do rm -rf -- "${BACKUP_ROOT:?}/$f"; done
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------
run_update() {
    local -a api_headers skipped=() done_platforms=()
    local response http_code api_msg hint release_json version
    local fingerprint state_fp old_version from p f all_present
    local rx asset_line asset_name asset_url asset_size asset_digest tmp size hash
    local files_json='{}' manifest_tmp list

    # --- Latest release ---
    api_headers=(-H "User-Agent: $USER_AGENT" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        api_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    # Body and HTTP status are captured together so API errors (e.g. rate limit) can be reported
    response="$(curl --proto '=https' --tlsv1.2 -sSL --retry 3 --retry-delay 5 \
        --connect-timeout 20 --max-time 60 "${api_headers[@]}" -w '\n%{http_code}' \
        "https://api.github.com/repos/$REPOSITORY/releases/latest")" \
        || die "GitHub API request failed for $REPOSITORY (network error)."
    http_code="${response##*$'\n'}"
    release_json="${response%$'\n'*}"
    if [[ "$http_code" != 200 ]]; then
        api_msg="$(jq -r '.message // empty' <<<"$release_json" 2>/dev/null || true)"
        hint=""
        [[ "$http_code" == 403 || "$http_code" == 429 ]] && hint=" Rate limit? Set GITHUB_TOKEN."
        die "GitHub API returned HTTP $http_code for $REPOSITORY${api_msg:+: $api_msg}.$hint"
    fi

    version="$(jq -r '.tag_name // empty' <<<"$release_json")"
    version="${version#v}"
    [[ -n "$version" ]] || die "The latest release has no tag name."

    # --- Change detection: version, platforms, file names and server configuration ---
    fingerprint="$version|"
    for p in "${SELECTED[@]}"; do fingerprint+="$p=${PUBLISH_NAME[$p]};"; done
    fingerprint="${fingerprint%;}|$ENCODED_CONFIG"

    state_fp="$(jq -r '.fingerprint // empty' -- "$STATE_FILE" 2>/dev/null || true)"
    old_version="$(jq -r '.version // empty' -- "$STATE_FILE" 2>/dev/null || true)"
    all_present=true
    [[ -f "$MANIFEST_PATH" ]] || all_present=false
    for p in "${SELECTED[@]}"; do [[ -f "$TARGET_DIR/${PUBLISH_NAME[$p]}" ]] || all_present=false; done

    if [[ "$FORCE" != true && "$all_present" == true && "$state_fp" == "$fingerprint" ]]; then
        log INFO "Up to date: $version is already published."
        return 0
    fi
    from="${old_version:-unknown}"
    log INFO "Publishing $from -> $version (${SELECTED[*]})."

    # --- Download and verify every platform before touching TARGET_DIR ---
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rustdesk-client-updater.XXXXXXXX")"

    for p in "${SELECTED[@]}"; do
        rx="${ASSET_RX[$p]}"
        asset_line="$(jq -r --arg re "$rx" '
            [.assets[] | select(.name | test($re))][0] // empty
            | [.name, .browser_download_url, (.size | tostring), (.digest // "")]
            | @tsv' <<<"$release_json")"
        if [[ -z "$asset_line" ]]; then
            log WARN "Platform $p skipped: no asset matching '$rx' in release $version."
            skipped+=("$p")
            continue
        fi
        IFS=$'\t' read -r asset_name asset_url asset_size asset_digest <<<"$asset_line"
        is_plain_name "$asset_name" || die "Unexpected asset name '$asset_name'."

        # Keep the asset name/extension: the magic check depends on it
        tmp="$TMP_DIR/$asset_name"
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 5 \
            --connect-timeout 20 --max-time 1800 -H "User-Agent: $USER_AGENT" \
            -o "$tmp" "$asset_url" \
            || die "Download failed: $asset_url"

        size="$(wc -c <"$tmp")"; size="${size//[[:space:]]/}"
        [[ "$size" == "$asset_size" ]] || die "$asset_name: size mismatch (expected $asset_size, got $size)."

        hash="$(sha256sum -- "$tmp" | cut -d' ' -f1)"
        if [[ "${asset_digest:-}" =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
            [[ "$hash" == "${BASH_REMATCH[1],,}" ]] || die "$asset_name: SHA-256 mismatch."
        else
            log WARN "$asset_name: no SHA-256 digest published; hash check skipped."
        fi

        check_magic "$tmp" || die "$asset_name: file signature does not match its type."

        log INFO "$asset_name: verified ($size bytes)."
        files_json="$(jq -c --arg p "$p" --arg f "${PUBLISH_NAME[$p]}" --arg a "$asset_name" \
            --argjson s "$size" --arg h "$hash" \
            '. + {($p): {file: $f, asset: $a, size: $s, sha256: $h}}' <<<"$files_json")"
        done_platforms+=("$p")
    done
    [[ ${#done_platforms[@]} -gt 0 ]] || die "No platform could be downloaded."

    # --- Publish ---
    backup_published "$MANIFEST_PATH"
    for p in "${done_platforms[@]}"; do
        install_file "$TMP_DIR/$(jq -r --arg p "$p" '.[$p].asset' <<<"$files_json")" "$TARGET_DIR/${PUBLISH_NAME[$p]}"
    done

    # Remove files published by the previous run that are no longer part of the set
    while IFS= read -r f; do
        if ! jq -e --arg f "$f" 'any(.[]; .file == $f)' <<<"$files_json" >/dev/null && [[ -f "$TARGET_DIR/$f" ]]; then
            rm -f -- "$TARGET_DIR/$f"
            log INFO "Removed obsolete file $f."
        fi
    done < <(managed_files "$MANIFEST_PATH")

    # Manifest for the download page
    manifest_tmp="$TMP_DIR/$MANIFEST_NAME"
    jq -n --arg v "$version" --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg h "$SERVER_HOST" --arg r "$CONFIG_RELAY" --arg a "$API_SERVER" --arg k "$KEY" \
        --arg c "$ENCODED_CONFIG" --argjson files "$files_json" \
        '{version: $v, published: $t, server: {host: $h, relay: $r, api: $a, key: $k}, config: $c, files: $files}' \
        >"$manifest_tmp"
    install_file "$manifest_tmp" "$MANIFEST_PATH"

    jq -n --arg v "$version" --arg f "$fingerprint" '{version: $v, fingerprint: $f}' >"$STATE_FILE"
    log INFO "Published $version to $TARGET_DIR (${#done_platforms[@]} files)."

    # --- Public update log (only when something was published) ---
    if [[ "$WRITE_UPDATE_LOG" == true ]]; then
        list="$(printf '%s, ' "${done_platforms[@]}")"
        printf '%s | %s -> %s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$from" "$version" "${list%, }" \
            >>"$TARGET_DIR/$UPDATE_LOG_NAME" 2>/dev/null \
            || log WARN "Could not write update log $TARGET_DIR/$UPDATE_LOG_NAME."
    fi

    # Reported by main() as exit code 3 (a non-zero return here would trip "set -e")
    [[ ${#skipped[@]} -eq 0 ]] || PARTIAL=true
    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_dependencies
    validate_config
    build_names

    # Short stable ID of the target directory: lets several targets share one state dir
    INSTANCE_ID="$(printf '%s' "$TARGET_DIR" | sha256sum | cut -c1-12)"
    LOG_FILE="$STATE_DIR/rustdesk-client-updater.log"
    STATE_FILE="$STATE_DIR/state-$INSTANCE_ID.json"
    BACKUP_ROOT="$STATE_DIR/backup/$INSTANCE_ID"
    MANIFEST_PATH="$TARGET_DIR/$MANIFEST_NAME"

    trap cleanup EXIT
    trap 'log ERROR "Unexpected failure at line $LINENO (exit code $?)."' ERR

    # One run at a time per target directory
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$STATE_DIR/$INSTANCE_ID.lock"
        if ! flock -n 9; then
            log INFO "Another run for this target is in progress; skipping."
            exit 0
        fi
    fi

    run_update
    [[ "$PARTIAL" == true ]] && exit 3
    exit 0
}

main "$@"
