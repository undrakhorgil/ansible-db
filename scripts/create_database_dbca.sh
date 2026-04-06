#!/usr/bin/env bash
# Manual DBCA create — mirrors playbooks/tasks/oracle/16_create_orcl_database.yml (Oracle Restart + ASM).
# Run as root:  sudo bash scripts/create_database_dbca.sh
# Edit the variables below if your paths/SID/passwords differ from group_vars/all.yml.

set -euo pipefail

# --- paths / users (match group_vars/all.yml) ---
ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"
ORACLE_HOME="${ORACLE_HOME:-/u01/app/oracle/product/26.0.0/dbhome_1}"
GRID_HOME="${GRID_HOME:-/u01/app/26.0.0/grid}"
ORACLE_USER="${ORACLE_USER:-oracle}"
GRID_USER="${GRID_USER:-grid}"

# --- database identity ---
GDB_NAME="${GDB_NAME:-ORCL}"
SID="${SID:-ORCL}"
PDB_NAME="${PDB_NAME:-ORCLPDB}"
CHARACTER_SET="${CHARACTER_SET:-AL32UTF8}"
DATABASE_CONFIG_TYPE="${DATABASE_CONFIG_TYPE:-SINGLE}"

# --- ASM ---
DATA_DG="${DATA_DG:-DATA}"
FRA_DG="${FRA_DG:-FRA}"
RECOVERY_AREA_MB="${RECOVERY_AREA_MB:-20480}"
ASM_SID="${ASM_SID:-+ASM}"

# --- passwords (change for production) ---
SYS_PW="${SYS_PW:-Welcome1}"
SYSTEM_PW="${SYSTEM_PW:-Welcome1}"
DBSNMP_PW="${DBSNMP_PW:-Welcome1}"
PDBADMIN_PW="${PDBADMIN_PW:-Welcome1}"
ASMSNMP_PW="${ASMSNMP_PW:-${DBSNMP_PW}}"

# --- DBCA options ---
IGNORE_PREREQS="${IGNORE_PREREQS:-true}"
DBCA_TIMEOUT_SEC="${DBCA_TIMEOUT_SEC:-7200}"
SETUID_ORACLE="${SETUID_ORACLE:-true}"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root (uses runuser to ${ORACLE_USER} / ${GRID_USER})." >&2
    exit 1
  fi
}

precheck_asm() {
  runuser -u "$GRID_USER" -- env \
    DATA_DG="$DATA_DG" \
    FRA_DG="$FRA_DG" \
    ORACLE_HOME="$GRID_HOME" \
    ORACLE_SID="$ASM_SID" \
    "PATH=${GRID_HOME}/bin:${PATH}" \
    /bin/bash <<'EOS'
set -euo pipefail
export ORACLE_HOME ORACLE_SID PATH
for DG in "$DATA_DG" "$FRA_DG"; do
  "$ORACLE_HOME/bin/srvctl" start diskgroup -g "$DG" 2>/dev/null || true
done
set +e
CNT=$(printf '%s\n' \
  'SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF PAGESIZE 0' \
  "SELECT COUNT(*) FROM v\$asm_diskgroup WHERE UPPER(name) IN (UPPER('${DATA_DG}'), UPPER('${FRA_DG}')) AND state = 'MOUNTED';" \
  'EXIT;' | sqlplus -s "/ as sysasm")
SP_RC=$?
set -e
CNT=$(echo "$CNT" | tr -d ' \r\n\t')
if [[ ! "$CNT" =~ ^[0-9]+$ ]]; then
  echo "FATAL: sqlplus did not return a numeric COUNT (rc=$SP_RC, output='$CNT')." >&2
  printf '%s\n' \
    'SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF PAGESIZE 0' \
    'SELECT name, state FROM v$asm_diskgroup ORDER BY 1;' \
    'EXIT;' | sqlplus -s "/ as sysasm" || true
  exit 1
fi
if [[ "${CNT:-0}" != "2" ]]; then
  echo "FATAL: need 2 MOUNTED disk groups ($DATA_DG, $FRA_DG); count='${CNT:-}'" >&2
  printf '%s\n' \
    'SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF PAGESIZE 0' \
    'SELECT name, state FROM v$asm_diskgroup ORDER BY 1;' \
    'EXIT;' | sqlplus -s "/ as sysasm" || true
  exit 1
fi
EOS
}

run_dbca() {
  local ignore_flag=""
  [[ "$IGNORE_PREREQS" == "true" ]] && ignore_flag="-ignorePreReqs"

  runuser -u "$ORACLE_USER" -- /bin/bash <<EOS
set -euo pipefail
export ORACLE_HOME="$ORACLE_HOME"
export ORACLE_BASE="$ORACLE_BASE"
export ORACLE_SID="$SID"
export PATH="\$ORACLE_HOME/bin:\$PATH"
export LD_LIBRARY_PATH="\${ORACLE_HOME}/lib:${GRID_HOME}/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

timeout "$DBCA_TIMEOUT_SEC" \\
  "\$ORACLE_HOME/bin/dbca" -silent -createDatabase \\
    $ignore_flag \\
    -templateName General_Purpose.dbc \\
    -gdbName "$GDB_NAME" \\
    -sid "$SID" \\
    -createAsContainerDatabase true \\
    -numberOfPDBs 1 \\
    -pdbName "$PDB_NAME" \\
    -characterSet "$CHARACTER_SET" \\
    -sysPassword "$SYS_PW" \\
    -systemPassword "$SYSTEM_PW" \\
    -dbsnmpPassword "$DBSNMP_PW" \\
    -pdbAdminPassword "$PDBADMIN_PW" \\
    -databaseConfigType "$DATABASE_CONFIG_TYPE" \\
    -storageType ASM \\
    -datafileDestination "+$DATA_DG" \\
    -asmsnmpPassword "$ASMSNMP_PW" \\
    -recoveryAreaDestination "+$FRA_DG" \\
    -recoveryAreaSize "$RECOVERY_AREA_MB" \\
    -useOMF true \\
    -rmanParallelism 1 \\
    -initParams 'db_create_file_dest=+$DATA_DG,db_recovery_file_dest=+$FRA_DG,db_recovery_file_dest_size=${RECOVERY_AREA_MB}M'
EOS
}

srvctl_diskgroups() {
  runuser -u "$GRID_USER" -- /bin/bash <<EOS
set -euo pipefail
export ORACLE_HOME="$GRID_HOME"
export PATH="\$ORACLE_HOME/bin:\$PATH"
"\$ORACLE_HOME/bin/srvctl" modify database -db "$SID" -diskgroup "$DATA_DG,$FRA_DG"
EOS
}

main() {
  require_root
  precheck_asm
  if [[ "$SETUID_ORACLE" == "true" ]]; then
    chmod 6751 "$ORACLE_HOME/bin/oracle" || true
  fi
  run_dbca
  srvctl_diskgroups || true
  echo "Done. Logs: $ORACLE_BASE/cfgtoollogs/dbca/"
}

main "$@"
