#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MODE=""
SINGLE=""
RANGE=""
ROOT_PW="${ROOT_PW:-Welcome1}"
# Persist step status in the repo (survives reboot; /tmp/oradbctl.state was easy to lose). Override with ORADBCTL_STATE_FILE.
STATE_FILE="${ORADBCTL_STATE_FILE:-$SCRIPT_DIR/.oradbctl.state}"

usage() {
  echo "Usage:" >&2
  echo "  $0 -s <n> [-p <root_password>]" >&2
  echo "  $0 -u <n> [-p <root_password>]" >&2
  echo "  $0 -s -r <start-end> [-p <root_password>]" >&2
  echo "  $0 -u -r <start-end> [-p <root_password>]" >&2
  echo "  $0 -l" >&2
  echo "  $0 -?   (help; quote it in zsh: $0 '-?')" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 -s 7" >&2
  echo "  $0 -s -r 1-18" >&2
  echo "  $0 -u 10" >&2
  echo "  $0 -u -r 6-12   # reverse order" >&2
  echo "" >&2
  echo "Notes:" >&2
  echo "  - Undo uses the same step number: $0 -u <n>" >&2
  echo "  - $0 -l reads step status from: ${STATE_FILE}" >&2
  echo "  - Status is recorded only when you run -s / -r / -u through this script (not raw ansible-playbook)." >&2
}

# Format per line: step <n> <DONE|FAILED> <timestamp>
# Use numeric compare for $2 — BSD awk is picky; avoid $2==n edge cases.
step_status() {
  local n="$1"
  [[ -f "${STATE_FILE}" ]] || { echo ""; return 0; }
  awk -v n="$n" '$1=="step" && ($2+0)==(n+0) { s=$3 } END { print s }' "${STATE_FILE}" 2>/dev/null || true
}

write_step_status() {
  local n="$1" status="$2"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
  mkdir -p "$(dirname "${STATE_FILE}")" 2>/dev/null || true
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  if [[ -f "${STATE_FILE}" ]]; then
    awk -v n="$n" '$1=="step" && ($2+0)==(n+0) { next } { print }' "${STATE_FILE}" > "${tmp}" 2>/dev/null || true
  fi
  printf "step %s %s %s\n" "${n}" "${status}" "${ts}" >> "${tmp}"
  mv "${tmp}" "${STATE_FILE}"
}

clear_step_status() {
  local n="$1"
  [[ -f "${STATE_FILE}" ]] || return 0
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  awk -v n="$n" '$1=="step" && ($2+0)==(n+0) { next } { print }' "${STATE_FILE}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${STATE_FILE}"
}

list_steps() {
  local max_step=$(( ${#ORACLE_GRID_STEPS[@]} - 1 ))
  echo "Steps:"
  for ((i=1;i<=max_step;i++)); do
    local st
    st="$(step_status "$i")"
    local tag=""
    case "$st" in
      DONE) tag="[DONE]" ;;
      FAILED) tag="[FAILED]" ;;
      *) tag="" ;;
    esac
    printf "  %-8s %2d  %s\n" "$tag" "$i" "${STEP_TITLE[$i]}"
  done
  echo ""
  echo "State file: ${STATE_FILE}"
  echo "Empty status = no record (run steps via this script's -s / -r, or state file new/cleared)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -\?|--help|-h) usage; exit 0 ;;
    -l|--list) MODE="list" ;;
    -s) MODE="step"; [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]] && SINGLE="$2" && shift ;;
    -u) MODE="undo"; [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]] && SINGLE="$2" && shift ;;
    -r) RANGE="$2"; shift ;;
    -p) ROOT_PW="$2"; shift ;;
    *) usage; exit 2 ;;
  esac
  shift
done

