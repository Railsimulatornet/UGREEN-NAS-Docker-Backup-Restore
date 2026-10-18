#!/usr/bin/env bash
# UGREEN Docker Backup - v1.10.1
# Copyright (c) 2026 Roman Glos
set -Eeuo pipefail

SCRIPT_VERSION="1.10.1"
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
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

SOURCE_DIR="${SOURCE_DIR:-auto}"
DOCKER_ROOT_DIR="${DOCKER_ROOT_DIR:-auto}"
UGOS_DOCKER_DB="${UGOS_DOCKER_DB:-auto}"

STOP_CONTAINERS="${STOP_CONTAINERS:-true}"
START_PREVIOUSLY_RUNNING_CONTAINERS="${START_PREVIOUSLY_RUNNING_CONTAINERS:-true}"
PRE_STOP_SLEEP="${PRE_STOP_SLEEP:-0}"
STOP_TIMEOUT="${STOP_TIMEOUT:-20}"
KILL_GRACE="${KILL_GRACE:-3}"

BACKUP_ALL_PROJECTS="${BACKUP_ALL_PROJECTS:-true}"
INCLUDE_PROJECTS="${INCLUDE_PROJECTS:-}"
EXCLUDE_PROJECTS="${EXCLUDE_PROJECTS:-}"
EXCLUDE_CONTAINERS="${EXCLUDE_CONTAINERS:-}"
BACKUP_STANDALONE_CONTAINERS="${BACKUP_STANDALONE_CONTAINERS:-true}"
BACKUP_PROJECTS_OUTSIDE_SOURCE_DIR="${BACKUP_PROJECTS_OUTSIDE_SOURCE_DIR:-false}"
BACKUP_EXCLUDE_PATHS_FILE="${BACKUP_EXCLUDE_PATHS_FILE:-backup-exclude-paths.txt}"
BACKUP_EXCLUDE_PATHS="${BACKUP_EXCLUDE_PATHS:-}"

BACKUP_DOCKER_APP_DB="${BACKUP_DOCKER_APP_DB:-true}"
BACKUP_DOCKER_METADATA="${BACKUP_DOCKER_METADATA:-true}"
BACKUP_IMAGES="${BACKUP_IMAGES:-false}"
BACKUP_NAMED_VOLUMES="${BACKUP_NAMED_VOLUMES:-false}"
BACKUP_EXTERNAL_BINDS="${BACKUP_EXTERNAL_BINDS:-false}"
# true = also back up bind mounts below SOURCE_DIR that are outside the project folder.
# This catches project-related side folders such as /volume2/docker/livisi-legacy-proxy
# without archiving large data shares like /volume1/Emby.
BACKUP_DOCKER_DIR_EXTERNAL_BINDS="${BACKUP_DOCKER_DIR_EXTERNAL_BINDS:-true}"

ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-ugreen-docker-backup}"
COMPRESS_BACKUP="${COMPRESS_BACKUP:-true}"

ENABLE_REMOTE_BACKUP="${ENABLE_REMOTE_BACKUP:-false}"
REMOTE_METHOD="${REMOTE_METHOD:-scp}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_PATH="${REMOTE_PATH:-}"
REMOTE_KEEP_BACKUPS="${REMOTE_KEEP_BACKUPS:-5}"

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
MAIL_SUBJECT_PREFIX="${MAIL_SUBJECT_PREFIX:-[UGREEN Docker Backup] }"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"

SHUTDOWN_AFTER_SUCCESS="${SHUTDOWN_AFTER_SUCCESS:-false}"
SHUTDOWN_COMMAND="${SHUTDOWN_COMMAND:-poweroff}"

DOCKER_BIN="${DOCKER_BIN:-docker}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log_file=""
backup_fullpath=""
stage_dir=""
stage_parent=""
selected_running_names=()
selected_running_ids=()
TAR_EXCLUDE_ARGS=()
backup_success="false"
script_start_epoch=0
REMOTE_BACKUP_STATUS="deaktiviert"
REMOTE_BACKUP_TARGET=""
REMOTE_BACKUP_ERROR=""
FAILURE_REASON=""

lower(){ printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
is_true(){ case "$(lower "${1:-}")" in true|1|yes|y|ja) return 0;; *) return 1;; esac; }
is_false(){ ! is_true "${1:-}"; }

tr_text(){
  local de="$1"; local en="$2"
  if [[ "$(lower "$LANGUAGE")" == en* ]]; then printf '%s' "$en"; else printf '%s' "$de"; fi
}

hr_size(){
  local b="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B --format="%.1f" "$b"
  else
    printf '%sB' "$b"
  fi
}

mkdir_safe(){ mkdir -p "$1"; }

rotate_logs(){
  mkdir_safe "$LOG_DIR"
  local lf="${LOG_DIR}/ugreen-docker-backup.log"
  if [[ -f "$lf" ]]; then
    for ((i=9;i>=1;i--)); do
      [[ -f "${lf}.${i}" ]] && mv -f "${lf}.${i}" "${lf}.$((i+1))" || true
    done
    mv -f "$lf" "${lf}.1" || true
  fi
  touch "$lf"
  printf '%s' "$lf"
}

log(){
  local msg="$*"
  printf '[%s] %s\n' "$(date +'%F %T')" "$msg" | tee -a "$log_file"
}

log_i(){
  local de="$1"; local en="$2"
  log "$(tr_text "$de" "$en")"
}

die(){
  local msg="$*"
  if [[ -z "${FAILURE_REASON:-}" ]]; then
    FAILURE_REASON="$msg"
  fi
  log "ERROR: $msg"
  false
}

split_words(){
  # Prints one entry per line. Whitespace, comma and semicolon are accepted separators.
  printf '%s' "${1:-}" | tr ',;' '  ' | tr -s ' ' '\n' | sed '/^$/d'
}

path_in_dir(){
  local path="$1"; local dir="$2"
  [[ -z "$path" || -z "$dir" ]] && return 1
  case "${path%/}/" in
    "${dir%/}/"*) return 0;;
    *) return 1;;
  esac
}

