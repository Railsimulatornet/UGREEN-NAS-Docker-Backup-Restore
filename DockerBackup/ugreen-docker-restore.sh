#!/usr/bin/env bash
# UGREEN Docker Restore - v1.10
# Copyright (c) 2026 Roman Glos
set -Eeuo pipefail

SCRIPT_VERSION="1.10"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/dockersich.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

LANGUAGE="${LANGUAGE:-de}"
HOST_LABEL="${HOST_LABEL:-$(hostname 2>/dev/null || echo 'UGREEN NAS')}"
BACKUP_DIR="${BACKUP_DIR:-/volume2/DockerBackup}"
TEMP_DIR="${TEMP_DIR:-${BACKUP_DIR}/tmp}"
LOG_DIR="${LOG_DIR:-${BACKUP_DIR}/log}"

SOURCE_DIR="${SOURCE_DIR:-auto}"
DOCKER_ROOT_DIR="${DOCKER_ROOT_DIR:-auto}"
UGOS_DOCKER_DB="${UGOS_DOCKER_DB:-auto}"

RESTORE_ARCHIVE="${RESTORE_ARCHIVE:-${1:-}}"
DRY_RUN="${DRY_RUN:-true}"
RESTORE_CONFIRMATION_REQUIRED="${RESTORE_CONFIRMATION_REQUIRED:-true}"
RESTORE_ALL_PROJECTS="${RESTORE_ALL_PROJECTS:-false}"
RESTORE_PROJECTS="${RESTORE_PROJECTS:-}"
EXCLUDE_PROJECTS="${EXCLUDE_PROJECTS:-}"
RESTORE_OVERWRITE_EXISTING="${RESTORE_OVERWRITE_EXISTING:-false}"
RESTORE_STOP_EXISTING_PROJECTS="${RESTORE_STOP_EXISTING_PROJECTS:-true}"
RESTORE_RUN_COMPOSE_UP="${RESTORE_RUN_COMPOSE_UP:-true}"
RESTORE_CONTINUE_ON_COMPOSE_ERROR="${RESTORE_CONTINUE_ON_COMPOSE_ERROR:-true}"
RESTORE_RECREATE_NETWORKS="${RESTORE_RECREATE_NETWORKS:-true}"
RESTORE_CREATE_MISSING_NETWORKS="${RESTORE_CREATE_MISSING_NETWORKS:-true}"
RESTORE_CREATE_MACVLAN_NETWORKS="${RESTORE_CREATE_MACVLAN_NETWORKS:-true}"
RESTORE_MACVLAN_PARENT="${RESTORE_MACVLAN_PARENT:-auto}"
RESTORE_MACVLAN_PARENT_MAP="${RESTORE_MACVLAN_PARENT_MAP:-}"
RESTORE_FAIL_ON_NETWORK_ERROR="${RESTORE_FAIL_ON_NETWORK_ERROR:-true}"
RESTORE_VALIDATE_BIND_MOUNTS="${RESTORE_VALIDATE_BIND_MOUNTS:-true}"
RESTORE_BACKGROUND="${RESTORE_BACKGROUND:-false}"

ENABLE_PATH_REMAP="${ENABLE_PATH_REMAP:-true}"
PATH_REMAP_FILE="${PATH_REMAP_FILE:-path-remap.tsv}"
PATH_REMAP_FROM="${PATH_REMAP_FROM:-}"
PATH_REMAP_TO="${PATH_REMAP_TO:-}"
APPLY_PATH_REMAP_TO_TEXT_FILES="${APPLY_PATH_REMAP_TO_TEXT_FILES:-true}"

RESTORE_NAMED_VOLUMES="${RESTORE_NAMED_VOLUMES:-false}"
RESTORE_IMAGES="${RESTORE_IMAGES:-false}"
RESTORE_EXTERNAL_BINDS="${RESTORE_EXTERNAL_BINDS:-false}"
RESTORE_STANDALONE_CONTAINERS="${RESTORE_STANDALONE_CONTAINERS:-true}"
RESTORE_FIX_PERMISSIONS="${RESTORE_FIX_PERMISSIONS:-true}"
RESTORE_FIX_OWNER="${RESTORE_FIX_OWNER:-auto}"
RESTORE_FIX_DIR_MODE="${RESTORE_FIX_DIR_MODE:-775}"
RESTORE_FIX_FILE_MODE="${RESTORE_FIX_FILE_MODE:-664}"

UPDATE_UGOS_DOCKER_DB="${UPDATE_UGOS_DOCKER_DB:-true}"
UGOS_DB_CONTENT_MODE="${UGOS_DB_CONTENT_MODE:-empty}" # empty|backup
KEEP_UGOS_DB_BACKUPS="${KEEP_UGOS_DB_BACKUPS:-10}"
CLEANUP_TEMP_AFTER_RESTORE="${CLEANUP_TEMP_AFTER_RESTORE:-true}"
REFRESH_UGOS_DOCKER_APP="${REFRESH_UGOS_DOCKER_APP:-true}"
UGOS_DOCKER_SERVICE="${UGOS_DOCKER_SERVICE:-docker_serv}"

SEND_MAIL="${SEND_MAIL:-false}"
MAIL_NOTIFY_ON="${MAIL_NOTIFY_ON:-all}"   # all|fail|success|none
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_USE_TLS="${SMTP_USE_TLS:-true}"
SMTP_USE_SSL="${SMTP_USE_SSL:-false}"
MAIL_FROM="${MAIL_FROM:-}"
MAIL_TO="${MAIL_TO:-}"
MAIL_SUBJECT_PREFIX="${MAIL_SUBJECT_PREFIX:-[UGREEN Docker Restore] }"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"

DOCKER_BIN="${DOCKER_BIN:-docker}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log_file=""
extract_parent=""
backup_root=""
script_start_epoch=0
UGOS_DB_STATUS="not executed"
UGOS_REFRESH_STATUS="not executed"
RESTORE_FAILURE_REASON=""
LAST_CMD=""
RESTORE_COMPOSE_FAILED=0
RESTORE_COMPOSE_ERROR_COUNT=0

lower(){ printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
is_true(){ case "$(lower "${1:-}")" in true|1|yes|y|ja) return 0;; *) return 1;; esac; }
is_false(){ ! is_true "${1:-}"; }

tr_text(){
  local de="$1"; local en="$2"
  if [[ "$(lower "$LANGUAGE")" == en* ]]; then printf '%s' "$en"; else printf '%s' "$de"; fi
}

UGOS_DB_STATUS="$(tr_text 'nicht ausgeführt' 'not executed')"
UGOS_REFRESH_STATUS="$(tr_text 'nicht ausgeführt' 'not executed')"

prune_ugos_db_backups(){
  local db_dir db_base keep
  keep="${KEEP_UGOS_DB_BACKUPS:-10}"
  [[ "$keep" =~ ^[0-9]+$ && "$keep" -gt 0 ]] || return 0
  [[ -n "${UGOS_DOCKER_DB:-}" ]] || return 0
  db_dir="$(dirname "$UGOS_DOCKER_DB")"
  db_base="$(basename "$UGOS_DOCKER_DB")"
  ls -1t "${db_dir}/${db_base}.dockersich-restore-backup-"* 2>/dev/null | awk "NR>$keep" | xargs -r rm -f --
  log_i "[UGOS-DB] Behalte die letzten ${keep} Datenbank-Sicherheitskopien." "[UGOS DB] Keeping the last ${keep} database safety copies."
}


mkdir_safe(){ mkdir -p "$1"; }

rotate_logs(){
  mkdir_safe "$LOG_DIR"
  local lf="${LOG_DIR}/ugreen-docker-restore.log"
  if [[ -f "$lf" ]]; then
    for ((i=9;i>=1;i--)); do
      [[ -f "${lf}.${i}" ]] && mv -f "${lf}.${i}" "${lf}.$((i+1))" || true
    done
    mv -f "$lf" "${lf}.1" || true
  fi
  touch "$lf"
  printf '%s' "$lf"
}


run_background_if_requested(){
  is_true "$RESTORE_BACKGROUND" || return 0
  [[ "${UGREEN_DOCKER_RESTORE_BACKGROUND_CHILD:-0}" == "1" ]] && return 0

  mkdir_safe "$LOG_DIR"
  local ts bg_log bg_pid script_path
  ts="$(date +'%Y%m%d_%H%M%S')"
  bg_log="${LOG_DIR}/ugreen-docker-restore-nohup-${ts}.log"
  bg_pid="${LOG_DIR}/ugreen-docker-restore-nohup.pid"
  script_path="$0"

  echo "Starte Docker-Restore im Hintergrund."
  echo "Log: ${bg_log}"
  UGREEN_DOCKER_RESTORE_BACKGROUND_CHILD=1 RESTORE_BACKGROUND=false nohup "$script_path" "$RESTORE_ARCHIVE" > "$bg_log" 2>&1 &
  echo $! > "$bg_pid"
  echo "PID: $(cat "$bg_pid")"
  exit 0
}

log(){ printf '[%s] %s\n' "$(date +'%F %T')" "$*" | tee -a "$log_file"; }
log_i(){ log "$(tr_text "$1" "$2")"; }
die(){ log "ERROR: $*"; exit 1; }

split_words(){ printf '%s' "${1:-}" | tr ',;' '  ' | tr -s ' ' '\n' | sed '/^$/d'; }
hr_size(){ local b="${1:-0}"; if command -v numfmt >/dev/null 2>&1; then numfmt --to=iec --suffix=B --format="%.1f" "$b"; else echo "${b}B"; fi; }

run_cmd(){
  LAST_CMD="$*"
  log "+ $*"
  if is_true "$DRY_RUN"; then
    return 0
  fi
  local rc
  set +e
  "$@" 2>&1 | tee -a "$log_file"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ "$rc" -ne 0 ]]; then
    RESTORE_FAILURE_REASON="$(tr_text 'Befehl fehlgeschlagen' 'Command failed') (Exit ${rc}): ${LAST_CMD}"
  fi
  return "$rc"
}

run_cmd_in_dir(){
  local dir="$1"
  shift
  LAST_CMD="(cd ${dir} && $*)"
  log "+ (cd ${dir} && $*)"
  if is_true "$DRY_RUN"; then
    return 0
  fi
  local oldpwd rc
  oldpwd="$(pwd)"
  cd "$dir"
  set +e
  "$@" 2>&1 | tee -a "$log_file"
  rc=${PIPESTATUS[0]}
  set -e
  cd "$oldpwd"
  if [[ "$rc" -ne 0 ]]; then
    RESTORE_FAILURE_REASON="$(tr_text 'Befehl fehlgeschlagen' 'Command failed') (Exit ${rc}): ${LAST_CMD}"
  fi
  return "$rc"
}