ORACLE_GRID_STEPS=(
  "" "01_precheck_network.yml" "02_os_packages.yml" "03_users_groups.yml" "04_create_folders.yml"
  "05_shared_disks_udev.yml"
  "06_grid_software_install.yml" "07_gridsetup.yml" "08_grid_rootsh.yml" "09_executeconfigtools.yml" "10_grid_postcheck.yml"
  "11_db_software_unzip.yml" "12_db_software_install.yml"
  "13_db_rootsh.yml" "14_db_postcheck.yml" "15_create_diskgroups.yml"
  "16_create_orcl_database.yml" "17_summary.yml" "18_change_all_passwords.yml"
)

STEP_TITLE=(
  ""
  "Precheck networking"
  "OS packages & time sync"
  "Users, groups, limits"
  "Create Oracle directories"
  "Shared disks (ASM) + udev"
  "Unzip Grid Infrastructure"
  "Grid setup (standalone server / Restart)"
  "Run GI root scripts"
  "Execute GI config tools"
  "GI postcheck"
  "Unzip DB software"
  "Install DB software"
  "Run DB root scripts"
  "DB postcheck"
  "Create ASM disk groups"
  "Create database"
  "Summary"
  "Rotate root/oracle/grid passwords"
)

ORACLE_GRID_UNDOS=(
  "" "undo_01_precheck_network.yml" "undo_02_os_packages.yml" "undo_03_users_groups.yml" "undo_04_create_folders.yml"
  "undo_05_shared_disks_udev.yml"
  "undo_06_grid_software_install.yml" "undo_07_gridsetup.yml" "undo_08_grid_rootsh.yml" "undo_09_executeconfigtools.yml" "undo_10_grid_postcheck.yml"
  "undo_11_db_software_unzip.yml" "undo_12_db_software_install.yml"
  "undo_13_db_rootsh.yml" "undo_14_db_postcheck.yml" "undo_15_create_diskgroups.yml"
  "undo_16_create_orcl_database.yml" "undo_17_summary.yml" "undo_18_change_all_passwords.yml"
)

if [[ "${MODE:-}" == "list" ]]; then
  list_steps
  exit 0
fi

[[ -n "${MODE:-}" ]] || { usage; exit 2; }
[[ -n "${SINGLE:-}" || -n "${RANGE:-}" ]] || { usage; exit 2; }
[[ -z "${SINGLE:-}" || -z "${RANGE:-}" ]] || { echo "Choose single or range."; exit 2; }

run_one() {
  local step="$1"
  local idx="$step"
  local max_step=$(( ${#ORACLE_GRID_STEPS[@]} - 1 ))
  (( idx>=1 && idx<=max_step )) || { echo "Unsupported step $idx (max=$max_step)"; exit 2; }
  if [[ "$MODE" == "step" ]]; then
    if ansible-playbook -i inventory.yml playbooks/run_step.yml -e "target_root_password=$ROOT_PW" -e "oracle_step=${ORACLE_GRID_STEPS[$idx]}"; then
      write_step_status "$idx" "DONE"
    else
      write_step_status "$idx" "FAILED"
      return 1
    fi
  else
    local undo_task="${ORACLE_GRID_UNDOS[$idx]:-}"
    [[ -n "$undo_task" ]] || { echo "No undo mapping for step $idx"; exit 2; }
    if ansible-playbook -i inventory.yml playbooks/run_undo_step.yml -e "target_root_password=$ROOT_PW" -e "oracle_undo_step=${undo_task}"; then
      # Undo succeeded: clear prior status so -l reflects "not done".
      clear_step_status "$idx"
    else
      return 1
    fi
  fi
}

if [[ -n "$SINGLE" ]]; then
  run_one "$SINGLE"
else
  [[ "$RANGE" =~ ^([0-9]+)-([0-9]+)$ ]] || { echo "Invalid range"; exit 2; }
  s="${BASH_REMATCH[1]}"; e="${BASH_REMATCH[2]}"
  if [[ "$MODE" == "undo" ]]; then
    for ((i=e;i>=s;i--)); do run_one "$i"; done
  else
    for ((i=s;i<=e;i++)); do run_one "$i"; done
  fi
fi