trim_ws(){
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

resolve_backup_exclude_file(){
  local f="${BACKUP_EXCLUDE_PATHS_FILE:-}"
  [[ -z "$f" ]] && return 0
  if [[ "$f" == /* ]]; then
    printf '%s\n' "$f"
    return 0
  fi
  local env_dir
  env_dir="$(cd "$(dirname "${ENV_FILE}")" 2>/dev/null && pwd || printf '%s' "$SCRIPT_DIR")"
  if [[ -f "${env_dir}/${f}" ]]; then
    printf '%s\n' "${env_dir}/${f}"
  else
    printf '%s\n' "${SCRIPT_DIR}/${f}"
  fi
}

print_configured_backup_exclude_paths(){
  local line file
  declare -A seen=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim_ws "$line")"
    [[ -z "$line" ]] && continue
    if [[ -z "${seen[$line]:-}" ]]; then
      seen[$line]=1
      printf '%s\n' "$line"
    fi
  done < <(printf '%s\n' "${BACKUP_EXCLUDE_PATHS:-}" | tr ',;' '\n')

  file="$(resolve_backup_exclude_file)"
  if [[ -n "$file" && -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="$(trim_ws "$line")"
      [[ -z "$line" ]] && continue
      if [[ -z "${seen[$line]:-}" ]]; then
        seen[$line]=1
        printf '%s\n' "$line"
      fi
    done < "$file"
  fi
}

build_tar_exclude_args(){
  local parent="$1"
  local base="$2"
  local root raw p rel
  TAR_EXCLUDE_ARGS=()
  root="${parent%/}/${base}"

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ -z "$raw" ]] && continue
    p="${raw%/}"
    rel=""

    if [[ "$p" == /* ]]; then
      if [[ "$p" == "$root" ]]; then
        rel="$base"
      elif [[ "$p" == "$root/"* ]]; then
        rel="${base}/${p#"$root/"}"
      else
        continue
      fi
    else
      rel="${p#./}"
      if [[ "$rel" != "$base" && "$rel" != "$base/"* ]]; then
        rel="${base}/${rel}"
      fi
    fi

    [[ -z "$rel" ]] && continue
    TAR_EXCLUDE_ARGS+=(--exclude="$rel" --exclude="$rel/*" --exclude="$rel/**")
  done < <(print_configured_backup_exclude_paths)
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
    if [[ -n "$base_volume" && -d "${base_volume}/docker" ]]; then
      SOURCE_DIR="${base_volume}/docker"
    else
      local found
      found="$(find /volume* -maxdepth 1 -type d -name docker 2>/dev/null | head -n 1 || true)"
      [[ -n "$found" ]] || die "$(tr_text 'Docker-Projektordner konnte nicht automatisch ermittelt werden. Bitte SOURCE_DIR in der .env setzen.' 'Could not auto-detect Docker project folder. Please set SOURCE_DIR in the .env.')"
      SOURCE_DIR="$found"
    fi
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
  [[ -d "$SOURCE_DIR" ]] || die "$(tr_text "SOURCE_DIR existiert nicht: $SOURCE_DIR" "SOURCE_DIR does not exist: $SOURCE_DIR")"
  mkdir_safe "$BACKUP_DIR"
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

mail_subject(){
  local event="$1"
  case "$event" in
    start) tr_text "Backup gestartet" "Backup started";;
    success) tr_text "Backup erfolgreich" "Backup successful";;
    fail) tr_text "Backup fehlgeschlagen" "Backup failed";;
    *) printf '%s' "$event";;
  esac
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

plain_body = f"{title}\n{host_label}\n\n{status}\n\n{details}\n\nUGREEN Docker Backup v{script_version}\nCopyright Roman Glos 2026\n"
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
UGREEN Docker Backup v{safe_version}<br>Copyright Roman Glos 2026
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

mail_tail_file(){
  local f="${LOG_DIR}/ugreen-docker-backup-last-${LOG_TAIL_LINES}.log"
  tail -n "$LOG_TAIL_LINES" "$log_file" > "$f" 2>/dev/null || true
  printf '%s' "$f"
}

export_ugos_compose_table(){
  local db="$1"
  local out_json="$2"
  local out_schema="$3"
  [[ -n "$db" && -f "$db" ]] || return 0
  "$PYTHON_BIN" - "$db" "$out_json" "$out_schema" <<'PY'
import json
import sqlite3
import sys

db, out_json, out_schema = sys.argv[1:4]
conn = sqlite3.connect(db)
conn.row_factory = sqlite3.Row
cur = conn.cursor()
tables = [r[0] for r in cur.execute("select name from sqlite_master where type='table'")]
result = {"available_tables": tables, "compose": []}
if "compose" in tables:
    result["compose"] = [dict(r) for r in cur.execute("select * from compose order by name")]
    schema = cur.execute("select sql from sqlite_master where type='table' and name='compose'").fetchone()
    with open(out_schema, "w", encoding="utf-8") as f:
        f.write((schema[0] if schema else "") + "\n")
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2, default=str)
PY
}

collect_metadata(){
  log_i "[Metadaten] Docker- und UGOS-Informationen werden erfasst." "[Metadata] Collecting Docker and UGOS information."
  mkdir_safe "${stage_dir}/metadata"
  mkdir_safe "${stage_dir}/projects"
  mkdir_safe "${stage_dir}/images"
  mkdir_safe "${stage_dir}/volumes"
  mkdir_safe "${stage_dir}/external-binds"

  {
    echo "SCRIPT_VERSION=${SCRIPT_VERSION}"
    echo "HOST_LABEL=${HOST_LABEL}"
    echo "HOSTNAME=$(hostname 2>/dev/null || true)"
    echo "DATE=$(date -Is)"
    echo "SOURCE_DIR=${SOURCE_DIR}"
    echo "DOCKER_ROOT_DIR=${DOCKER_ROOT_DIR}"
    echo "UGOS_DOCKER_DB=${UGOS_DOCKER_DB}"
    echo "BACKUP_ALL_PROJECTS=${BACKUP_ALL_PROJECTS}"
    echo "INCLUDE_PROJECTS=${INCLUDE_PROJECTS}"
    echo "EXCLUDE_PROJECTS=${EXCLUDE_PROJECTS}"
    echo "EXCLUDE_CONTAINERS=${EXCLUDE_CONTAINERS}"
    echo "BACKUP_EXCLUDE_PATHS_FILE=${BACKUP_EXCLUDE_PATHS_FILE}"
    echo "BACKUP_EXCLUDE_PATHS=${BACKUP_EXCLUDE_PATHS}"
    echo "BACKUP_EXTERNAL_BINDS=${BACKUP_EXTERNAL_BINDS}"
    echo "BACKUP_DOCKER_DIR_EXTERNAL_BINDS=${BACKUP_DOCKER_DIR_EXTERNAL_BINDS}"
  } > "${stage_dir}/metadata/manifest.env"
  print_configured_backup_exclude_paths > "${stage_dir}/metadata/backup_exclude_paths.txt"

  $DOCKER_BIN info > "${stage_dir}/metadata/docker_info.txt" 2>&1 || true
  $DOCKER_BIN version > "${stage_dir}/metadata/docker_version.txt" 2>&1 || true
  $DOCKER_BIN compose version > "${stage_dir}/metadata/docker_compose_version.txt" 2>&1 || true
  $DOCKER_BIN compose ls --all > "${stage_dir}/metadata/docker_compose_ls.txt" 2>&1 || true
  $DOCKER_BIN compose ls --all --format json > "${stage_dir}/metadata/docker_compose_ls.json" 2>&1 || true
  $DOCKER_BIN ps -a --no-trunc --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Labels}}' > "${stage_dir}/metadata/docker_ps_all.txt" 2>&1 || true

  mapfile -t all_container_ids < <($DOCKER_BIN ps -aq 2>/dev/null || true)
  if ((${#all_container_ids[@]} > 0)); then
    $DOCKER_BIN inspect "${all_container_ids[@]}" > "${stage_dir}/metadata/docker_containers_inspect.json" 2>&1 || true
  else
    echo "[]" > "${stage_dir}/metadata/docker_containers_inspect.json"
  fi

  mapfile -t all_network_ids < <($DOCKER_BIN network ls -q 2>/dev/null || true)
  if ((${#all_network_ids[@]} > 0)); then
    $DOCKER_BIN network inspect "${all_network_ids[@]}" > "${stage_dir}/metadata/docker_networks_inspect.json" 2>&1 || true
  else
    echo "[]" > "${stage_dir}/metadata/docker_networks_inspect.json"
  fi
  $DOCKER_BIN network ls > "${stage_dir}/metadata/docker_network_ls.txt" 2>&1 || true

  mapfile -t all_volume_names < <($DOCKER_BIN volume ls -q 2>/dev/null || true)
  if ((${#all_volume_names[@]} > 0)); then
    $DOCKER_BIN volume inspect "${all_volume_names[@]}" > "${stage_dir}/metadata/docker_volumes_inspect.json" 2>&1 || true
  else
    echo "[]" > "${stage_dir}/metadata/docker_volumes_inspect.json"
  fi
  $DOCKER_BIN volume ls > "${stage_dir}/metadata/docker_volume_ls.txt" 2>&1 || true

  if is_true "$BACKUP_DOCKER_APP_DB" && [[ -n "$UGOS_DOCKER_DB" && -f "$UGOS_DOCKER_DB" ]]; then
    mkdir_safe "${stage_dir}/metadata/ugos_db"
    cp -a "$UGOS_DOCKER_DB" "${stage_dir}/metadata/ugos_db/docker_info_log.db" || true
    export_ugos_compose_table "$UGOS_DOCKER_DB" "${stage_dir}/metadata/ugos_compose_table.json" "${stage_dir}/metadata/ugos_compose_schema.sql" || true
  else
    echo '{"available_tables":[],"compose":[]}' > "${stage_dir}/metadata/ugos_compose_table.json"
  fi
}

create_inventory(){
  log_i "[Inventar] Projekte und Container werden ausgewertet." "[Inventory] Evaluating projects and containers."

  export SOURCE_DIR BACKUP_ALL_PROJECTS INCLUDE_PROJECTS EXCLUDE_PROJECTS EXCLUDE_CONTAINERS BACKUP_STANDALONE_CONTAINERS
  "$PYTHON_BIN" - "${stage_dir}/metadata/docker_containers_inspect.json" "${stage_dir}/metadata" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

inspect_file = Path(sys.argv[1])
out_dir = Path(sys.argv[2])

source_dir = os.environ.get("SOURCE_DIR", "").rstrip("/")
backup_all = os.environ.get("BACKUP_ALL_PROJECTS", "true").lower() in ("true", "1", "yes", "ja")
standalone = os.environ.get("BACKUP_STANDALONE_CONTAINERS", "false").lower() in ("true", "1", "yes", "ja")

def split(v):
    if not v:
        return []
    return [x for x in re.split(r"[\s,;]+", v.strip()) if x]

include_projects = set(split(os.environ.get("INCLUDE_PROJECTS", "")))
exclude_projects = set(split(os.environ.get("EXCLUDE_PROJECTS", "")))
exclude_containers = set(split(os.environ.get("EXCLUDE_CONTAINERS", "")))

try:
    data = json.loads(inspect_file.read_text(encoding="utf-8"))
except Exception:
    data = []

containers = []
projects = {}

for c in data:
    labels = c.get("Config", {}).get("Labels") or {}
    name = (c.get("Name") or "").lstrip("/")
    cid = c.get("Id") or ""
    short_id = cid[:12]
    state = c.get("State") or {}
    running = bool(state.get("Running"))
    image = (c.get("Config") or {}).get("Image") or c.get("Image") or ""
    project = labels.get("com.docker.compose.project") or ""
    service = labels.get("com.docker.compose.service") or ""
    working_dir = labels.get("com.docker.compose.project.working_dir") or ""
    config_files = labels.get("com.docker.compose.project.config_files") or ""
    is_compose = bool(project)

    if not is_compose:
        if standalone:
            project = f"standalone_{name}"
        else:
            selected = False
            containers.append({
                "id": cid, "short_id": short_id, "name": name, "project": "",
                "service": service, "image": image, "running": running,
                "working_dir": working_dir, "config_files": config_files,
                "selected": selected, "stop": False, "is_compose": False
            })
            continue

    # Project selection and stop selection are intentionally separate:
    # EXCLUDE_CONTAINERS must only exclude a container from being stopped,
    # not remove its Compose project from the backup archive.
    selected = True
    if not backup_all:
        selected = project in include_projects
    if project in exclude_projects:
        selected = False

    stop = selected and running and (name not in exclude_containers)

    item = {
        "id": cid, "short_id": short_id, "name": name, "project": project,
        "service": service, "image": image, "running": running,
        "working_dir": working_dir, "config_files": config_files,
        "selected": selected, "stop": stop, "is_compose": is_compose
    }
    containers.append(item)

    if selected:
        p = projects.setdefault(project, {
            "project": project,
            "working_dir": working_dir,
            "config_files": config_files,
            "containers": [],
            "images": set(),
        })
        if not p["working_dir"] and working_dir:
            p["working_dir"] = working_dir
        if not p["config_files"] and config_files:
            p["config_files"] = config_files
        p["containers"].append(name)
        if image:
            p["images"].add(image)

def write_tsv(path, rows, header):
    with open(out_dir / path, "w", encoding="utf-8") as f:
        f.write("\t".join(header) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(h, "")) for h in header) + "\n")

write_tsv("containers_inventory.tsv", containers, ["id","short_id","name","project","service","image","running","working_dir","config_files","selected","stop","is_compose"])

project_rows = []
for p in sorted(projects.values(), key=lambda x: x["project"]):
    project_name = p["project"]
    is_standalone_project = project_name.startswith("standalone_")
    working_dir = p["working_dir"]
    config_files = p["config_files"]
    # Important: do not leave empty TSV fields for standalone projects.
    # Bash read with tab IFS can otherwise collapse empty fields and shift columns.
    if is_standalone_project and not working_dir and source_dir:
        working_dir = source_dir.rstrip("/") + "/" + project_name
    if is_standalone_project and not config_files and working_dir:
        config_files = working_dir.rstrip("/") + "/docker-compose.yaml"
    project_rows.append({
        "project": project_name,
        "working_dir": working_dir,
        "config_files": config_files,
        "containers": ",".join(sorted(p["containers"])),
        "images": ",".join(sorted(p["images"])),
        "is_standalone": str(is_standalone_project).lower(),
    })
write_tsv("selected_projects.tsv", project_rows, ["project","working_dir","config_files","containers","images","is_standalone"])

running_rows = [c for c in containers if c.get("stop")]
write_tsv("selected_running_containers.tsv", running_rows, ["id","short_id","name","project","service","image","running"])

image_set = sorted({img for p in projects.values() for img in p["images"] if img})
with open(out_dir / "selected_images.txt", "w", encoding="utf-8") as f:
    for img in image_set:
        f.write(img + "\n")

# External bind mounts and named volumes used by selected containers.
selected_names = {c["name"] for c in containers if c.get("selected")}
external_binds = []
bind_mounts = []
named_volumes = []
for c in data:
    name = (c.get("Name") or "").lstrip("/")
    if name not in selected_names:
        continue
    labels = c.get("Config", {}).get("Labels") or {}
    project = labels.get("com.docker.compose.project") or ""
    workdir = labels.get("com.docker.compose.project.working_dir") or ""
    for m in c.get("Mounts") or []:
        mtype = m.get("Type") or ""
        src = m.get("Source") or ""
        dst = m.get("Destination") or ""
        rw = m.get("RW")
        if mtype == "bind":
            src_norm = src.rstrip("/")
            workdir_norm = workdir.rstrip("/")
            source_norm = source_dir.rstrip("/")
            inside_project = bool(workdir_norm and (src_norm == workdir_norm or src_norm.startswith(workdir_norm + "/")))
            inside_source = bool(source_norm and (src_norm == source_norm or src_norm.startswith(source_norm + "/")))
            if not inside_project:
                external_binds.append({
                    "container": name, "project": project, "source": src, "destination": dst, "rw": rw
                })
            if os.path.isdir(src):
                source_type = "dir"
            elif os.path.isfile(src):
                source_type = "file"
            elif os.path.exists(src):
                source_type = "other"
            else:
                source_type = "missing"
            bind_mounts.append({
                "project": project, "container": name, "source": src, "destination": dst, "rw": rw,
                "inside_project": str(inside_project).lower(),
                "inside_source": str(inside_source).lower(),
                "source_type": source_type,
            })
        elif mtype == "volume":
            named_volumes.append({
                "container": name, "project": project, "name": m.get("Name") or "", "source": src, "destination": dst, "rw": rw
            })

write_tsv("external_bind_mounts.tsv", external_binds, ["project","container","source","destination","rw"])
write_tsv("bind_mounts.tsv", bind_mounts, ["project","container","source","destination","rw","inside_project","inside_source","source_type"])
write_tsv("selected_named_volumes.tsv", named_volumes, ["project","container","name","source","destination","rw"])
PY
}


create_network_inventory(){
  log_i "[Netzwerke] Docker-Netzwerke der ausgewählten Projekte werden erfasst." "[Networks] Collecting Docker networks used by selected projects."

  export DOCKER_BIN SOURCE_DIR
  "$PYTHON_BIN" - "${stage_dir}/metadata/docker_containers_inspect.json" "${stage_dir}/metadata/docker_networks_inspect.json" "${stage_dir}/metadata" <<'PYNETINV'
import csv
import json
import os
import re
import subprocess
import sys
from pathlib import Path

containers_file = Path(sys.argv[1])
networks_file = Path(sys.argv[2])
out_dir = Path(sys.argv[3])
docker_bin = os.environ.get("DOCKER_BIN", "docker")

try:
    containers = json.loads(containers_file.read_text(encoding="utf-8"))
except Exception:
    containers = []
try:
    networks = json.loads(networks_file.read_text(encoding="utf-8"))
except Exception:
    networks = []

warnings = []

def read_tsv(path):
    p = out_dir / path
    if not p.exists():
        return []
    with p.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))

inventory = read_tsv("containers_inventory.tsv")
projects_rows = read_tsv("selected_projects.tsv")

selected_names = {r.get("name", "") for r in inventory if str(r.get("selected", "")).lower() in ("true", "1", "yes", "ja")}
selected_projects = {r.get("project", "") for r in projects_rows if r.get("project", "")}

used_networks = set()
network_users = {}
network_sources = {}
compose_declared = {}


def add_network(name, used_by, source=""):
    if not name or name in ("bridge", "host", "none"):
        return
    used_networks.add(name)
    if used_by:
        network_users.setdefault(name, set()).add(used_by)
    if source:
        network_sources.setdefault(name, set()).add(source)

# 1) Real container attachments. This catches external networks like 120erNetz.
for c in containers:
    name = (c.get("Name") or "").lstrip("/")
    if name not in selected_names:
        continue
    labels = (c.get("Config") or {}).get("Labels") or {}
    project = labels.get("com.docker.compose.project") or ""
    label = f"{project}/{name}" if project else name
    for net_name in ((c.get("NetworkSettings") or {}).get("Networks") or {}).keys():
        add_network(net_name, label, "container")

# 2) Existing Docker networks with Compose project labels. This also catches stopped projects.
for n in networks:
    name = n.get("Name") or ""
    labels = n.get("Labels") or {}
    project = labels.get("com.docker.compose.project") or ""
    if project and project in selected_projects:
        add_network(name, project, "network-label")

# 3) Compose config references. This catches external networks even before any container is running.
#    The result is used only if the network exists in docker network inspect, or as a minimal fallback.
def split_config_files(value):
    if not value:
        return []
    return [x.strip() for x in value.split(",") if x.strip()]


def compose_actual_network_name(project, key, net_cfg):
    if not isinstance(net_cfg, dict):
        net_cfg = {}
    explicit_name = net_cfg.get("name")
    if explicit_name:
        return str(explicit_name)
    # Docker Compose uses <project>_<network>. The default network is <project>_default.
    return f"{project}_{key}"


def collect_compose_networks(project, workdir, config_files):
    if not project or not workdir:
        return
    files = split_config_files(config_files)
    if not files:
        for candidate in ("docker-compose.yaml", "docker-compose.yml", "compose.yaml", "compose.yml"):
            p = Path(workdir) / candidate
            if p.exists():
                files = [str(p)]
                break
    if not files:
        return
    cmd = [docker_bin, "compose", "-p", project]
    for f in files:
        cmd += ["-f", f]
    cmd += ["config", "--format", "json"]
    try:
        proc = subprocess.run(cmd, cwd=workdir, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except Exception as exc:
        warnings.append(f"{project}: docker compose config konnte nicht ausgeführt werden: {exc}")
        return
    if proc.returncode != 0:
        msg = (proc.stderr or proc.stdout or "").strip().replace("\n", " | ")
        warnings.append(f"{project}: docker compose config fehlgeschlagen: {msg[:500]}")
        return
    try:
        cfg = json.loads(proc.stdout or "{}")
    except Exception as exc:
        warnings.append(f"{project}: docker compose config JSON konnte nicht gelesen werden: {exc}")
        return
    nets = cfg.get("networks") or {}
    if not isinstance(nets, dict):
        return
    for key, net_cfg in nets.items():
        if not isinstance(net_cfg, dict):
            net_cfg = {}
        actual = compose_actual_network_name(project, key, net_cfg)
        add_network(actual, project, "compose-config")
        compose_declared.setdefault(actual, {"project": project, "key": key, "config": net_cfg})

for row in projects_rows:
    collect_compose_networks(row.get("project", ""), row.get("working_dir", ""), row.get("config_files", ""))

by_name = {n.get("Name", ""): n for n in networks if n.get("Name")}
plan = []
missing_from_inspect = []
for name in sorted(used_networks):
    n = by_name.get(name)
    declared = compose_declared.get(name, {})
    if not n:
        cfg = declared.get("config") or {}
        driver = cfg.get("driver") or "bridge"
        item = {
            "name": name,
            "id": "",
            "driver": driver,
            "scope": "local",
            "internal": bool(cfg.get("internal", False)),
            "attachable": bool(cfg.get("attachable", False)),
            "ingress": False,
            "enable_ipv6": bool(cfg.get("enable_ipv6", False)),
            "options": cfg.get("driver_opts") or {},
            "ipam_driver": ((cfg.get("ipam") or {}).get("driver") or "default") if isinstance(cfg.get("ipam"), dict) else "default",
            "ipam_options": ((cfg.get("ipam") or {}).get("options") or {}) if isinstance(cfg.get("ipam"), dict) else {},
            "ipam_config": ((cfg.get("ipam") or {}).get("config") or []) if isinstance(cfg.get("ipam"), dict) else [],
            "labels": {},
            "missing_on_source": True,
            "external_reference": bool(cfg.get("external", False)),
            "sources": sorted(network_sources.get(name, [])),
        }
        missing_from_inspect.append(name)
    else:
        ipam = n.get("IPAM") or {}
        item = {
            "name": name,
            "id": n.get("Id", ""),
            "driver": n.get("Driver") or "bridge",
            "scope": n.get("Scope") or "local",
            "internal": bool(n.get("Internal")),
            "attachable": bool(n.get("Attachable")),
            "ingress": bool(n.get("Ingress")),
            "enable_ipv6": bool(n.get("EnableIPv6")),
            "options": n.get("Options") or {},
            "ipam_driver": ipam.get("Driver") or "default",
            "ipam_options": ipam.get("Options") or {},
            "ipam_config": ipam.get("Config") or [],
            "labels": n.get("Labels") or {},
            "missing_on_source": False,
            "external_reference": bool((declared.get("config") or {}).get("external", False)),
            "sources": sorted(network_sources.get(name, [])),
        }
    item["used_by"] = sorted(network_users.get(name, []))
    plan.append(item)

(out_dir / "network_create_plan.json").write_text(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")

with (out_dir / "selected_networks.tsv").open("w", encoding="utf-8", newline="") as f:
    fields = ["name", "driver", "internal", "attachable", "enable_ipv6", "subnet", "gateway", "ip_range", "parent", "external_reference", "missing_on_source", "sources", "used_by"]
    w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
    w.writeheader()
    for item in plan:
        cfg = item.get("ipam_config") or []
        first = cfg[0] if cfg and isinstance(cfg[0], dict) else {}
        opts = item.get("options") or {}
        w.writerow({
            "name": item.get("name", ""),
            "driver": item.get("driver", ""),
            "internal": str(item.get("internal", False)).lower(),
            "attachable": str(item.get("attachable", False)).lower(),
            "enable_ipv6": str(item.get("enable_ipv6", False)).lower(),
            "subnet": first.get("Subnet", "") or first.get("subnet", ""),
            "gateway": first.get("Gateway", "") or first.get("gateway", ""),
            "ip_range": first.get("IPRange", "") or first.get("ip_range", ""),
            "parent": opts.get("parent", ""),
            "external_reference": str(item.get("external_reference", False)).lower(),
            "missing_on_source": str(item.get("missing_on_source", False)).lower(),
            "sources": ",".join(item.get("sources", [])),
            "used_by": ",".join(item.get("used_by", [])),
        })

with (out_dir / "network_inventory_warnings.txt").open("w", encoding="utf-8") as f:
    if missing_from_inspect:
        f.write("Netzwerke aus Compose-Referenzen ohne docker network inspect auf dem Quell-NAS:\n")
        for name in missing_from_inspect:
            f.write(f"- {name}\n")
    for w in warnings:
        f.write(w + "\n")

print(f"network_create_plan_count={len(plan)}")
PYNETINV
}


log_selection_summary(){
  local projects_file="${stage_dir}/metadata/selected_projects.tsv"
  local containers_file="${stage_dir}/metadata/selected_running_containers.tsv"

  if [[ -s "$projects_file" ]]; then
    log_i "[Auswahl] Ausgewählte Projekte:" "[Selection] Selected projects:"
    awk -F'\t' 'NR>1 && $1!="" {print "  - " $1 " (" $2 ")"}' "$projects_file" | tee -a "$log_file"
  else
    log_i "[Auswahl] Keine Projekte ausgewählt." "[Selection] No projects selected."
  fi

  if [[ -s "$containers_file" ]]; then
    log_i "[Auswahl] Laufende Container, die kurz gestoppt werden:" "[Selection] Running containers that will be stopped briefly:"
    awk -F'\t' 'NR>1 && $3!="" {print "  - " $3 " (Projekt: " $4 ")"}' "$containers_file" | tee -a "$log_file"
  else
    log_i "[Auswahl] Keine laufenden ausgewählten Container zu stoppen." "[Selection] No running selected containers to stop."
  fi
}

stop_selected_containers(){
  selected_running_ids=()
  selected_running_names=()
  if [[ ! -f "${stage_dir}/metadata/selected_running_containers.tsv" ]]; then
    return 0
  fi
  while IFS=$'\t' read -r id short_id name project service image running; do
    [[ "$id" == "id" || -z "$id" ]] && continue
    selected_running_ids+=("$id")
    selected_running_names+=("$name")
  done < "${stage_dir}/metadata/selected_running_containers.tsv"

  if ((${#selected_running_ids[@]} == 0)); then
    log_i "[Stop] Keine laufenden ausgewählten Container gefunden." "[Stop] No running selected containers found."
    return 0
  fi

  if is_false "$STOP_CONTAINERS"; then
    log_i "[Stop] STOP_CONTAINERS=false, Container werden nicht gestoppt." "[Stop] STOP_CONTAINERS=false, containers will not be stopped."
    return 0
  fi

  log_i "[Stop] Warte ${PRE_STOP_SLEEP}s vor dem Stoppen der Container." "[Stop] Waiting ${PRE_STOP_SLEEP}s before stopping containers."
  sleep "$PRE_STOP_SLEEP"

  local id name
  for id in "${selected_running_ids[@]}"; do
    name="$($DOCKER_BIN inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##' || true)"
    log_i "[Stop] Stoppe ${name:-$id} mit Timeout ${STOP_TIMEOUT}s." "[Stop] Stopping ${name:-$id} with timeout ${STOP_TIMEOUT}s."
    $DOCKER_BIN stop --time "$STOP_TIMEOUT" "$id" >/dev/null 2>&1 || true
    local waited=0
    while $DOCKER_BIN inspect --format '{{.State.Running}}' "$id" 2>/dev/null | grep -q true; do
      sleep 1
      waited=$((waited+1))
      if (( waited >= STOP_TIMEOUT )); then
        log_i "[Stop] ${name:-$id} läuft noch, erzwinge Stop nach ${KILL_GRACE}s." "[Stop] ${name:-$id} is still running, forcing stop after ${KILL_GRACE}s."
        sleep "$KILL_GRACE"
        $DOCKER_BIN kill "$id" >/dev/null 2>&1 || true
        break
      fi
    done
  done
}

restart_selected_containers(){
  if is_false "$START_PREVIOUSLY_RUNNING_CONTAINERS"; then
    log_i "[Start] START_PREVIOUSLY_RUNNING_CONTAINERS=false, Container werden nicht automatisch gestartet." "[Start] START_PREVIOUSLY_RUNNING_CONTAINERS=false, containers will not be started automatically."
    selected_running_names=()
    selected_running_ids=()
    return 0
  fi
  if ((${#selected_running_names[@]} == 0)); then
    return 0
  fi
  local name
  for name in "${selected_running_names[@]}"; do
    [[ -z "$name" ]] && continue
    log_i "[Start] Starte ${name}." "[Start] Starting ${name}."
    $DOCKER_BIN start "$name" >/dev/null 2>&1 || true
  done
  selected_running_names=()
  selected_running_ids=()
}

generate_standalone_compose_project(){
  local project="$1"
  local container_name="$2"
  local target_dir="$3"

  mkdir_safe "$target_dir"
  "$PYTHON_BIN" - "${stage_dir}/metadata/docker_containers_inspect.json" "$container_name" "$project" "$target_dir" <<'PYSTANDALONE'
import json
import sys
from pathlib import Path

inspect_file, container_name, project, target_dir = sys.argv[1:5]
target = Path(target_dir)
target.mkdir(parents=True, exist_ok=True)

def q(s):
    return json.dumps(str(s), ensure_ascii=False)

def safe_name(name):
    out = ''.join(ch if ch.isalnum() or ch in '_.-' else '_' for ch in (name or ''))
    return out or 'standalone'

try:
    data = json.loads(Path(inspect_file).read_text(encoding='utf-8'))
except Exception:
    data = []

c = None
for item in data:
    if (item.get('Name') or '').lstrip('/') == container_name:
        c = item
        break
if c is None:
    raise SystemExit(f'container not found in inspect data: {container_name}')

cfg = c.get('Config') or {}
host = c.get('HostConfig') or {}
service = safe_name(container_name)
lines = []
lines.append('# Auto-generated by UGREEN Docker Backup for a standalone container.')
lines.append('# The original container had no Docker Compose project label.')
lines.append('services:')
lines.append(f'  {service}:')
image = cfg.get('Image') or ''
if image:
    lines.append(f'    image: {q(image)}')
lines.append(f'    container_name: {q(container_name)}')
restart = ((host.get('RestartPolicy') or {}).get('Name') or 'no')
if restart in ('', 'none'):
    restart = 'no'
lines.append(f'    restart: {q(restart)}')
entrypoint = cfg.get('Entrypoint')
if entrypoint:
    lines.append('    entrypoint:')
    vals = entrypoint if isinstance(entrypoint, list) else [entrypoint]
    for v in vals:
        lines.append(f'      - {q(v)}')
cmd = cfg.get('Cmd')
if cmd:
    lines.append('    command:')
    vals = cmd if isinstance(cmd, list) else [cmd]
    for v in vals:
        lines.append(f'      - {q(v)}')
if cfg.get('User'):
    lines.append(f'    user: {q(cfg.get("User"))}')
if cfg.get('WorkingDir'):
    lines.append(f'    working_dir: {q(cfg.get("WorkingDir"))}')
if cfg.get('OpenStdin'):
    lines.append('    stdin_open: true')
if cfg.get('Tty'):
    lines.append('    tty: true')
network = host.get('NetworkMode') or ''
if network:
    lines.append(f'    network_mode: {q(network)}')
if host.get('Privileged'):
    lines.append('    privileged: true')
env = cfg.get('Env') or []
if env:
    lines.append('    environment:')
    for e in env:
        lines.append(f'      - {q(e)}')
ports = []
for cport, bindings in (host.get('PortBindings') or {}).items():
    if bindings is None:
        ports.append(cport)
    else:
        for b in bindings:
            b = b or {}
            hp = b.get('HostPort') or ''
            hip = b.get('HostIp') or ''
            if hp and hip:
                ports.append(f'{hip}:{hp}:{cport}')
            elif hp:
                ports.append(f'{hp}:{cport}')
            else:
                ports.append(cport)
if ports:
    lines.append('    ports:')
    for p in ports:
        lines.append(f'      - {q(p)}')
volumes = []
volume_defs = {}
for m in c.get('Mounts') or []:
    mtype = m.get('Type') or ''
    src = m.get('Source') or ''
    dst = m.get('Destination') or ''
    mode = 'rw' if m.get('RW') else 'ro'
    if not dst:
        continue
    if mtype == 'bind' and src:
        volumes.append(f'{src}:{dst}:{mode}')
    elif mtype == 'volume':
        name = m.get('Name') or ''
        if name:
            key = safe_name(name)
            volume_defs[key] = name
            volumes.append(f'{key}:{dst}:{mode}')
if volumes:
    lines.append('    volumes:')
    for v in volumes:
        lines.append(f'      - {q(v)}')
for key, values in [('cap_add', host.get('CapAdd') or []), ('cap_drop', host.get('CapDrop') or []), ('security_opt', host.get('SecurityOpt') or []), ('extra_hosts', host.get('ExtraHosts') or []), ('dns', host.get('Dns') or [])]:
    if values:
        lines.append(f'    {key}:')
        for v in values:
            lines.append(f'      - {q(v)}')
devices = []
for d in host.get('Devices') or []:
    hp = d.get('PathOnHost') or ''
    cp = d.get('PathInContainer') or ''
    perm = d.get('CgroupPermissions') or ''
    if hp and cp:
        devices.append(f'{hp}:{cp}:{perm}' if perm else f'{hp}:{cp}')
if devices:
    lines.append('    devices:')
    for d in devices:
        lines.append(f'      - {q(d)}')
if volume_defs:
    lines.append('')
    lines.append('volumes:')
    for key, name in sorted(volume_defs.items()):
        lines.append(f'  {key}:')
        lines.append(f'    name: {q(name)}')
(target / 'docker-compose.yaml').write_text('\n'.join(lines) + '\n', encoding='utf-8')
(target / 'README_STANDALONE.txt').write_text(
    'UGREEN Docker Backup standalone container restore project.\n'
    f'Original container: {container_name}\nGenerated project: {project}\n', encoding='utf-8')
PYSTANDALONE
  chmod 755 "$target_dir" 2>/dev/null || true
  find "$target_dir" -type f -exec chmod 644 {} + 2>/dev/null || true
}

copy_project_dirs(){
  log_i "[Sicherung] Projektordner werden gesichert." "[Backup] Backing up project folders."
  local inventory="${stage_dir}/metadata/selected_projects.tsv"
  local archive_map="${stage_dir}/metadata/project_archives.tsv"
  echo -e "project\tarchive\tworking_dir\tconfig_files" > "$archive_map"

  if [[ ! -s "$inventory" ]]; then
    log_i "[Sicherung] Keine ausgewählten Projekte gefunden." "[Backup] No selected projects found."
    return 0
  fi

  local project workdir config_files containers images is_standalone safe parent base archive generated_parent generated_dir generated_workdir generated_config container_name
  while IFS=$'\t' read -r project workdir config_files containers images is_standalone; do
    [[ "$project" == "project" || -z "$project" ]] && continue

    if [[ "$is_standalone" == "true" || "$project" == standalone_* ]]; then
      container_name="${containers%%,*}"
      generated_parent="${stage_parent}/standalone-generated"
      generated_dir="${generated_parent}/${project}"
      generated_workdir="${SOURCE_DIR%/}/${project}"
      generated_config="${generated_workdir}/docker-compose.yaml"
      log_i "[Standalone] Erzeuge Compose-Projekt für Container ${container_name}: ${project}" "[Standalone] Generating Compose project for container ${container_name}: ${project}"
      generate_standalone_compose_project "$project" "$container_name" "$generated_dir"
      workdir="$generated_workdir"
      config_files="$generated_config"
      parent="$generated_parent"
      base="$project"
    else
      if [[ -z "$workdir" || ! -d "$workdir" ]]; then
        log_i "[Sicherung] Projekt ${project}: Arbeitsordner fehlt oder existiert nicht: ${workdir}" "[Backup] Project ${project}: working directory missing or not found: ${workdir}"
        continue
      fi

      if is_false "$BACKUP_PROJECTS_OUTSIDE_SOURCE_DIR" && ! path_in_dir "$workdir" "$SOURCE_DIR"; then
        log_i "[Sicherung] Projekt ${project}: Arbeitsordner liegt außerhalb von SOURCE_DIR und wird übersprungen: ${workdir}" "[Backup] Project ${project}: working directory is outside SOURCE_DIR and will be skipped: ${workdir}"
        continue
      fi
      parent="$(dirname "$workdir")"
      base="$(basename "$workdir")"
    fi

    safe="$(printf '%s' "$project" | sed 's/[^A-Za-z0-9_.-]/_/g')"
    archive="projects/${safe}.tar"

    build_tar_exclude_args "$parent" "$base"
    if ((${#TAR_EXCLUDE_ARGS[@]} > 0)); then
      log_i "[Sicherung] Projekt ${project}: ${workdir} (Ausschlussregeln aktiv)" "[Backup] Project ${project}: ${workdir} (exclude rules active)"
    else
      log_i "[Sicherung] Projekt ${project}: ${workdir}" "[Backup] Project ${project}: ${workdir}"
    fi
    tar --warning=no-file-ignored --numeric-owner "${TAR_EXCLUDE_ARGS[@]}" -C "$parent" -cpf "${stage_dir}/${archive}" "$base"
    echo -e "${project}\t${archive}\t${workdir}\t${config_files}" >> "$archive_map"
  done < "$inventory"
}

backup_named_volumes(){
  is_true "$BACKUP_NAMED_VOLUMES" || return 0
  log_i "[Volumes] Named Volumes werden gesichert." "[Volumes] Backing up named volumes."
  local list="${stage_dir}/metadata/selected_named_volumes.tsv"
  [[ -f "$list" ]] || return 0
  local done_file="${stage_dir}/metadata/volume_archives.tsv"
  echo -e "name\tarchive\tsource" > "$done_file"

  local project container name source dest rw safe archive parent base
  local seen=" "
  while IFS=$'\t' read -r project container name source dest rw; do
    [[ "$name" == "name" || -z "$name" || -z "$source" ]] && continue
    [[ "$seen" == *" ${name} "* ]] && continue
    seen="${seen}${name} "
    [[ -d "$source" ]] || continue
    safe="$(printf '%s' "$name" | sed 's/[^A-Za-z0-9_.-]/_/g')"
    archive="volumes/${safe}.tar"
    parent="$(dirname "$source")"
    base="$(basename "$source")"
    build_tar_exclude_args "$parent" "$base"
    log_i "[Volumes] Sichere Volume ${name}." "[Volumes] Backing up volume ${name}."
    tar --warning=no-file-ignored --numeric-owner "${TAR_EXCLUDE_ARGS[@]}" -C "$parent" -cpf "${stage_dir}/${archive}" "$base"
    echo -e "${name}\t${archive}\t${source}" >> "$done_file"
  done < "$list"
}

backup_external_binds(){
  if is_false "$BACKUP_EXTERNAL_BINDS" && is_false "$BACKUP_DOCKER_DIR_EXTERNAL_BINDS"; then
    return 0
  fi
  local list="${stage_dir}/metadata/external_bind_mounts.tsv"
  [[ -f "$list" ]] || return 0

  local done_file="${stage_dir}/metadata/external_bind_archives.tsv"
  echo -e "project\tcontainer\tsource\tdestination\trw\tarchive" > "$done_file"

  local count
  count="$(awk 'NR>1 && $3!="" {c++} END{print c+0}' "$list" 2>/dev/null || echo 0)"
  if [[ "${count:-0}" -eq 0 ]]; then
    return 0
  fi

  log_i "[Bind-Mounts] Externe Bind-Mounts werden gesichert." "[Bind mounts] Backing up external bind mounts."
  mkdir_safe "${stage_dir}/external-binds"

  local project container source destination rw safe hash archive parent base existing backup_this
  declare -A source_to_archive=()

  while IFS=$'\t' read -r project container source destination rw; do
    [[ "$project" == "project" || -z "$source" ]] && continue

    backup_this="false"
    if is_true "$BACKUP_EXTERNAL_BINDS"; then
      backup_this="true"
    elif is_true "$BACKUP_DOCKER_DIR_EXTERNAL_BINDS" && path_in_dir "$source" "$SOURCE_DIR"; then
      backup_this="true"
    fi

    if [[ "$backup_this" != "true" ]]; then
      log_i "[Bind-Mounts] Externer Pfad wird nur dokumentiert, nicht gesichert: ${source}" "[Bind mounts] External path is documented only, not backed up: ${source}"
      echo -e "${project}\t${container}\t${source}\t${destination}\t${rw}\t" >> "$done_file"
      continue
    fi

    if [[ ! -e "$source" ]]; then
      log_i "[Bind-Mounts] Quelle fehlt, wird übersprungen: ${source}" "[Bind mounts] Source missing, skipping: ${source}"
      echo -e "${project}\t${container}\t${source}\t${destination}\t${rw}\t" >> "$done_file"
      continue
    fi

    existing="${source_to_archive[$source]:-}"
    if [[ -n "$existing" ]]; then
      echo -e "${project}\t${container}\t${source}\t${destination}\t${rw}\t${existing}" >> "$done_file"
      continue
    fi

    safe="$(printf '%s_%s_%s' "$project" "$container" "$(basename "$source")" | sed 's/[^A-Za-z0-9_.-]/_/g')"
    hash="$(printf '%s' "$source" | sha256sum | awk '{print substr($1,1,12)}')"
    archive="external-binds/${safe}_${hash}.tar"
    parent="$(dirname "$source")"
    base="$(basename "$source")"

    build_tar_exclude_args "$parent" "$base"
    log_i "[Bind-Mounts] Sichere externen Pfad: ${source}" "[Bind mounts] Backing up external path: ${source}"
    tar --warning=no-file-ignored --numeric-owner "${TAR_EXCLUDE_ARGS[@]}" -C "$parent" -cpf "${stage_dir}/${archive}" "$base"
    source_to_archive[$source]="$archive"
    echo -e "${project}\t${container}\t${source}\t${destination}\t${rw}\t${archive}" >> "$done_file"
  done < "$list"
}

backup_images(){
  is_true "$BACKUP_IMAGES" || return 0
  local images_file="${stage_dir}/metadata/selected_images.txt"
  [[ -s "$images_file" ]] || return 0
  mapfile -t imgs < "$images_file"
  if ((${#imgs[@]} == 0)); then
    return 0
  fi
  log_i "[Images] Docker Images werden per docker save gesichert." "[Images] Saving Docker images with docker save."
  $DOCKER_BIN save -o "${stage_dir}/images/docker-images.tar" "${imgs[@]}"
}

create_final_archive(){
  local ts="$1"
  local tarfile="${BACKUP_DIR}/${ARCHIVE_PREFIX}_${ts}.tar"
  local tmpfile

  if is_true "$COMPRESS_BACKUP"; then
    backup_fullpath="${tarfile}.gz"
    tmpfile="${backup_fullpath}.part"
    rm -f "$tmpfile" "$backup_fullpath" 2>/dev/null || true

    if command -v pigz >/dev/null 2>&1; then
      log_i "[Archiv] Erstelle komprimiertes Archiv direkt mit pigz: ${backup_fullpath}" "[Archive] Creating compressed archive directly with pigz: ${backup_fullpath}"
      tar --warning=no-file-ignored --numeric-owner -C "$stage_parent" -cf - "$(basename "$stage_dir")" | pigz -c > "$tmpfile"
    else
      log_i "[Archiv] Erstelle komprimiertes Archiv direkt mit gzip: ${backup_fullpath}" "[Archive] Creating compressed archive directly with gzip: ${backup_fullpath}"
      tar --warning=no-file-ignored --numeric-owner -C "$stage_parent" -cf - "$(basename "$stage_dir")" | gzip -c > "$tmpfile"
    fi

    mv -f "$tmpfile" "$backup_fullpath"
  else
    backup_fullpath="$tarfile"
    tmpfile="${tarfile}.part"
    rm -f "$tmpfile" "$backup_fullpath" 2>/dev/null || true
    log_i "[Archiv] Erstelle finales TAR-Archiv ohne Komprimierung: ${backup_fullpath}" "[Archive] Creating final TAR archive without compression: ${backup_fullpath}"
    tar --warning=no-file-ignored --numeric-owner -C "$stage_parent" -cpf "$tmpfile" "$(basename "$stage_dir")"
    mv -f "$tmpfile" "$backup_fullpath"
  fi

  if [[ -f "$backup_fullpath" ]]; then
    local owner_group
    owner_group="$(stat -c '%u:%g' "$BACKUP_DIR" 2>/dev/null || true)"
    if [[ -n "$owner_group" ]]; then
      chown "$owner_group" "$backup_fullpath" 2>/dev/null || true
    fi
    chmod 664 "$backup_fullpath" 2>/dev/null || true
    log_i "[Archiv] Fertig: ${backup_fullpath}" "[Archive] Finished: ${backup_fullpath}"
  else
    die "$(tr_text 'Finales Archiv wurde nicht erstellt.' 'Final archive was not created.')"
  fi
}

prune_local_backups(){
  local keep="$KEEP_BACKUPS"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
  (( keep > 0 )) || return 0
  log_i "[Aufbewahrung] Behalte lokal die letzten ${keep} Backups." "[Retention] Keeping the last ${keep} local backups."
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "${ARCHIVE_PREFIX}_*.tar.gz" -o -name "${ARCHIVE_PREFIX}_*.tar" \) -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn \
    | awk -v keep="$keep" 'NR>keep {sub(/^[^ ]+ /,""); print}' \
    | while IFS= read -r old; do
        [[ -n "$old" ]] && rm -f -- "$old" && log_i "[Aufbewahrung] Gelöscht: ${old}" "[Retention] Deleted: ${old}"
      done
}

remote_backup(){
  REMOTE_BACKUP_STATUS="deaktiviert"
  REMOTE_BACKUP_TARGET=""
  REMOTE_BACKUP_ERROR=""
  is_true "$ENABLE_REMOTE_BACKUP" || return 0
  [[ -n "$REMOTE_HOST" && -n "$REMOTE_USER" && -n "$REMOTE_PATH" ]] || {
    REMOTE_BACKUP_STATUS="übersprungen"
    REMOTE_BACKUP_ERROR="REMOTE_HOST, REMOTE_USER oder REMOTE_PATH fehlt."
    log_i "[Remote] REMOTE_HOST, REMOTE_USER oder REMOTE_PATH fehlt. Remote-Sicherung wird übersprungen." "[Remote] REMOTE_HOST, REMOTE_USER or REMOTE_PATH missing. Skipping remote backup."
    return 0
  }

  local base remote_file remote_target_display
  base="$(basename "$backup_fullpath")"
  remote_file="${REMOTE_PATH%/}/${base}"
  remote_target_display="${REMOTE_USER}@${REMOTE_HOST}:${remote_file}"
  REMOTE_BACKUP_STATUS="läuft"
  REMOTE_BACKUP_TARGET="$remote_target_display"

  log_i "[Remote] Erstelle Zielordner: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" "[Remote] Creating target folder: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
  if ! ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '$REMOTE_PATH'"; then
    REMOTE_BACKUP_STATUS="fehlgeschlagen"
    REMOTE_BACKUP_ERROR="Zielordner konnte nicht erstellt werden: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
    log_i "[Remote] Fehler: Zielordner konnte nicht erstellt werden." "[Remote] Error: target folder could not be created."
    return 1
  fi

  log_i "[Remote] Übertrage Backup per ${REMOTE_METHOD}." "[Remote] Transferring backup via ${REMOTE_METHOD}."
  case "$(lower "$REMOTE_METHOD")" in
    scp)
      # UGOS works reliably with legacy scp mode (-O). Newer scp/SFTP mode may fail with /volume paths.
      if ! scp -O -P "$REMOTE_PORT" "$backup_fullpath" "${REMOTE_USER}@${REMOTE_HOST}:${remote_file}"; then
        REMOTE_BACKUP_STATUS="fehlgeschlagen"
        REMOTE_BACKUP_ERROR="SCP-Übertragung fehlgeschlagen: ${remote_target_display}"
        log_i "[Remote] Fehler: SCP-Übertragung fehlgeschlagen." "[Remote] Error: SCP transfer failed."
        return 1
      fi
      ;;
    rsync)
      if ! rsync -av -e "ssh -p ${REMOTE_PORT}" "$backup_fullpath" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH%/}/"; then
        REMOTE_BACKUP_STATUS="fehlgeschlagen"
        REMOTE_BACKUP_ERROR="Rsync-Übertragung fehlgeschlagen: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
        log_i "[Remote] Fehler: Rsync-Übertragung fehlgeschlagen." "[Remote] Error: rsync transfer failed."
        return 1
      fi
      ;;
    *)
      REMOTE_BACKUP_STATUS="fehlgeschlagen"
      REMOTE_BACKUP_ERROR="Unbekannte REMOTE_METHOD: ${REMOTE_METHOD}"
      log_i "[Remote] Unbekannte REMOTE_METHOD: ${REMOTE_METHOD}" "[Remote] Unknown REMOTE_METHOD: ${REMOTE_METHOD}"
      return 1
      ;;
  esac

  if [[ "$REMOTE_KEEP_BACKUPS" =~ ^[0-9]+$ && "$REMOTE_KEEP_BACKUPS" -gt 0 ]]; then
    ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" \
      "mkdir -p '$REMOTE_PATH' && ls -1t '$REMOTE_PATH'/${ARCHIVE_PREFIX}_*.tar* 2>/dev/null | awk 'NR>${REMOTE_KEEP_BACKUPS}' | xargs -r rm -f --" || true
  fi
  REMOTE_BACKUP_STATUS="erfolgreich"
  REMOTE_BACKUP_ERROR=""
  log_i "[Remote] Externe Sicherung erfolgreich: ${remote_target_display}" "[Remote] Remote backup successful: ${remote_target_display}"
}

build_backup_mail_details(){
  local event="${1:-success}"
  local archive_path="${2:-}"
  local archive_size="${3:-}"
  local duration_h="${4:-}"

  "$PYTHON_BIN" - "$event" "$stage_dir" "$LANGUAGE" "$SCRIPT_VERSION" "$HOST_LABEL" "$SOURCE_DIR" "$DOCKER_ROOT_DIR" "${UGOS_DOCKER_DB:-}" "$archive_path" "$archive_size" "$duration_h" "$REMOTE_BACKUP_STATUS" "$REMOTE_BACKUP_TARGET" "${REMOTE_BACKUP_ERROR:-}" "${FAILURE_REASON:-}" "$KEEP_BACKUPS" "$BACKUP_IMAGES" "$BACKUP_NAMED_VOLUMES" "$BACKUP_EXTERNAL_BINDS" "$ENABLE_REMOTE_BACKUP" "$REMOTE_METHOD" "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PATH" "$log_file" <<'PYREPORT'
import csv
import sys
from datetime import datetime
from pathlib import Path

(event, stage_dir, language, version, host, source_dir, docker_root, ugos_db, archive_path,
 archive_size, duration_h, remote_status, remote_target, remote_error, failure_reason, keep_backups,
 backup_images, backup_named_volumes, backup_external_binds, enable_remote, remote_method,
 remote_user, remote_host, remote_path, log_file) = sys.argv[1:26]

lang_en = (language or "de").lower().startswith("en")
base = Path(stage_dir) if stage_dir else Path("")
meta = base / "metadata"

def t(de, en):
    return en if lang_en else de

def yes(v):
    return str(v or "").lower() in ("true", "1", "yes", "ja", "y")

def read_tsv(path):
    p = Path(path)
    if not p.exists():
        return []
    with p.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))

def hr(n):
    try:
        n = int(n)
    except Exception:
        return "0B"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    value = float(n)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f}{unit}" if unit != "B" else f"{int(value)}B"
        value /= 1024

def count_csv(value):
    return len([x for x in str(value or "").split(",") if x.strip()])

def csv_items(value):
    return [x.strip() for x in str(value or "").split(",") if x.strip()]

def add_limited(lines, title, items, limit=8):
    lines.append(title)
    if not items:
        lines.append("- " + t("keine", "none"))
        return
    for item in items[:limit]:
        lines.append("- " + item)
    if len(items) > limit:
        lines.append("- " + t(f"... und {len(items)-limit} weitere", f"... and {len(items)-limit} more"))

projects = read_tsv(meta / "selected_projects.tsv")
running = read_tsv(meta / "selected_running_containers.tsv")
external = read_tsv(meta / "external_bind_mounts.tsv")
external_archives = read_tsv(meta / "external_bind_archives.tsv")
external_archived_count = len({r.get("archive", "") for r in external_archives if r.get("archive", "")})
volumes = read_tsv(meta / "selected_named_volumes.tsv")
archive_rows = read_tsv(meta / "project_archives.tsv")
archive_map = {r.get("project", ""): r for r in archive_rows}
images_file = meta / "selected_images.txt"
images = []
if images_file.exists():
    images = [x.strip() for x in images_file.read_text(encoding="utf-8", errors="ignore").splitlines() if x.strip()]
exclude_file = meta / "backup_exclude_paths.txt"
backup_exclude_paths = []
if exclude_file.exists():
    backup_exclude_paths = [x.strip() for x in exclude_file.read_text(encoding="utf-8", errors="ignore").splitlines() if x.strip()]

remote_enabled = yes(enable_remote)
planned_target = ""
if remote_enabled:
    if remote_target:
        planned_target = remote_target
    elif remote_user and remote_host and remote_path:
        planned_target = f"{remote_user}@{remote_host}:{remote_path}"
    else:
        planned_target = t("aktiviert, Ziel unvollständig konfiguriert", "enabled, target incomplete")

def remote_line_for_event():
    if not remote_enabled:
        return t("deaktiviert", "disabled")
    if event == "start":
        return t("aktiviert/geplant", "enabled/planned") + (f" ({planned_target})" if planned_target else "")
    if str(remote_status or "").lower() in ("erfolgreich", "successful") and remote_target:
        return str(remote_status) + f" ({remote_target})"
    if remote_status:
        return str(remote_status)
    return t("aktiviert", "enabled")

project_summary = []
for p in projects:
    name = p.get("project", "")
    containers = count_csv(p.get("containers", ""))
    if event == "start":
        project_summary.append(f"{name} ({containers} {t('Container', 'container(s)')})")
    else:
        size = "-"
        a = archive_map.get(name, {}).get("archive")
        if a:
            ap = base / a
            if ap.exists():
                size = hr(ap.stat().st_size)
        project_summary.append(f"{name}: {containers} {t('Container', 'container(s)')}, {t('Projektarchiv', 'project archive')}: {size}")

running_summary = []
for r in running:
    name = r.get("name", "")
    project = r.get("project", "")
    image = r.get("image", "")
    if image:
        running_summary.append(f"{name} ({t('Projekt', 'project')}: {project}, Image: {image})")
    else:
        running_summary.append(f"{name} ({t('Projekt', 'project')}: {project})")

lines = []

if event == "start":
    lines.append(t("Backup gestartet", "Backup started"))
    lines.append("")
    lines.append(t("Kurzüberblick:", "Summary:"))
    lines.append(f"- {t('Host', 'Host')}: {host}")
    lines.append(f"- {t('Ausgewählte Projekte', 'Selected projects')}: {len(projects)}")
    lines.append(f"- {t('Container werden kurz gestoppt', 'Containers temporarily stopped')}: {len(running)}")
    lines.append(f"- {t('Externe Sicherung', 'Remote backup')}: {remote_line_for_event()}")
    lines.append(f"- {t('Startzeit', 'Start time')}: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    add_limited(lines, t("Ausgewählte Projekte:", "Selected projects:"), project_summary)
    lines.append("")
    add_limited(lines, t("Kurz gestoppte Container:", "Temporarily stopped containers:"), running_summary)
    lines.append("")
    lines.append(t("Hinweise:", "Notes:"))
    if yes(backup_external_binds):
        lines.append(f"- {len(external)} {t('externe Bind-Mounts erkannt, werden mitgesichert', 'external bind mounts detected, will be backed up')}")
    else:
        lines.append(f"- {len(external)} {t('externe Bind-Mounts erkannt, nicht im Archiv enthalten', 'external bind mounts detected, not included in the archive')}")
    if backup_exclude_paths:
        lines.append(f"- {t('Backup-Ausschlussregeln', 'Backup exclude rules')}: {len(backup_exclude_paths)} {t('aktiv', 'active')}")
        for ep in backup_exclude_paths[:3]:
            lines.append(f"  - {ep}")
    lines.append(f"- {t('Details stehen im Log-Anhang der Abschluss-Mail', 'Details are included in the final mail log attachment')}")
else:
    if event == "fail":
        lines.append(t("Backup fehlgeschlagen", "Backup failed"))
        lines.append("")
        lines.append(t("Fehler:", "Error:"))
        if remote_error:
            lines.append(f"- {remote_error}")
        if failure_reason:
            lines.append(f"- {failure_reason}")
        if not remote_error and not failure_reason:
            lines.append(f"- {t('siehe Log-Anhang', 'see log attachment')}")
        lines.append("")
    else:
        lines.append(t("Backup erfolgreich abgeschlossen", "Backup completed successfully"))
        lines.append("")

    lines.append(t("Status:", "Status:"))
    lines.append(f"- {t('Lokales Archiv', 'Local archive')}: {t('erstellt', 'created') if archive_path else t('nicht verfügbar', 'not available')}")
    if archive_size:
        lines.append(f"- {t('Archivgröße', 'Archive size')}: {archive_size}")
    if duration_h:
        lines.append(f"- {t('Laufzeit', 'Duration')}: {duration_h}")
    lines.append(f"- {t('Externe Sicherung', 'Remote backup')}: {remote_line_for_event()}")
    lines.append(f"- {t('Lokale Aufbewahrung', 'Local retention')}: {t('letzte', 'last')} {keep_backups} {t('Backups', 'backups')}")
    if archive_path:
        lines.append(f"- {t('Archiv', 'Archive')}: {archive_path}")
    lines.append("")

    add_limited(lines, t("Gesicherte Projekte:", "Backed up projects:"), project_summary, limit=12)
    lines.append("")

    lines.append(t("Hinweise:", "Notes:"))
    if yes(backup_external_binds):
        lines.append(f"- {len(external)} {t('externe Bind-Mounts erkannt', 'external bind mounts detected')}, {external_archived_count} {t('externes Bind-Archiv erstellt', 'external bind archive(s) created')}")
    else:
        lines.append(f"- {len(external)} {t('externe Bind-Mounts erkannt und nicht gesichert', 'external bind mounts detected and not backed up')}")
    if backup_exclude_paths:
        lines.append(f"- {t('Backup-Ausschlussregeln', 'Backup exclude rules')}: {len(backup_exclude_paths)} {t('aktiv', 'active')}")
        for ep in backup_exclude_paths[:5]:
            lines.append(f"  - {ep}")
    lines.append(f"- {t('Docker Images separat sichern', 'Separate Docker image backup')}: {backup_images} ({len(images)} {t('Images erkannt', 'images detected')})")
    lines.append(f"- {t('Named Volumes separat sichern', 'Separate named volume backup')}: {backup_named_volumes} ({len(volumes)} {t('Volumes erkannt', 'volumes detected')})")
    lines.append(f"- {t('Details siehe Log-Anhang', 'Details: see log attachment')}")
    if remote_error:
        lines.append(f"- {t('Remote-Fehler', 'Remote error')}: {remote_error}")

lines.append("")
lines.append(t("Logdatei:", "Log file:"))
lines.append(f"- {log_file}")

print("\n".join(lines))
PYREPORT
}

on_error(){
  local exitcode=$?
  local failed_cmd="${BASH_COMMAND:-unbekannt}"
  trap - ERR
  if [[ -z "${FAILURE_REASON:-}" ]]; then
    FAILURE_REASON="Exit-Code ${exitcode}; letzter Befehl: ${failed_cmd}"
  fi
  log_i "[Fehler] Backup wurde abgebrochen. Exit-Code: ${exitcode}" "[Error] Backup aborted. Exit code: ${exitcode}"
  restart_selected_containers || true
  local attach
  attach="$(mail_tail_file)"
  local fail_duration=""
  if [[ "${script_start_epoch:-0}" -gt 0 ]]; then
    local now_epoch duration
    now_epoch="$(date +%s)"
    duration=$((now_epoch - script_start_epoch))
    fail_duration=$(printf "%02d:%02d:%02d" $((duration/3600)) $(((duration%3600)/60)) $((duration%60)))
  fi
  local fail_archive="" fail_size=""
  if [[ -n "${backup_fullpath:-}" && -f "$backup_fullpath" ]]; then
    fail_archive="$backup_fullpath"
    fail_size="$(hr_size "$(wc -c < "$backup_fullpath" 2>/dev/null || echo 0)")"
  fi
  send_mail "fail" "$(mail_subject fail)" "$(tr_text 'Fehler' 'Error')" "$(build_backup_mail_details fail "$fail_archive" "$fail_size" "$fail_duration")" "$attach" || true
  exit "$exitcode"
}
trap on_error ERR

main(){
  mkdir_safe "$BACKUP_DIR"
  mkdir_safe "$TEMP_DIR"
  mkdir_safe "$LOG_DIR"
  log_file="$(rotate_logs)"

  local ts
  ts="$(date +'%Y-%m-%d_%H-%M-%S')"
  script_start_epoch="$(date +%s)"
  stage_parent="${TEMP_DIR}/${ARCHIVE_PREFIX}_${ts}_work"
  stage_dir="${stage_parent}/${ARCHIVE_PREFIX}_${ts}"
  mkdir_safe "$stage_dir"

  log_i "UGREEN Docker Backup v${SCRIPT_VERSION} wird gestartet." "UGREEN Docker Backup v${SCRIPT_VERSION} is starting."

  resolve_auto_paths
  preflight

  log_i "Host: ${HOST_LABEL}" "Host: ${HOST_LABEL}"
  log_i "Docker Root Dir: ${DOCKER_ROOT_DIR}" "Docker Root Dir: ${DOCKER_ROOT_DIR}"
  log_i "Docker-Projektordner: ${SOURCE_DIR}" "Docker project folder: ${SOURCE_DIR}"
  log_i "UGOS-Docker-DB: ${UGOS_DOCKER_DB:-nicht gefunden}" "UGOS Docker DB: ${UGOS_DOCKER_DB:-not found}"

  collect_metadata
  create_inventory
  create_network_inventory

  local selected_count running_count external_count
  selected_count="$(awk 'NR>1 && $1!="" {c++} END{print c+0}' "${stage_dir}/metadata/selected_projects.tsv" 2>/dev/null || echo 0)"
  running_count="$(awk 'NR>1 && $1!="" {c++} END{print c+0}' "${stage_dir}/metadata/selected_running_containers.tsv" 2>/dev/null || echo 0)"
  external_count="$(awk 'NR>1 && $1!="" {c++} END{print c+0}' "${stage_dir}/metadata/external_bind_mounts.tsv" 2>/dev/null || echo 0)"

  log_selection_summary

  if (( selected_count == 0 )); then
    FAILURE_REASON="$(tr_text 'Keine Projekte für die Sicherung ausgewählt. Bitte BACKUP_ALL_PROJECTS, INCLUDE_PROJECTS und EXCLUDE_PROJECTS prüfen.' 'No projects selected for backup. Please check BACKUP_ALL_PROJECTS, INCLUDE_PROJECTS and EXCLUDE_PROJECTS.')"
    log_i "[Fehler] Keine Projekte für die Sicherung ausgewählt. Backup wird abgebrochen." "[Error] No projects selected for backup. Backup will abort."
    die "$FAILURE_REASON"
  fi

  send_mail "start" "$(mail_subject start)" "$(tr_text 'Backup gestartet' 'Backup started')" "$(build_backup_mail_details start)" "" || true

  stop_selected_containers
  copy_project_dirs
  backup_named_volumes
  backup_external_binds
  backup_images
  restart_selected_containers

  create_final_archive "$ts"
  prune_local_backups
  remote_backup

  backup_success="true"
  local size_bytes size_h attach end_epoch duration duration_hm
  size_bytes="$(wc -c < "$backup_fullpath" 2>/dev/null || echo 0)"
  size_h="$(hr_size "$size_bytes")"
  end_epoch="$(date +%s)"
  duration=$((end_epoch - script_start_epoch))
  duration_hm=$(printf "%02d:%02d:%02d" $((duration/3600)) $(((duration%3600)/60)) $((duration%60)))
  attach="$(mail_tail_file)"
  send_mail "success" "$(mail_subject success)" "$(tr_text 'Erfolgreich' 'Successful')" "$(build_backup_mail_details success "$backup_fullpath" "$size_h" "$duration_hm")" "$attach" || true

  rm -rf "$stage_parent" || true
  log_i "Backup abgeschlossen." "Backup completed."

  if is_true "$SHUTDOWN_AFTER_SUCCESS"; then
    log_i "[Shutdown] NAS wird nach erfolgreichem Backup heruntergefahren." "[Shutdown] Shutting down NAS after successful backup."
    $SHUTDOWN_COMMAND
  fi
}

main "$@"