resolve_auto_paths(){
  if [[ "$DOCKER_ROOT_DIR" == "auto" || -z "$DOCKER_ROOT_DIR" ]]; then
    DOCKER_ROOT_DIR="$($DOCKER_BIN info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    [[ -n "$DOCKER_ROOT_DIR" ]] || die "$(tr_text 'Docker Root Dir konnte nicht automatisch ermittelt werden.' 'Could not auto-detect Docker Root Dir.')"
  fi

  local base_volume=""
  if [[ "$(basename "$DOCKER_ROOT_DIR")" == "@docker" ]]; then
    base_volume="$(dirname "$DOCKER_ROOT_DIR")"
  fi

  if [[ "$SOURCE_DIR" == "auto" || -z "$SOURCE_DIR" ]]; then
    if [[ -n "$base_volume" ]]; then
      SOURCE_DIR="${base_volume}/docker"
    else
      local found
      found="$(find /volume* -maxdepth 1 -type d -name docker 2>/dev/null | head -n 1 || true)"
      SOURCE_DIR="${found:-}"
    fi
    [[ -n "$SOURCE_DIR" ]] || die "$(tr_text 'Docker-Projektordner konnte nicht automatisch ermittelt werden. Bitte SOURCE_DIR in der .env setzen.' 'Could not auto-detect Docker project folder. Please set SOURCE_DIR in the .env.')"
  fi

  if [[ "$UGOS_DOCKER_DB" == "auto" || -z "$UGOS_DOCKER_DB" ]]; then
    if [[ -n "$base_volume" && -f "${base_volume}/@appstore/com.ugreen.docker/db/docker_info_log.db" ]]; then
      UGOS_DOCKER_DB="${base_volume}/@appstore/com.ugreen.docker/db/docker_info_log.db"
    else
      local matches count
      matches="$(find /volume* -path '*/@appstore/com.ugreen.docker/db/docker_info_log.db' -type f 2>/dev/null || true)"
      count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
      if [[ "$count" == "1" ]]; then
        UGOS_DOCKER_DB="$(printf '%s\n' "$matches" | sed '/^$/d' | head -n 1)"
      elif [[ "$count" == "0" ]]; then
        UGOS_DOCKER_DB=""
      else
        die "$(tr_text 'Mehrere UGOS-Docker-Datenbanken gefunden. Bitte UGOS_DOCKER_DB in der .env fest setzen.' 'Multiple UGOS Docker databases found. Please set UGOS_DOCKER_DB in the .env.')"
      fi
    fi
  fi
}

preflight(){
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "docker command not found"
  command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "python3 command not found"
  $DOCKER_BIN info >/dev/null 2>&1 || die "$(tr_text 'Kein Zugriff auf Docker. Bitte als root ausführen.' 'No Docker access. Please run as root.')"
  [[ -n "$RESTORE_ARCHIVE" ]] || die "$(tr_text 'RESTORE_ARCHIVE ist nicht gesetzt. Alternativ Archiv als erstes Argument übergeben.' 'RESTORE_ARCHIVE is not set. Alternatively pass the archive as first argument.')"
  [[ -f "$RESTORE_ARCHIVE" ]] || die "$(tr_text "Archiv nicht gefunden: $RESTORE_ARCHIVE" "Archive not found: $RESTORE_ARCHIVE")"
  RESTORE_ARCHIVE="$(readlink -f "$RESTORE_ARCHIVE" 2>/dev/null || realpath "$RESTORE_ARCHIVE" 2>/dev/null || printf '%s' "$RESTORE_ARCHIVE")"
  mkdir_safe "$TEMP_DIR"
  mkdir_safe "$LOG_DIR"
}

should_mail(){
  local event="$1"
  is_true "$SEND_MAIL" || return 1
  local mode
  mode="$(lower "$MAIL_NOTIFY_ON")"
  case "$mode" in
    all) return 0;;
    fail) [[ "$event" == "fail" ]] && return 0 || return 1;;
    success|ok) [[ "$event" == "success" ]] && return 0 || return 1;;
    none) return 1;;
    *) return 0;;
  esac
}

mail_tail_file(){
  local f="${LOG_DIR}/ugreen-docker-restore-last-${LOG_TAIL_LINES}.log"
  tail -n "$LOG_TAIL_LINES" "$log_file" > "$f" 2>/dev/null || true
  printf '%s' "$f"
}

send_mail(){
  local event="$1"
  local title="$2"
  local status="$3"
  local details="$4"
  local attach="${5:-}"

  should_mail "$event" || return 0
  if [[ -z "$SMTP_HOST" || -z "$MAIL_FROM" || -z "$MAIL_TO" ]]; then
    log_i "[Mail] SMTP_HOST, MAIL_FROM oder MAIL_TO nicht gesetzt, E-Mail wird übersprungen." "[Mail] SMTP_HOST, MAIL_FROM or MAIL_TO not set, skipping e-mail."
    return 0
  fi

  "$PYTHON_BIN" - "$SMTP_HOST" "$SMTP_PORT" "$SMTP_USER" "$SMTP_PASS" "$SMTP_USE_TLS" "$SMTP_USE_SSL" "$MAIL_FROM" "$MAIL_TO" "$MAIL_SUBJECT_PREFIX" "$title" "$status" "$details" "$attach" "$HOST_LABEL" "$SCRIPT_VERSION" "$event" <<'PYMAIL'
import html
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage
from pathlib import Path

(smtp_host, smtp_port, smtp_user, smtp_pass, use_tls, use_ssl, mail_from, mail_to,
 subject_prefix, title, status, details, attach_path, host_label, script_version, event_name) = sys.argv[1:17]
smtp_port = int(smtp_port or 587)
use_tls = (use_tls or "true").lower() in ("true", "1", "yes", "ja")
use_ssl = (use_ssl or "false").lower() in ("true", "1", "yes", "ja")
recips = [x.strip() for x in mail_to.split(",") if x.strip()]

details = (details or "").replace("\\n", "\n")
status = (status or "").replace("\\n", "\n")
prefix = subject_prefix or ""
separator = "" if (not prefix or prefix.endswith((" ", "-", "|", ":", "–"))) else " "
subject = f"{prefix}{separator}{title}"

msg = EmailMessage()
msg["Subject"] = subject
msg["From"] = mail_from
msg["To"] = ", ".join(recips)

plain_body = f"{title}\n{host_label}\n\n{status}\n\n{details}\n\nUGREEN Docker Restore v{script_version}\nCopyright Roman Glos 2026\n"
msg.set_content(plain_body)

safe_status = html.escape(status).replace("\n", "<br>")
safe_details = html.escape(details).replace("\n", "<br>")
safe_host = html.escape(host_label or "")
safe_title = html.escape(title or "")
safe_version = html.escape(script_version or "")

event_l = (event_name or "").lower()
if event_l == "fail":
    badge_bg = "#fef2f2"
    badge_fg = "#991b1b"
    badge_border = "#fecaca"
elif event_l == "start":
    badge_bg = "#eff6ff"
    badge_fg = "#1d4ed8"
    badge_border = "#bfdbfe"
else:
    badge_bg = "#eef7ee"
    badge_fg = "#166534"
    badge_border = "#bbdfc1"

html_body = f"""<!doctype html>
<html><head><meta charset="utf-8"></head>
<body style="margin:0;padding:0;background:#f4f6f8;font-family:Arial,Helvetica,sans-serif;color:#1f2937;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f4f6f8;margin:0;padding:24px 0;">
<tr><td align="center">
<table role="presentation" width="920" cellspacing="0" cellpadding="0" style="max-width:920px;width:92%;background:#ffffff;border:1px solid #d9dde3;border-radius:12px;overflow:hidden;">
<tr><td style="background:#eaf2ff;padding:20px 24px;border-bottom:1px solid #d9dde3;">
<div style="font-size:24px;font-weight:700;color:#111827;line-height:1.25;">{safe_title}</div>
<div style="font-size:14px;color:#374151;margin-top:6px;">{safe_host}</div>
</td></tr>
<tr><td style="padding:18px 24px;">
<div style="display:inline-block;background:{badge_bg};color:{badge_fg};border:1px solid {badge_border};border-radius:999px;padding:6px 12px;font-weight:700;margin-bottom:16px;">{safe_status}</div>
<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.55;white-space:normal;background:#f8fafc;border:1px solid #e5e7eb;border-radius:10px;padding:14px;color:#111827;word-break:break-word;">{safe_details}</div>
</td></tr>
<tr><td style="padding:14px 24px;border-top:1px solid #e5e7eb;background:#fafafa;color:#6b7280;font-size:12px;">
UGREEN Docker Restore v{safe_version}<br>Copyright Roman Glos 2026
</td></tr>
</table>
</td></tr>
</table>
</body></html>"""
msg.add_alternative(html_body, subtype="html")

if attach_path and os.path.exists(attach_path):
    p = Path(attach_path)
    msg.add_attachment(p.read_bytes(), maintype="text", subtype="plain", filename=p.name)

ctx = ssl.create_default_context()
try:
    if use_ssl:
        server = smtplib.SMTP_SSL(smtp_host, smtp_port, context=ctx, timeout=30)
    else:
        server = smtplib.SMTP(smtp_host, smtp_port, timeout=30)
        if use_tls:
            server.starttls(context=ctx)
    if smtp_user:
        server.login(smtp_user, smtp_pass or "")
    server.send_message(msg)
    server.quit()
    print("email: sent")
except Exception as e:
    print(f"email failed: {e}", file=sys.stderr)
    sys.exit(2)
PYMAIL
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    log_i "[Mail] E-Mail gesendet." "[Mail] E-mail sent."
  else
    log_i "[Mail] E-Mail konnte nicht gesendet werden." "[Mail] E-mail could not be sent."
  fi
  return 0
}

extract_archive(){
  local ts
  ts="$(date +'%Y-%m-%d_%H-%M-%S')"
  extract_parent="${TEMP_DIR}/ugreen-docker-restore_${ts}"
  mkdir_safe "$extract_parent"

  log_i "[Restore] Entpacke Archiv: ${RESTORE_ARCHIVE}" "[Restore] Extracting archive: ${RESTORE_ARCHIVE}"
  # Detect compression so backups created with COMPRESS_BACKUP=false also restore.
  tar -xf "$RESTORE_ARCHIVE" -C "$extract_parent"

  backup_root="$(find "$extract_parent" -mindepth 1 -maxdepth 1 -type d -name 'ugreen-docker-backup_*' | head -n 1 || true)"
  [[ -n "$backup_root" ]] || backup_root="$(find "$extract_parent" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  [[ -n "$backup_root" && -d "$backup_root/metadata" ]] || die "$(tr_text 'Backup-Struktur im Archiv nicht erkannt.' 'Backup structure not recognized in archive.')"
}

manifest_value(){
  local key="$1"
  grep -E "^${key}=" "$backup_root/metadata/manifest.env" 2>/dev/null | head -n 1 | cut -d= -f2- || true
}

effective_remap_file(){
  local f="${PATH_REMAP_FILE:-}"
  [[ -n "$f" ]] || return 0
  if [[ "$f" != /* ]]; then
    f="${SCRIPT_DIR}/${f}"
  fi
  printf '%s' "$f"
}

parse_remap_line(){
  # prints: source<TAB>target or nothing
  local line="$1" from="" to=""
  line="${line%$'\r'}"
  [[ -z "${line//[[:space:]]/}" ]] && return 0
  [[ "$line" =~ ^[[:space:]]*# ]] && return 0
  if [[ "$line" == *$'\t'* ]]; then
    IFS=$'\t' read -r from to _rest <<< "$line"
  else
    read -r from to _rest <<< "$line"
  fi
  from="${from%/}"
  to="${to%/}"
  [[ -n "$from" && -n "$to" ]] || return 0
  printf '%s\t%s\n' "$from" "$to"
}

apply_custom_path_remaps(){
  local p="$1" f line from to parsed
  is_true "$ENABLE_PATH_REMAP" || { printf '%s' "$p"; return 0; }

  # 1) Mapping file, for multiple path remaps.
  f="$(effective_remap_file)"
  if [[ -n "$f" && -f "$f" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      parsed="$(parse_remap_line "$line")"
      [[ -n "$parsed" ]] || continue
      IFS=$'\t' read -r from to <<< "$parsed"
      case "$p" in
        "$from"*) printf '%s%s' "$to" "${p#"$from"}"; return 0;;
      esac
    done < "$f"
  fi

  # 2) Legacy single mapping from .env, kept for compatibility.
  if [[ -n "$PATH_REMAP_FROM" && -n "$PATH_REMAP_TO" ]]; then
    case "$p" in
      "$PATH_REMAP_FROM"*) printf '%s%s' "$PATH_REMAP_TO" "${p#"$PATH_REMAP_FROM"}"; return 0;;
    esac
  fi

  printf '%s' "$p"
}

map_path(){
  local p="$1"
  local mapped original_source target_source

  mapped="$(apply_custom_path_remaps "$p")"
  if [[ "$mapped" != "$p" ]]; then
    printf '%s' "$mapped"
    return 0
  fi

  original_source="$(manifest_value SOURCE_DIR)"
  target_source="$SOURCE_DIR"
  if [[ -n "$original_source" && -n "$target_source" && "$original_source" != "$target_source" ]]; then
    case "$p" in
      "$original_source"*) printf '%s%s' "$target_source" "${p#"$original_source"}"; return 0;;
    esac
  fi

  printf '%s' "$p"
}

project_selected(){
  local project="$1"
  local restore_all p
  restore_all="$(lower "$RESTORE_ALL_PROJECTS")"

  for p in $(split_words "$EXCLUDE_PROJECTS"); do
    [[ "$project" == "$p" ]] && return 1
  done

  if [[ "$project" == standalone_* ]] && is_false "$RESTORE_STANDALONE_CONTAINERS"; then
    return 1
  fi

  if [[ "$restore_all" == "true" || "$restore_all" == "1" || "$restore_all" == "yes" || "$restore_all" == "ja" ]]; then
    return 0
  fi

  # Safer default: RESTORE_ALL_PROJECTS=false and RESTORE_PROJECTS empty
  # means all projects that are really present in project_archives.tsv.
  if [[ -z "${RESTORE_PROJECTS// }" ]]; then
    return 0
  fi

  for p in $(split_words "$RESTORE_PROJECTS"); do
    [[ "$project" == "$p" ]] && return 0
  done
  return 1
}


validate_restore_selection(){
  log_i "[Check] Prüfe Restore-Auswahl." "[Check] Validating restore selection."

  if [[ -z "${RESTORE_ARCHIVE:-}" ]]; then
    die "$(tr_text '[Fehler] RESTORE_ARCHIVE ist nicht gesetzt.' '[Error] RESTORE_ARCHIVE is not set.')"
  fi

  if [[ ! -f "${RESTORE_ARCHIVE}" ]]; then
    die "$(tr_text "[Fehler] Restore-Archiv nicht gefunden: ${RESTORE_ARCHIVE}" "[Error] Restore archive not found: ${RESTORE_ARCHIVE}")"
  fi

  if is_true "${RESTORE_ALL_PROJECTS:-false}"; then
    log_i "[Check] Restore-Auswahl: alle Projekte." "[Check] Restore selection: all projects."
    return 0
  fi

  if [[ -z "${RESTORE_PROJECTS:-}" ]]; then
    log_i "[Check] RESTORE_ALL_PROJECTS=false und RESTORE_PROJECTS leer. Es werden alle im Backup vorhandenen Projekte berücksichtigt." "[Check] RESTORE_ALL_PROJECTS=false and RESTORE_PROJECTS is empty. All projects present in the backup will be considered."
    return 0
  fi

  log_i "[Check] Restore-Auswahl: ${RESTORE_PROJECTS}" "[Check] Restore selection: ${RESTORE_PROJECTS}"
  return 0
}

confirm_restore(){
  if is_true "$DRY_RUN"; then
    log_i "[DRY-RUN] Es werden keine Änderungen vorgenommen." "[DRY-RUN] No changes will be made."
    return 0
  fi

  is_true "$RESTORE_CONFIRMATION_REQUIRED" || return 0

  if [[ ! -t 0 ]]; then
    die "$(tr_text 'Bestätigung erforderlich, aber keine interaktive Konsole verfügbar. Setze RESTORE_CONFIRMATION_REQUIRED=false für automatischen Restore.' 'Confirmation required, but no interactive terminal available. Set RESTORE_CONFIRMATION_REQUIRED=false for automated restore.')"
  fi

  echo
  echo "$(tr_text 'ACHTUNG: Der Restore kann Dateien überschreiben und die UGOS-Docker-Datenbank ändern.' 'WARNING: Restore may overwrite files and modify the UGOS Docker database.')"
  read -r -p "$(tr_text 'Zum Fortfahren RESTORE eingeben: ' 'Type RESTORE to continue: ')" answer
  [[ "$answer" == "RESTORE" ]] || die "$(tr_text 'Restore abgebrochen.' 'Restore cancelled.')"
}

apply_path_remap_to_files(){
  local dir="$1"
  is_true "$APPLY_PATH_REMAP_TO_TEXT_FILES" || return 0
  is_true "$ENABLE_PATH_REMAP" || return 0

  local rules_file="${extract_parent}/path-remap-rules.tsv"
  local remap_file line parsed from to original_source
  : > "$rules_file"

  remap_file="$(effective_remap_file)"
  if [[ -n "$remap_file" && -f "$remap_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      parsed="$(parse_remap_line "$line")"
      [[ -n "$parsed" ]] || continue
      printf '%s\n' "$parsed" >> "$rules_file"
    done < "$remap_file"
  fi

  if [[ -n "$PATH_REMAP_FROM" && -n "$PATH_REMAP_TO" ]]; then
    printf '%s\t%s\n' "${PATH_REMAP_FROM%/}" "${PATH_REMAP_TO%/}" >> "$rules_file"
  fi

  original_source="$(manifest_value SOURCE_DIR)"
  if [[ -n "$original_source" && -n "$SOURCE_DIR" && "$original_source" != "$SOURCE_DIR" ]]; then
    printf '%s\t%s\n' "${original_source%/}" "${SOURCE_DIR%/}" >> "$rules_file"
  fi

  if [[ ! -s "$rules_file" ]]; then
    return 0
  fi

  log_i "[Restore] Passe Pfade in Textdateien per Remap-Regeln an." "[Restore] Remapping paths in text files using mapping rules."
  while IFS=$'\t' read -r from to; do
    [[ -n "$from" && -n "$to" ]] || continue
    log "  ${from} -> ${to}"
  done < "$rules_file"

  if is_true "$DRY_RUN"; then
    return 0
  fi

  "$PYTHON_BIN" - "$dir" "$rules_file" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
rules_path = Path(sys.argv[2])
rules = []
for line in rules_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    parts = line.split("\t", 1)
    if len(parts) != 2:
        continue
    old, new = parts[0].strip(), parts[1].strip()
    if old and new and old != new:
        rules.append((old, new))

suffixes = {".yml", ".yaml", ".env", ".json", ".txt", ".conf", ".ini"}
names = {".env", "docker-compose.yaml", "docker-compose.yml", "compose.yaml", "compose.yml"}

for p in root.rglob("*"):
    if not p.is_file():
        continue
    if p.name not in names and p.suffix.lower() not in suffixes:
        continue
    try:
        data = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    except Exception:
        continue
    new_data = data
    for old, new in rules:
        new_data = new_data.replace(old, new)
    if new_data != data:
        p.write_text(new_data, encoding="utf-8")
PY
}

restore_project_dirs(){
  local mapfile="${backup_root}/metadata/project_archives.tsv"
  [[ -f "$mapfile" ]] || die "$(tr_text 'project_archives.tsv fehlt im Backup.' 'project_archives.tsv is missing in the backup.')"

  mkdir_safe "$SOURCE_DIR"

  local project archive workdir config_files target_dir target_parent tmp_project top
  while IFS=$'\t' read -r project archive workdir config_files; do
    [[ "$project" == "project" || -z "$project" ]] && continue
    project_selected "$project" || {
      log_i "[Restore] Projekt ${project} wird übersprungen." "[Restore] Project ${project} is skipped."
      continue
    }

    target_dir="$(map_path "$workdir")"
    target_parent="$(dirname "$target_dir")"
    log_i "[Restore] Projekt ${project}: ${workdir} -> ${target_dir}" "[Restore] Project ${project}: ${workdir} -> ${target_dir}"

    if [[ -e "$target_dir" ]]; then
      if is_false "$RESTORE_OVERWRITE_EXISTING"; then
        log_i "[Restore] Ziel existiert bereits und wird nicht überschrieben: ${target_dir}" "[Restore] Target already exists and will not be overwritten: ${target_dir}"
        # Existing project folder is kept, but remap still has to be applied to compose/.env/text files.
        apply_path_remap_to_files "$target_dir"
        continue
      fi
      run_cmd mv "$target_dir" "${target_dir}.restore-backup-$(date +'%Y-%m-%d_%H-%M-%S')"
    fi

    if is_true "$DRY_RUN"; then
      continue
    fi

    mkdir_safe "$target_parent"
    tmp_project="${extract_parent}/project_extract_${project}"
    rm -rf "$tmp_project"
    mkdir_safe "$tmp_project"
    tar -xpf "${backup_root}/${archive}" -C "$tmp_project"
    top="$(find "$tmp_project" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
    [[ -n "$top" ]] || die "$(tr_text "Projektarchiv leer oder ungültig: ${archive}" "Project archive empty or invalid: ${archive}")"
    mv "$top" "$target_dir"
    apply_path_remap_to_files "$target_dir"
    if [[ "$project" == standalone_* ]]; then
      apply_restore_permissions "$target_dir" || return 1
    fi
  done < "$mapfile"
}

restore_images(){
  is_true "$RESTORE_IMAGES" || return 0
  local img="${backup_root}/images/docker-images.tar"
  [[ -f "$img" ]] || return 0
  log_i "[Images] Lade Docker Images." "[Images] Loading Docker images."
  run_cmd $DOCKER_BIN load -i "$img"
}

restore_named_volumes(){
  is_true "$RESTORE_NAMED_VOLUMES" || return 0
  local vf="${backup_root}/metadata/volume_archives.tsv"
  [[ -f "$vf" ]] || return 0
  log_i "[Volumes] Stelle Named Volumes wieder her." "[Volumes] Restoring named volumes."

  local name archive source target_source parent base tmp top
  while IFS=$'\t' read -r name archive source; do
    [[ "$name" == "name" || -z "$name" || -z "$archive" ]] && continue
    target_source="$(map_path "$source")"
    parent="$(dirname "$target_source")"
    log_i "[Volumes] Volume ${name}: ${target_source}" "[Volumes] Volume ${name}: ${target_source}"
    if is_true "$DRY_RUN"; then
      continue
    fi
    $DOCKER_BIN volume create "$name" >/dev/null 2>&1 || true
    mkdir_safe "$parent"
    tmp="${extract_parent}/volume_extract_${name}"
    rm -rf "$tmp"
    mkdir_safe "$tmp"
    tar -xpf "${backup_root}/${archive}" -C "$tmp"
    top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
    [[ -n "$top" ]] || continue
    rm -rf "$target_source"
    mv "$top" "$target_source"
  done < "$vf"
}


valid_chmod_mode(){
  [[ "${1:-}" =~ ^[0-7]{3,4}$ ]]
}

resolve_permission_owner(){
  local target_path="$1"
  local owner="${RESTORE_FIX_OWNER:-auto}"
  local parent

  case "$(lower "$owner")" in
    ""|keep|false|no|none|disabled)
      printf ''
      return 0
      ;;
    auto)
      parent="$(dirname "$target_path")"
      if [[ -e "$parent" ]]; then
        stat -c '%u:%g' "$parent" 2>/dev/null || true
      fi
      return 0
      ;;
    *)
      printf '%s' "$owner"
      return 0
      ;;
  esac
}

apply_restore_permissions(){
  local target_path="$1"
  [[ -e "$target_path" ]] || return 0
  is_true "$RESTORE_FIX_PERMISSIONS" || return 0

  local owner dir_mode file_mode
  owner="$(resolve_permission_owner "$target_path")"
  dir_mode="${RESTORE_FIX_DIR_MODE:-}"
  file_mode="${RESTORE_FIX_FILE_MODE:-}"

  log_i "[Rechte] Passe Rechte für wiederhergestellten Pfad an: ${target_path}" "[Permissions] Adjusting permissions for restored path: ${target_path}"

  if is_true "$DRY_RUN"; then
    log_i "[DRY-RUN] Rechte würden angepasst: Owner=${owner:-unverändert}, Ordner=${dir_mode:-unverändert}, Dateien=${file_mode:-unverändert}" "[DRY-RUN] Permissions would be adjusted: owner=${owner:-unchanged}, directories=${dir_mode:-unchanged}, files=${file_mode:-unchanged}"
    return 0
  fi

  if [[ -n "$owner" ]]; then
    if ! chown -R "$owner" "$target_path" >> "$log_file" 2>&1; then
      RESTORE_FAILURE_REASON="$(tr_text "Rechtekorrektur fehlgeschlagen: chown -R ${owner} ${target_path}" "Permission fix failed: chown -R ${owner} ${target_path}")"
      return 1
    fi
  fi

  if valid_chmod_mode "$dir_mode"; then
    if [[ -d "$target_path" ]]; then
      if ! find "$target_path" -type d -exec chmod "$dir_mode" {} + >> "$log_file" 2>&1; then
        RESTORE_FAILURE_REASON="$(tr_text "Rechtekorrektur fehlgeschlagen: chmod ${dir_mode} für Ordner unter ${target_path}" "Permission fix failed: chmod ${dir_mode} for directories below ${target_path}")"
        return 1
      fi
    fi
  elif [[ -n "$dir_mode" ]]; then
    log_i "[Rechte] Ungültiger Ordner-Modus wird ignoriert: ${dir_mode}" "[Permissions] Invalid directory mode ignored: ${dir_mode}"
  fi

  if valid_chmod_mode "$file_mode"; then
    if [[ -f "$target_path" ]]; then
      if ! chmod "$file_mode" "$target_path" >> "$log_file" 2>&1; then
        RESTORE_FAILURE_REASON="$(tr_text "Rechtekorrektur fehlgeschlagen: chmod ${file_mode} ${target_path}" "Permission fix failed: chmod ${file_mode} ${target_path}")"
        return 1
      fi
    elif [[ -d "$target_path" ]]; then
      if ! find "$target_path" -type f -exec chmod "$file_mode" {} + >> "$log_file" 2>&1; then
        RESTORE_FAILURE_REASON="$(tr_text "Rechtekorrektur fehlgeschlagen: chmod ${file_mode} für Dateien unter ${target_path}" "Permission fix failed: chmod ${file_mode} for files below ${target_path}")"
        return 1
      fi
    fi
  elif [[ -n "$file_mode" ]]; then
    log_i "[Rechte] Ungültiger Datei-Modus wird ignoriert: ${file_mode}" "[Permissions] Invalid file mode ignored: ${file_mode}"
  fi

  return 0
}


restore_external_binds(){
  is_true "$RESTORE_EXTERNAL_BINDS" || return 0
  local vf="${backup_root}/metadata/external_bind_archives.tsv"
  [[ -f "$vf" ]] || {
    log_i "[Bind-Mounts] Keine externen Bind-Mount-Archive im Backup gefunden." "[Bind mounts] No external bind mount archives found in the backup."
    return 0
  }

  log_i "[Bind-Mounts] Stelle externe Bind-Mounts wieder her." "[Bind mounts] Restoring external bind mounts."

  local report_file="${extract_parent}/restored_external_binds.tsv"
  printf 'project\tcontainer\tsource\ttarget\tdestination\tarchive\tstatus\n' > "$report_file"

  local project container source destination rw archive target_source target_parent tmp top backup_archive status target_base
  while IFS=$'\t' read -r project container source destination rw archive; do
    [[ "$project" == "project" || -z "$project" ]] && continue
    project_selected "$project" || continue
    [[ -n "$archive" ]] || continue

    backup_archive="${backup_root}/${archive}"
    target_source="$(map_path "$source")"
    target_parent="$(dirname "$target_source")"
    target_base="$(basename "$target_source")"

    if [[ ! -f "$backup_archive" ]]; then
      status="missing-archive"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$project" "$container" "$source" "$target_source" "$destination" "$archive" "$status" >> "$report_file"
      RESTORE_FAILURE_REASON="$(tr_text "Externes Bind-Mount-Archiv fehlt für ${project}: ${archive}" "External bind mount archive missing for ${project}: ${archive}")"
      log_i "[Bind-Mounts] Archiv fehlt: ${backup_archive}" "[Bind mounts] Archive missing: ${backup_archive}"
      return 1
    fi

    log_i "[Bind-Mounts] ${project}: ${source} -> ${target_source}" "[Bind mounts] ${project}: ${source} -> ${target_source}"

    if [[ -e "$target_source" ]]; then
      if is_false "$RESTORE_OVERWRITE_EXISTING"; then
        status="skipped-existing"
        log_i "[Bind-Mounts] Ziel existiert bereits und wird nicht überschrieben: ${target_source}" "[Bind mounts] Target already exists and will not be overwritten: ${target_source}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$project" "$container" "$source" "$target_source" "$destination" "$archive" "$status" >> "$report_file"
        continue
      fi
      run_cmd mv "$target_source" "${target_source}.restore-backup-$(date +'%Y-%m-%d_%H-%M-%S')"
    fi

    if is_true "$DRY_RUN"; then
      status="dry-run"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$project" "$container" "$source" "$target_source" "$destination" "$archive" "$status" >> "$report_file"
      continue
    fi

    mkdir_safe "$target_parent"
    tmp="${extract_parent}/external_bind_extract_${project}_${target_base}"
    rm -rf "$tmp"
    mkdir_safe "$tmp"
    tar -xpf "$backup_archive" -C "$tmp"
    top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
    if [[ -z "$top" ]]; then
      top="$(find "$tmp" -mindepth 1 -maxdepth 1 | head -n 1 || true)"
    fi
    if [[ -z "$top" ]]; then
      status="empty-archive"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$project" "$container" "$source" "$target_source" "$destination" "$archive" "$status" >> "$report_file"
      RESTORE_FAILURE_REASON="$(tr_text "Externes Bind-Mount-Archiv ist leer oder ungültig: ${archive}" "External bind mount archive is empty or invalid: ${archive}")"
      log_i "[Bind-Mounts] Archiv leer oder ungültig: ${archive}" "[Bind mounts] Archive empty or invalid: ${archive}"
      return 1
    fi

    mv "$top" "$target_source"
    apply_restore_permissions "$target_source"
    status="restored"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$project" "$container" "$source" "$target_source" "$destination" "$archive" "$status" >> "$report_file"
  done < "$vf"
}


restore_docker_networks(){
  is_true "$RESTORE_RECREATE_NETWORKS" || return 0
  local plan="${backup_root}/metadata/network_create_plan.json"
  [[ -f "$plan" ]] || {
    log_i "[Netzwerke] Kein Netzwerk-Wiederherstellungsplan im Backup gefunden, überspringe." "[Networks] No network restore plan found in backup, skipping."
    return 0
  }

  log_i "[Netzwerke] Netzwerke aus dem Backup werden vor dem Compose-Start geprüft." "[Networks] Checking backup networks before Compose startup."

  export RESTORE_CREATE_MISSING_NETWORKS RESTORE_CREATE_MACVLAN_NETWORKS RESTORE_MACVLAN_PARENT RESTORE_MACVLAN_PARENT_MAP RESTORE_FAIL_ON_NETWORK_ERROR DRY_RUN LANGUAGE
  "$PYTHON_BIN" - "$plan" "$DOCKER_BIN" "$log_file" <<'PYNET'
import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path

plan_file, docker_bin, log_file = sys.argv[1:4]
log_path = Path(log_file)

TRUE = {"true", "1", "yes", "y", "ja", "on"}

def is_true(value):
    return str(value or "").strip().lower() in TRUE

def log(msg):
    with log_path.open("a", encoding="utf-8") as f:
        f.write(msg + "\n")
    print(msg)

def run(cmd):
    log("+ " + " ".join(cmd))
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.stdout:
        with log_path.open("a", encoding="utf-8") as f:
            f.write(proc.stdout)
        print(proc.stdout, end="")
    return proc.returncode

def exists_net(name):
    return subprocess.run([docker_bin, "network", "inspect", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def iface_exists(name):
    return bool(name) and Path("/sys/class/net", name).exists()

def proc_default_ifaces():
    result = []
    try:
        out = subprocess.run(["ip", "-o", "-4", "route", "show", "default"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        for line in out.splitlines():
            parts = line.split()
            if "dev" in parts and parts.index("dev") + 1 < len(parts):
                result.append(parts[parts.index("dev") + 1])
    except Exception:
        pass
    if not result:
        try:
            for line in Path("/proc/net/route").read_text().splitlines()[1:]:
                parts = line.split()
                if len(parts) > 1 and parts[1] == "00000000":
                    result.append(parts[0])
        except Exception:
            pass
    return result

def ifaces_with_subnet(subnet):
    result = []
    if not subnet:
        return result
    try:
        net = ipaddress.ip_network(subnet, strict=False)
    except Exception:
        return result
    try:
        out = subprocess.run(["ip", "-o", "-4", "addr", "show", "scope", "global"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[2] == "inet":
                iface = parts[1]
                addr = parts[3].split("/", 1)[0]
                try:
                    if ipaddress.ip_address(addr) in net:
                        result.append(iface)
                except Exception:
                    pass
    except Exception:
        pass
    return result

def bridge_members(iface):
    members = []
    p = Path("/sys/class/net", iface, "brif")
    if p.exists():
        try:
            members.extend(sorted(x.name for x in p.iterdir()))
        except Exception:
            pass
    return members

def all_up_ifaces():
    result = []
    base = Path("/sys/class/net")
    try:
        for p in sorted(base.iterdir()):
            n = p.name
            if n in ("lo", "docker0") or n.startswith(("veth", "br-", "virbr")):
                continue
            state = (p / "operstate").read_text().strip() if (p / "operstate").exists() else ""
            if state in ("up", "unknown"):
                result.append(n)
    except Exception:
        pass
    return result

def parse_parent_map(value):
    mapping = {}
    for token in re.split(r"[;,\s]+", value or ""):
        token = token.strip()
        if not token or "=" not in token:
            continue
        k, v = token.split("=", 1)
        if k.strip() and v.strip():
            mapping[k.strip()] = v.strip()
    return mapping

def add_candidate(cands, value):
    if not value:
        return
    value = value.strip()
    if value and value not in cands and iface_exists(value):
        cands.append(value)

def macvlan_parent_candidates(item):
    name = item.get("name") or ""
    opts = item.get("options") or {}
    cfg = (item.get("ipam_config") or [{}])[0] if item.get("ipam_config") else {}
    subnet = cfg.get("Subnet") or ""
    env_parent = os.environ.get("RESTORE_MACVLAN_PARENT", "auto").strip()
    parent_map = parse_parent_map(os.environ.get("RESTORE_MACVLAN_PARENT_MAP", ""))

    cands = []
    add_candidate(cands, parent_map.get(name))

    if env_parent and env_parent.lower() != "auto":
        add_candidate(cands, env_parent)

    # Backup option is used only if it is a real Linux interface on this NAS.
    add_candidate(cands, str(opts.get("parent") or "").strip())

    # Auto-detect the active LAN interface on the restore NAS.
    for iface in ifaces_with_subnet(subnet):
        add_candidate(cands, iface)
        for member in bridge_members(iface):
            add_candidate(cands, member)
    for iface in proc_default_ifaces():
        add_candidate(cands, iface)
        for member in bridge_members(iface):
            add_candidate(cands, member)
    for iface in all_up_ifaces():
        add_candidate(cands, iface)

    return cands

def build_base_cmd(item, driver):
    cmd = [docker_bin, "network", "create", "--driver", driver]
    if item.get("internal"):
        cmd.append("--internal")
    if item.get("attachable"):
        cmd.append("--attachable")
    if item.get("enable_ipv6"):
        cmd.append("--ipv6")

    ipam_driver = item.get("ipam_driver") or "default"
    if ipam_driver and ipam_driver != "default":
        cmd += ["--ipam-driver", ipam_driver]

    for cfg in item.get("ipam_config") or []:
        subnet = cfg.get("Subnet") or ""
        gateway = cfg.get("Gateway") or ""
        ip_range = cfg.get("IPRange") or ""
        if subnet:
            cmd += ["--subnet", subnet]
        if gateway:
            cmd += ["--gateway", gateway]
        if ip_range:
            cmd += ["--ip-range", ip_range]
        for aux_name, aux_ip in (cfg.get("AuxiliaryAddresses") or {}).items():
            if aux_name and aux_ip:
                cmd += ["--aux-address", f"{aux_name}={aux_ip}"]
    return cmd

def print_manual_hint(item):
    name = item.get("name") or ""
    driver = item.get("driver") or ""
    cfg = (item.get("ipam_config") or [{}])[0] if item.get("ipam_config") else {}
    subnet = cfg.get("Subnet", "")
    gateway = cfg.get("Gateway", "")
    parent = (item.get("options") or {}).get("parent", "")
    log("[Netzwerke] Manuelle Anlage in UGOS Docker-App:")
    log(f"  Name    : {name}")
    log(f"  Modus   : {driver}")
    if parent:
        log(f"  Parent aus Backup: {parent}")
    if subnet:
        log(f"  Subnetz : {subnet}")
    if gateway:
        log(f"  Gateway : {gateway}")
    log("  Hinweis : In UGOS bei macvlan die LAN-Karte auswaehlen, z. B. BR-LAN1. Docker CLI benoetigt dagegen den echten Linux-Interface-Namen wie bridge0 oder eth0.")

def create_network(item):
    name = item.get("name") or ""
    driver = item.get("driver") or "bridge"
    opts = item.get("options") or {}
    labels = item.get("labels") or {}

    if driver == "macvlan":
        if not is_true(os.environ.get("RESTORE_CREATE_MACVLAN_NETWORKS", "true")):
            log(f"[Netzwerke] FEHLT macvlan: {name}. Automatisches Anlegen ist deaktiviert.")
            print_manual_hint(item)
            return False
        candidates = macvlan_parent_candidates(item)
        if not candidates:
            log(f"[Netzwerke] FEHLT macvlan: {name}. Keine passende Linux-Netzwerkschnittstelle erkannt.")
            print_manual_hint(item)
            return False

        base = build_base_cmd(item, driver)
        filtered_opts = {k: v for k, v in opts.items() if k != "parent"}
        for k, v in sorted(filtered_opts.items()):
            if k and v is not None:
                base += ["-o", f"{k}={v}"]
        for k, v in sorted(labels.items()):
            if k and v is not None:
                base += ["--label", f"{k}={v}"]

        log(f"[Netzwerke] Erstelle macvlan-Netzwerk {name}. Kandidaten fuer parent: {', '.join(candidates)}")
        for parent in candidates:
            cmd = list(base) + ["-o", f"parent={parent}", name]
            rc = run(cmd)
            if rc == 0:
                log(f"[Netzwerke] OK: macvlan-Netzwerk {name} wurde mit parent={parent} erstellt.")
                return True
            subprocess.run([docker_bin, "network", "rm", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"[Netzwerke] FEHLER: macvlan-Netzwerk {name} konnte mit keinem Kandidaten erstellt werden.")
        print_manual_hint(item)
        return False

    cmd = build_base_cmd(item, driver)
    for k, v in sorted(opts.items()):
        if k and v is not None:
            cmd += ["-o", f"{k}={v}"]
    for k, v in sorted(labels.items()):
        if k and v is not None:
            cmd += ["--label", f"{k}={v}"]
    cmd.append(name)
    return run(cmd) == 0

try:
    plan = json.loads(Path(plan_file).read_text(encoding="utf-8"))
except Exception as exc:
    log(f"[Netzwerke] Netzwerkplan konnte nicht gelesen werden: {exc}")
    raise SystemExit(0)

if not isinstance(plan, list):
    log("[Netzwerke] Netzwerkplan hat ein ungueltiges Format, ueberspringe.")
    raise SystemExit(0)

missing = []
for item in plan:
    name = item.get("name") or ""
    if not name or name in ("bridge", "host", "none"):
        continue
    cfg = (item.get("ipam_config") or [{}])[0] if item.get("ipam_config") else {}
    detail = f"{name} ({item.get('driver') or 'bridge'}"
    if cfg.get("Subnet"):
        detail += f", subnet={cfg.get('Subnet')}"
    if cfg.get("Gateway"):
        detail += f", gateway={cfg.get('Gateway')}"
    detail += ")"
    if exists_net(name):
        log(f"[Netzwerke] OK vorhanden: {detail}")
    else:
        log(f"[Netzwerke] FEHLT: {detail}")
        missing.append(item)

if not missing:
    log("[Netzwerke] OK: Alle im Backup benoetigten Netzwerke sind vorhanden.")
    raise SystemExit(0)

if is_true(os.environ.get("DRY_RUN", "true")):
    log("[DRY-RUN] Fehlende Netzwerke wuerden vor dem Compose-Start angelegt bzw. als manuelle Aktion gemeldet.")
    for item in missing:
        if (item.get("driver") or "") == "macvlan":
            cands = macvlan_parent_candidates(item)
            log(f"[DRY-RUN] macvlan {item.get('name')}: parent-Kandidaten: {', '.join(cands) if cands else 'keine'}")
    raise SystemExit(0)

if not is_true(os.environ.get("RESTORE_CREATE_MISSING_NETWORKS", "true")):
    log("[Netzwerke] Automatisches Anlegen fehlender Netzwerke ist deaktiviert.")
    for item in missing:
        print_manual_hint(item)
    raise SystemExit(2 if is_true(os.environ.get("RESTORE_FAIL_ON_NETWORK_ERROR", "true")) else 0)

failed = []
for item in missing:
    if not create_network(item):
        failed.append(item.get("name") or "unknown")

if failed:
    log("[Netzwerke] FEHLER: Folgende Netzwerke fehlen weiterhin: " + ", ".join(failed))
    raise SystemExit(2 if is_true(os.environ.get("RESTORE_FAIL_ON_NETWORK_ERROR", "true")) else 0)

log("[Netzwerke] OK: Fehlende Netzwerke wurden angelegt.")
PYNET
}


validate_bind_mounts_for_project(){
  local project="$1"
  is_true "$RESTORE_VALIDATE_BIND_MOUNTS" || return 0

  local vf="${backup_root}/metadata/bind_mounts.tsv"
  local fallback="false"
  if [[ ! -f "$vf" ]]; then
    vf="${backup_root}/metadata/external_bind_mounts.tsv"
    fallback="true"
  fi
  [[ -f "$vf" ]] || return 0

  local row_project container source destination rw inside_project inside_source source_type mapped_source missing=0 mismatch=0
  while IFS=$'\t' read -r row_project container source destination rw inside_project inside_source source_type; do
    [[ "$row_project" == "project" || -z "$row_project" || -z "$source" ]] && continue
    [[ "$row_project" == "$project" ]] || continue
    mapped_source="$(map_path "$source")"

    if [[ -z "$mapped_source" || ! -e "$mapped_source" ]]; then
      log_i "[Bind-Mounts] Fehlender Bind-Mount-Pfad für ${project}: ${mapped_source} -> ${destination}" "[Bind mounts] Missing bind mount path for ${project}: ${mapped_source} -> ${destination}"
      missing=$((missing+1))
      continue
    fi

    if [[ "$fallback" != "true" ]]; then
      case "$source_type" in
        file)
          if [[ ! -f "$mapped_source" ]]; then
            log_i "[Bind-Mounts] Typfehler für ${project}: Datei erwartet, aber Ziel ist keine Datei: ${mapped_source} -> ${destination}" "[Bind mounts] Type mismatch for ${project}: file expected, but target is not a file: ${mapped_source} -> ${destination}"
            mismatch=$((mismatch+1))
          fi
          ;;
        dir)
          if [[ ! -d "$mapped_source" ]]; then
            log_i "[Bind-Mounts] Typfehler für ${project}: Ordner erwartet, aber Ziel ist kein Ordner: ${mapped_source} -> ${destination}" "[Bind mounts] Type mismatch for ${project}: directory expected, but target is not a directory: ${mapped_source} -> ${destination}"
            mismatch=$((mismatch+1))
          fi
          ;;
      esac
    fi
  done < "$vf"

  if (( missing > 0 || mismatch > 0 )); then
    RESTORE_FAILURE_REASON="$(tr_text "Bind-Mount-Prüfung für Projekt ${project} fehlgeschlagen: ${missing} fehlend, ${mismatch} Typfehler." "Bind mount validation for project ${project} failed: ${missing} missing, ${mismatch} type mismatch.")"
    return 1
  fi
  return 0
}
compose_error_file(){
  printf '%s' "${extract_parent}/restore_compose_errors.tsv"
}

record_compose_error(){
  local project="$1" reason="$2" file
  file="$(compose_error_file)"
  if [[ ! -f "$file" ]]; then
    printf 'project\treason\n' > "$file"
  fi
  printf '%s\t%s\n' "$project" "$reason" >> "$file"
  RESTORE_COMPOSE_FAILED=1
  RESTORE_COMPOSE_ERROR_COUNT=$((RESTORE_COMPOSE_ERROR_COUNT+1))
  [[ -n "${RESTORE_FAILURE_REASON:-}" ]] || RESTORE_FAILURE_REASON="$reason"
}

handle_compose_error(){
  local project="$1" reason="$2"
  record_compose_error "$project" "$reason"
  if is_true "$RESTORE_CONTINUE_ON_COMPOSE_ERROR"; then
    log_i "[Compose] WARNUNG: ${project} fehlgeschlagen, Restore läuft mit den nächsten Projekten weiter. Grund: ${reason}" "[Compose] WARNING: ${project} failed, restore continues with the next projects. Reason: ${reason}"
    return 0
  fi
  log_i "[Compose] Fehler: ${project}: ${reason}" "[Compose] Error: ${project}: ${reason}"
  return 1
}

compose_up_projects(){
  is_true "$RESTORE_RUN_COMPOSE_UP" || return 0
  local mapfile="${backup_root}/metadata/project_archives.tsv"
  [[ -f "$mapfile" ]] || return 0

  local project archive workdir config_files target_dir cf mapped_cf args missing reason

  while IFS=$'\t' read -r project archive workdir config_files; do
    [[ "$project" == "project" || -z "$project" ]] && continue
    project_selected "$project" || continue

    target_dir="$(map_path "$workdir")"
    if [[ ! -d "$target_dir" ]]; then
      reason="$(tr_text "Projektordner nicht vorhanden: ${target_dir}" "Project folder missing: ${target_dir}")"
      if ! handle_compose_error "$project" "$reason"; then return 1; fi
      continue
    fi

    if ! validate_bind_mounts_for_project "$project"; then
      reason="${RESTORE_FAILURE_REASON:-$(tr_text "Bind-Mount-Prüfung fehlgeschlagen" "Bind mount validation failed")}"
      if ! handle_compose_error "$project" "$reason"; then return 1; fi
      continue
    fi

    if is_true "$RESTORE_STOP_EXISTING_PROJECTS"; then
      log_i "[Compose] Stoppe bestehendes Projekt ${project}, falls vorhanden." "[Compose] Stopping existing project ${project}, if present."
      run_cmd_in_dir "$target_dir" $DOCKER_BIN compose -p "$project" down || true
    fi

    args=()
    missing=0
    IFS=',' read -r -a cf_array <<< "${config_files:-}"
    if ((${#cf_array[@]} == 0)) || [[ -z "${cf_array[0]:-}" ]]; then
      if [[ -f "${target_dir}/docker-compose.yaml" ]]; then
        cf_array=("${workdir}/docker-compose.yaml")
      elif [[ -f "${target_dir}/docker-compose.yml" ]]; then
        cf_array=("${workdir}/docker-compose.yml")
      elif [[ -f "${target_dir}/compose.yaml" ]]; then
        cf_array=("${workdir}/compose.yaml")
      elif [[ -f "${target_dir}/compose.yml" ]]; then
        cf_array=("${workdir}/compose.yml")
      fi
    fi

    for cf in "${cf_array[@]}"; do
      [[ -z "$cf" ]] && continue
      mapped_cf="$(map_path "$cf")"
      if [[ ! -f "$mapped_cf" ]]; then
        log_i "[Compose] Compose-Datei fehlt: ${mapped_cf}" "[Compose] Compose file missing: ${mapped_cf}"
        missing=1
      else
        args+=("-f" "$mapped_cf")
      fi
    done

    if (( missing == 1 || ${#args[@]} == 0 )); then
      reason="$(tr_text "Keine gültige Compose-Datei für Projekt ${project} gefunden." "No valid Compose file found for project ${project}.")"
      if ! handle_compose_error "$project" "$reason"; then return 1; fi
      continue
    fi

    log_i "[Compose] Starte Projekt ${project}." "[Compose] Starting project ${project}."
    if ! run_cmd_in_dir "$target_dir" $DOCKER_BIN compose -p "$project" "${args[@]}" up -d; then
      reason="${RESTORE_FAILURE_REASON:-$(tr_text "docker compose up fehlgeschlagen" "docker compose up failed")}"
      if ! handle_compose_error "$project" "$reason"; then return 1; fi
      continue
    fi
  done < "$mapfile"

  if (( RESTORE_COMPOSE_FAILED > 0 )); then
    log_i "[Compose] Restore wurde fortgesetzt, aber ${RESTORE_COMPOSE_ERROR_COUNT} Projekt(e) hatten Compose-Fehler. Details: $(compose_error_file)" "[Compose] Restore continued, but ${RESTORE_COMPOSE_ERROR_COUNT} project(s) had Compose errors. Details: $(compose_error_file)"
  fi
}

update_ugos_db(){
  if ! is_true "$UPDATE_UGOS_DOCKER_DB"; then
    UGOS_DB_STATUS="$(tr_text 'deaktiviert' 'disabled')"
    return 0
  fi
  [[ -n "$UGOS_DOCKER_DB" ]] || {
    UGOS_DB_STATUS="$(tr_text 'übersprungen, keine UGOS-Docker-DB gefunden' 'skipped, no UGOS Docker DB found')"
    log_i "[UGOS-DB] Keine UGOS-Docker-DB gefunden, DB-Abgleich wird übersprungen." "[UGOS DB] No UGOS Docker DB found, skipping DB sync."
    return 0
  }
  [[ -f "$UGOS_DOCKER_DB" ]] || {
    UGOS_DB_STATUS="$(tr_text 'übersprungen, DB-Datei nicht gefunden' 'skipped, DB file not found'): ${UGOS_DOCKER_DB}"
    log_i "[UGOS-DB] Datei nicht gefunden: ${UGOS_DOCKER_DB}" "[UGOS DB] File not found: ${UGOS_DOCKER_DB}"
    return 0
  }
  local json_file="${backup_root}/metadata/ugos_compose_table.json"
  [[ -f "$json_file" ]] || {
    UGOS_DB_STATUS="$(tr_text 'übersprungen, ugos_compose_table.json fehlt' 'skipped, ugos_compose_table.json missing')"
    log_i "[UGOS-DB] ugos_compose_table.json fehlt, DB-Abgleich wird übersprungen." "[UGOS DB] ugos_compose_table.json missing, skipping DB sync."
    return 0
  }

  log_i "[UGOS-DB] Compose-Tabelle wird abgeglichen." "[UGOS DB] Syncing compose table."

  if is_true "$DRY_RUN"; then
    UGOS_DB_STATUS="DRY-RUN, $(tr_text 'würde aktualisiert' 'would update'): ${UGOS_DOCKER_DB}"
    log_i "[DRY-RUN] UGOS-DB würde aktualisiert: ${UGOS_DOCKER_DB}" "[DRY-RUN] UGOS DB would be updated: ${UGOS_DOCKER_DB}"
    return 0
  fi

  local db_bak="${UGOS_DOCKER_DB}.dockersich-restore-backup-$(date +'%Y-%m-%d_%H-%M-%S')"
  cp -a "$UGOS_DOCKER_DB" "$db_bak"
  log_i "[UGOS-DB] Sicherheitskopie erstellt: ${db_bak}" "[UGOS DB] Safety copy created: ${db_bak}"
  UGOS_DB_STATUS="$(tr_text 'erfolgreich, Sicherheitskopie' 'successful, backup copy'): ${db_bak}"

  PATH_REMAP_FILE_REAL="$(effective_remap_file)"
  export RESTORE_ALL_PROJECTS RESTORE_PROJECTS EXCLUDE_PROJECTS SOURCE_DIR ENABLE_PATH_REMAP PATH_REMAP_FROM PATH_REMAP_TO UGOS_DB_CONTENT_MODE PATH_REMAP_FILE_REAL
  "$PYTHON_BIN" - "$UGOS_DOCKER_DB" "$json_file" "$(manifest_value SOURCE_DIR)" "${backup_root}/metadata/project_archives.tsv" <<'PY'
import datetime
import json
import os
import re
import sqlite3
import sys

db, json_file, original_source, project_archives_file = sys.argv[1:5]
target_source = os.environ.get("SOURCE_DIR", "")
enable_remap = os.environ.get("ENABLE_PATH_REMAP", "true").lower() in ("true", "1", "yes", "ja")
remap_from = os.environ.get("PATH_REMAP_FROM", "")
remap_to = os.environ.get("PATH_REMAP_TO", "")
remap_file = os.environ.get("PATH_REMAP_FILE_REAL", "")
remap_rules = []
if enable_remap and remap_file and os.path.exists(remap_file):
    try:
        with open(remap_file, encoding="utf-8", errors="ignore") as f:
            for raw in f:
                line = raw.strip("\r\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                if "\t" in line:
                    parts = line.split("\t", 2)
                else:
                    parts = line.split(None, 2)
                if len(parts) >= 2:
                    old, new = parts[0].rstrip("/"), parts[1].rstrip("/")
                    if old and new and old != new:
                        remap_rules.append((old, new))
    except Exception:
        pass

content_mode = os.environ.get("UGOS_DB_CONTENT_MODE", "empty").lower()

def split(v):
    if not v:
        return []
    return [x for x in re.split(r"[\s,;]+", v.strip()) if x]

restore_all = os.environ.get("RESTORE_ALL_PROJECTS", "false").lower() in ("true", "1", "yes", "ja")
restore_projects = set(split(os.environ.get("RESTORE_PROJECTS", "")))
exclude_projects = set(split(os.environ.get("EXCLUDE_PROJECTS", "")))

archived_projects = {}
try:
    with open(project_archives_file, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("project\t"):
                continue
            parts = line.split("\t")
            name = parts[0] if len(parts) > 0 else ""
            archive = parts[1] if len(parts) > 1 else ""
            workdir = parts[2] if len(parts) > 2 else ""
            config_files = parts[3] if len(parts) > 3 else ""
            if name:
                archived_projects[name] = {"archive": archive, "workdir": workdir, "config_files": config_files}
except FileNotFoundError:
    pass

def selected(name):
    # Never write stale UGOS-DB project entries unless that project really exists in this backup archive.
    if archived_projects and name not in archived_projects:
        return False
    if name in exclude_projects:
        return False
    if restore_all:
        return True
    if not restore_projects:
        return True
    return name in restore_projects

def map_path(p):
    if not p:
        return p
    if enable_remap:
        for old, new in remap_rules:
            if p.startswith(old):
                return new + p[len(old):]
    if enable_remap and remap_from and remap_to and p.startswith(remap_from):
        return remap_to + p[len(remap_from):]
    if original_source and target_source and original_source != target_source and p.startswith(original_source):
        return target_source + p[len(original_source):]
    return p

data = json.load(open(json_file, encoding="utf-8"))
rows = data.get("compose") or []
now = datetime.datetime.now().astimezone().isoformat(sep=" ")

conn = sqlite3.connect(db)
cur = conn.cursor()
tables = [r[0] for r in cur.execute("select name from sqlite_master where type='table'")]
if "compose" not in tables:
    raise SystemExit("compose table not found")

handled = set()
for row in rows:
    name = row.get("name")
    if not name or not selected(name):
        continue
    path = map_path(row.get("path") or "")
    state = int(row.get("state") or 1)
    content = row.get("content") or ""
    if content_mode == "empty":
        content = ""
    app_id = row.get("app_id")
    container_num = row.get("container_num")
    exists = cur.execute("select id from compose where name=?", (name,)).fetchone()
    if exists:
        cur.execute(
            "update compose set updated_at=?, state=?, path=?, content=?, app_id=?, container_num=? where name=?",
            (now, state, path, content, app_id, container_num, name),
        )
    else:
        cur.execute(
            "insert into compose (created_at, updated_at, name, state, path, content, app_id, container_num) values (?,?,?,?,?,?,?,?)",
            (now, now, name, state, path, content, app_id, container_num),
        )
    handled.add(name)

# Standalone-generated projects do not exist in the source UGOS DB export.
# Add/update a safe Compose table entry from project_archives.tsv.
for name, meta in sorted(archived_projects.items()):
    if name in handled or not selected(name):
        continue
    workdir = meta.get("workdir") or ""
    config_files = meta.get("config_files") or ""
    first_config = ""
    for part in re.split(r",", config_files):
        part = part.strip()
        if part:
            first_config = part
            break
    path = first_config or (workdir.rstrip("/") + "/docker-compose.yaml" if workdir else "")
    path = map_path(path)
    state = 1
    content = ""
    app_id = None
    container_num = 0
    exists = cur.execute("select id from compose where name=?", (name,)).fetchone()
    if exists:
        cur.execute(
            "update compose set updated_at=?, state=?, path=?, content=?, app_id=?, container_num=? where name=?",
            (now, state, path, content, app_id, container_num, name),
        )
    else:
        cur.execute(
            "insert into compose (created_at, updated_at, name, state, path, content, app_id, container_num) values (?,?,?,?,?,?,?,?)",
            (now, now, name, state, path, content, app_id, container_num),
        )

conn.commit()
conn.close()
PY
  prune_ugos_db_backups
}

list_running_container_names(){
  $DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | sed '/^$/d' || true
}

restore_running_containers_after_refresh(){
  local before_file="$1"
  [[ -f "$before_file" ]] || return 0

  local restarted=() name running_now exists
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    exists="$($DOCKER_BIN inspect -f '{{.Name}}' "$name" 2>/dev/null || true)"
    [[ -n "$exists" ]] || continue
    running_now="$($DOCKER_BIN inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)"
    if [[ "$running_now" != "true" ]]; then
      log_i "[UGOS] Container war vor dem Docker-App-Refresh aktiv und wird erneut gestartet: ${name}" "[UGOS] Container was running before Docker app refresh and is started again: ${name}"
      if $DOCKER_BIN start "$name" >> "$log_file" 2>&1; then
        restarted+=("$name")
      fi
    fi
  done < "$before_file"

  if ((${#restarted[@]} > 0)); then
    UGOS_REFRESH_STATUS="${UGOS_REFRESH_STATUS}; $(tr_text 'wieder gestartete Container' 'restarted containers'): ${restarted[*]}"
  fi
}

refresh_ugos_app(){
  if ! is_true "$REFRESH_UGOS_DOCKER_APP"; then
    UGOS_REFRESH_STATUS="$(tr_text 'deaktiviert' 'disabled')"
    return 0
  fi

  local service_name="${UGOS_DOCKER_SERVICE}"
  local unit="${service_name}.service"
  local before_file="${extract_parent:-${TEMP_DIR}}/docker-running-before-ugos-refresh.txt"

  if is_true "$DRY_RUN"; then
    UGOS_REFRESH_STATUS="DRY-RUN, $(tr_text 'würde aktualisiert' 'would update'): ${unit}"
    log_i "[DRY-RUN] Docker-App-Refresh würde ausgeführt: ${unit}" "[DRY-RUN] Docker app refresh would be executed: ${unit}"
    return 0
  fi

  list_running_container_names > "$before_file" || true

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl cat "$unit" >/dev/null 2>&1 || systemctl status "$unit" >/dev/null 2>&1; then
      log_i "[UGOS] Starte Dienst ${unit} neu." "[UGOS] Restarting service ${unit}."
      if run_cmd systemctl restart "$unit"; then
        UGOS_REFRESH_STATUS="$(tr_text 'erfolgreich per systemctl' 'successful via systemctl'): ${unit}"
        restore_running_containers_after_refresh "$before_file"
      else
        UGOS_REFRESH_STATUS="$(tr_text 'fehlgeschlagen per systemctl' 'failed via systemctl'): ${unit}"
        log_i "[UGOS] Neustart von ${unit} fehlgeschlagen." "[UGOS] Restart of ${unit} failed."
      fi
      return 0
    fi
  fi

  if command -v service >/dev/null 2>&1; then
    if service "$service_name" status >/dev/null 2>&1; then
      log_i "[UGOS] Starte Dienst ${service_name} neu." "[UGOS] Restarting service ${service_name}."
      if run_cmd service "$service_name" restart; then
        UGOS_REFRESH_STATUS="$(tr_text 'erfolgreich per service' 'successful via service'): ${service_name}"
        restore_running_containers_after_refresh "$before_file"
      else
        UGOS_REFRESH_STATUS="$(tr_text 'fehlgeschlagen per service' 'failed via service'): ${service_name}"
        log_i "[UGOS] Neustart von ${service_name} fehlgeschlagen." "[UGOS] Restart of ${service_name} failed."
      fi
      return 0
    fi
  fi

  UGOS_REFRESH_STATUS="$(tr_text 'übersprungen, Dienst nicht gefunden' 'skipped, service not found'): ${service_name}"
  log_i "[UGOS] Dienst ${service_name} nicht gefunden, Refresh wird übersprungen." "[UGOS] Service ${service_name} not found, skipping refresh."
}

build_restore_mail_details(){
  local event="${1:-success}"
  local duration_h="${2:-}"
  local archive_size="0B"
  if [[ -n "${RESTORE_ARCHIVE:-}" && -f "$RESTORE_ARCHIVE" ]]; then
    archive_size="$(hr_size "$(wc -c < "$RESTORE_ARCHIVE" 2>/dev/null || echo 0)")"
  fi

  PATH_REMAP_FILE_REAL="$(effective_remap_file)"
  export RESTORE_ALL_PROJECTS RESTORE_PROJECTS EXCLUDE_PROJECTS
  "$PYTHON_BIN" - "$event" "${backup_root:-}" "$LANGUAGE" "$SCRIPT_VERSION" "$HOST_LABEL" "$SOURCE_DIR" "${UGOS_DOCKER_DB:-}" "$RESTORE_ARCHIVE" "$archive_size" "$duration_h" "$DRY_RUN" "$RESTORE_OVERWRITE_EXISTING" "$RESTORE_STOP_EXISTING_PROJECTS" "$RESTORE_RUN_COMPOSE_UP" "$RESTORE_NAMED_VOLUMES" "$RESTORE_IMAGES" "$RESTORE_EXTERNAL_BINDS" "$RESTORE_FIX_PERMISSIONS" "$RESTORE_FIX_OWNER" "$RESTORE_FIX_DIR_MODE" "$RESTORE_FIX_FILE_MODE" "$UPDATE_UGOS_DOCKER_DB" "$UGOS_DB_STATUS" "$UGOS_REFRESH_STATUS" "$log_file" "$ENABLE_PATH_REMAP" "$PATH_REMAP_FROM" "$PATH_REMAP_TO" "$PATH_REMAP_FILE_REAL" "${RESTORE_FAILURE_REASON:-}" "${LAST_CMD:-}" <<'PYREPORT'
import csv
import os
import re
import sys
from pathlib import Path

(event, backup_root, language, version, host, source_dir, ugos_db, archive_path, archive_size,
 duration_h, dry_run, overwrite_existing, stop_existing, compose_up, restore_volumes,
 restore_images, restore_external_binds, restore_fix_permissions, restore_fix_owner, restore_fix_dir_mode,
 restore_fix_file_mode, update_db, ugos_db_status, ugos_refresh_status, log_file, enable_remap,
 remap_from, remap_to, remap_file, failure_reason, last_cmd) = sys.argv[1:32]

lang_en = (language or "de").lower().startswith("en")
base = Path(backup_root) if backup_root else Path("")
meta = base / "metadata"

def t(de, en):
    return en if lang_en else de

def read_tsv(path):
    p = Path(path)
    if not p.exists():
        return []
    with p.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))

def manifest_value(key):
    p = meta / "manifest.env"
    if not p.exists():
        return ""
    prefix = key + "="
    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith(prefix):
            return line[len(prefix):]
    return ""

def split(v):
    return [x for x in re.split(r"[\s,;]+", (v or "").strip()) if x]

def count_csv(value):
    return len([x for x in str(value or "").split(",") if x.strip()])

def add_limited(lines, title, items, limit=10):
    lines.append(title)
    if not items:
        lines.append("- " + t("keine", "none"))
        return
    for item in items[:limit]:
        lines.append("- " + item)
    if len(items) > limit:
        lines.append("- " + t(f"... und {len(items)-limit} weitere", f"... and {len(items)-limit} more"))

restore_all = os.environ.get("RESTORE_ALL_PROJECTS", "false").lower() in ("true", "1", "yes", "ja")
restore_projects = set(split(os.environ.get("RESTORE_PROJECTS", "")))
exclude_projects = set(split(os.environ.get("EXCLUDE_PROJECTS", "")))

def selected(name):
    if not name or name in exclude_projects:
        return False
    if restore_all or not restore_projects:
        return True
    return name in restore_projects

projects = [r for r in read_tsv(meta / "project_archives.tsv") if selected(r.get("project", ""))]
selected_meta = {r.get("project", ""): r for r in read_tsv(meta / "selected_projects.tsv")}
running = [r for r in read_tsv(meta / "selected_running_containers.tsv") if selected(r.get("project", ""))]
external = [r for r in read_tsv(meta / "external_bind_mounts.tsv") if selected(r.get("project", ""))]
external_archives = [r for r in read_tsv(meta / "external_bind_archives.tsv") if selected(r.get("project", ""))]
restore_report = read_tsv(base.parent / "restored_external_binds.tsv") if backup_root else []
restored_external = [r for r in restore_report if r.get("status") == "restored"]
skipped_external = [r for r in restore_report if r.get("status") == "skipped-existing"]

remap_rules = []
if str(enable_remap or "").lower() in ("true", "1", "yes", "ja"):
    if remap_file and Path(remap_file).exists():
        for raw in Path(remap_file).read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "\t" in raw:
                old, new = raw.split("\t", 1)
            else:
                parts = line.split(None, 1)
                if len(parts) != 2:
                    continue
                old, new = parts
            old, new = old.strip(), new.strip()
            if old and new:
                remap_rules.append((old, new))
    if remap_from and remap_to:
        remap_rules.append((remap_from, remap_to))


source_host = manifest_value("HOST_LABEL") or manifest_value("HOSTNAME") or "-"
source_dir_original = manifest_value("SOURCE_DIR") or "-"

project_lines = []
for r in projects:
    name = r.get("project", "")
    meta_row = selected_meta.get(name, {})
    containers = count_csv(meta_row.get("containers", ""))
    images = meta_row.get("images", "") or "-"
    project_lines.append(f"{name}: {containers} {t('Container', 'container(s)')}, Images: {images}")

lines = []

if event == "fail":
    lines.append(t("Restore fehlgeschlagen", "Restore failed"))
    lines.append("")
    lines.append(t("Fehler:", "Error:"))
    if failure_reason:
        lines.append(f"- {failure_reason}")
    elif last_cmd:
        lines.append(f"- {t('Letzter Befehl', 'Last command')}: {last_cmd}")
    else:
        lines.append(f"- {t('siehe Log-Anhang', 'see log attachment')}")
    lines.append("")
else:
    lines.append(t("Restore erfolgreich abgeschlossen", "Restore completed successfully"))
    lines.append("")

lines.append(t("Status:", "Status:"))
lines.append(f"- {t('Ziel-Host', 'Target host')}: {host}")
lines.append(f"- {t('Quelle', 'Source')}: {t('Backup von', 'Backup from')} {source_host}")
lines.append(f"- {t('Archivgröße', 'Archive size')}: {archive_size}")
if duration_h:
    lines.append(f"- {t('Laufzeit', 'Duration')}: {duration_h}")
lines.append(f"- {t('Wiederhergestellte Projekte', 'Restored projects')}: {len(projects)}")
lines.append(f"- {t('UGOS-Docker-App-Abgleich', 'UGOS Docker app sync')}: {ugos_db_status}")
lines.append(f"- {t('Docker-App-Refresh', 'Docker app refresh')}: {ugos_refresh_status}")
lines.append(f"- DRY_RUN: {dry_run}")
lines.append("")

add_limited(lines, t("Wiederhergestellte Projekte:", "Restored projects:"), project_lines)
lines.append("")

lines.append(t("Hinweise:", "Notes:"))
lines.append(f"- {t('Quell-Docker-Projektordner', 'Source Docker project folder')}: {source_dir_original}")
lines.append(f"- {t('Ziel-Docker-Projektordner', 'Target Docker project folder')}: {source_dir}")
if str(restore_external_binds or "").lower() in ("true", "1", "yes", "ja"):
    lines.append(f"- {t('Externe Bind-Mounts wiederherstellen', 'Restore external bind mounts')}: {restore_external_binds} ({len(restored_external)} {t('wiederhergestellt', 'restored')}, {len(skipped_external)} {t('übersprungen', 'skipped')}, {len(external_archives)} {t('Archiv(e) im Backup', 'archive(s) in backup')})")
    lines.append(f"- {t('Rechtekorrektur externe Bind-Mounts', 'Permission fix for external bind mounts')}: {restore_fix_permissions} ({t('Owner', 'owner')}: {restore_fix_owner or t('unverändert', 'unchanged')}, {t('Ordner', 'directories')}: {restore_fix_dir_mode or t('unverändert', 'unchanged')}, {t('Dateien', 'files')}: {restore_fix_file_mode or t('unverändert', 'unchanged')})")
else:
    lines.append(f"- {len(external)} {t('externe Bind-Mounts erkannt und nicht wiederhergestellt', 'external bind mounts detected and not restored')}")
if event == "fail" and external:
    lines.append(f"- {t('Bei fehlenden Zielpfaden bitte Ordner auf dem Ziel-NAS anlegen oder path-remap.tsv oder PATH_REMAP_FROM/PATH_REMAP_TO setzen.', 'If target paths are missing, create them on the target NAS or use path-remap.tsv or PATH_REMAP_FROM/PATH_REMAP_TO.')}")
lines.append(f"- {t('Images wiederherstellen', 'Restore images')}: {restore_images}")
lines.append(f"- {t('Named Volumes wiederherstellen', 'Restore named volumes')}: {restore_volumes}")
if remap_rules:
    lines.append(f"- {t('Pfad-Remap', 'Path remap')}: {len(remap_rules)} {t('Regel(n) aktiv', 'rule(s) active')}")
    for old, new in remap_rules[:5]:
        lines.append(f"  - {old} -> {new}")
    if len(remap_rules) > 5:
        lines.append(f"  - {t('... und weitere Regeln', '... and more rules')}")
else:
    lines.append(f"- {t('Pfad-Remap', 'Path remap')}: {t('nicht aktiv', 'not active')}")
lines.append(f"- {t('Details siehe Log-Anhang', 'Details: see log attachment')}")
lines.append("")

lines.append(t("Archiv:", "Archive:"))
lines.append(f"- {archive_path}")
lines.append("")

lines.append(t("Logdatei:", "Log file:"))
lines.append(f"- {log_file}")

print("\n".join(lines))
PYREPORT
}

cleanup_restore_temp(){
  is_true "$CLEANUP_TEMP_AFTER_RESTORE" || return 0
  [[ -n "$extract_parent" && -d "$extract_parent" ]] || return 0
  log_i "[Cleanup] Temporäres Restore-Verzeichnis wird gelöscht: ${extract_parent}" "[Cleanup] Removing temporary restore directory: ${extract_parent}"
  rm -rf "$extract_parent" || true
}

on_error(){
  local exitcode=$?
  trap - ERR
  log_i "[Fehler] Restore wurde abgebrochen. Exit-Code: ${exitcode}" "[Error] Restore aborted. Exit code: ${exitcode}"
  local attach
  attach="$(mail_tail_file)"
  local fail_duration=""
  if [[ "${script_start_epoch:-0}" -gt 0 ]]; then
    local now_epoch duration
    now_epoch="$(date +%s)"
    duration=$((now_epoch - script_start_epoch))
    fail_duration=$(printf "%02d:%02d:%02d" $((duration/3600)) $(((duration%3600)/60)) $((duration%60)))
  fi
  send_mail "fail" "$(tr_text 'Restore fehlgeschlagen' 'Restore failed')" "$(tr_text 'Fehler' 'Error')" "$(build_restore_mail_details fail "$fail_duration")" "$attach" || true
  exit "$exitcode"
}
trap on_error ERR

main(){
  mkdir_safe "$TEMP_DIR"
  mkdir_safe "$LOG_DIR"
  run_background_if_requested
  log_file="$(rotate_logs)"
  script_start_epoch="$(date +%s)"

  log_i "UGREEN Docker Restore v${SCRIPT_VERSION} wird gestartet." "UGREEN Docker Restore v${SCRIPT_VERSION} is starting."

  resolve_auto_paths
  preflight
  extract_archive

  log_i "Host: ${HOST_LABEL}" "Host: ${HOST_LABEL}"
  log_i "Ziel-Docker-Projektordner: ${SOURCE_DIR}" "Target Docker project folder: ${SOURCE_DIR}"
  log_i "UGOS-Docker-DB: ${UGOS_DOCKER_DB:-nicht gefunden}" "UGOS Docker DB: ${UGOS_DOCKER_DB:-not found}"
  log_i "DRY_RUN: ${DRY_RUN}" "DRY_RUN: ${DRY_RUN}"

  validate_restore_selection
  confirm_restore

  restore_images
  restore_named_volumes
  restore_external_binds
  restore_project_dirs
  restore_docker_networks
  update_ugos_db
  refresh_ugos_app
  compose_up_projects

  local attach end_epoch duration duration_hm
  end_epoch="$(date +%s)"
  duration=$((end_epoch - script_start_epoch))
  duration_hm=$(printf "%02d:%02d:%02d" $((duration/3600)) $(((duration%3600)/60)) $((duration%60)))
  attach="$(mail_tail_file)"
  send_mail "success" "$(tr_text 'Restore erfolgreich' 'Restore successful')" "$(tr_text 'Erfolgreich' 'Successful')" "$(build_restore_mail_details success "$duration_hm")" "$attach" || true

  log_i "Restore abgeschlossen." "Restore completed."
  cleanup_restore_temp
}

main "$@"
