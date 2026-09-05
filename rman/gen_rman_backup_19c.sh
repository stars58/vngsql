#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
ORACLE_SID="${ORACLE_SID:-YOUR_SID}"
export ORACLE_SID

# Optional if not in PATH
# export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
# export PATH="$ORACLE_HOME/bin:$PATH"

SQLPLUS="sqlplus -S /nolog"

# Backup config
BACKUP_DIR="/backup/rman"       # adjust
BACKUP_TAG="FULL_AUTO_19C"      # adjust
MAX_SECTION_SIZE_TB=1           # threshold to split
SECTION_SIZE_GB=100             # section size when splitting >1TB files

# Output RMAN script
RMAN_SCRIPT="rman_backup_auto_19c.rcv"

# --- Helper: run SQL and get single value ---
run_sql() {
  local sql="$1"
  $SQLPLUS <<EOF | tail -n +2 | head -n1 | tr -d ' '
CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TRIMSPOOL ON TRIMOUT ON
SPOOL STDOUT
${sql}
SPOOL OFF
EXIT;
EOF
}

# --- Get CPU count (from db) ---
CPU_COUNT=$(run_sql "SELECT VALUE FROM V\$PARAMETER WHERE NAME='cpu_count';")
if [[ -z "$CPU_COUNT" || "$CPU_COUNT" -eq 0 ]]; then
  echo "ERROR: Could not determine CPU_COUNT from database." >&2
  exit 1
fi

# --- Get datafile info: file#, name, bytes ---
DF_INFO=$(mktemp)
$SQLPLUS <<EOF > "$DF_INFO"
CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TRIMSPOOL ON TRIMOUT ON COLSEP '|'
SPOOL STDOUT
SELECT FILE# || '|' || NAME || '|' || BYTES FROM V\$DATAFILE ORDER BY FILE#;
SPOOL OFF
EXIT;
EOF

NUM_DATAFILES=$(wc -l < "$DF_INFO" | tr -d ' ')
if [[ "$NUM_DATAFILES" -eq 0 ]]; then
  echo "ERROR: No datafiles found." >&2
  exit 1
fi

# --- Calculate number of channels ---
# Rule: channels = min(NUM_DATAFILES, CPU_COUNT)
if [[ "$NUM_DATAFILES" -lt "$CPU_COUNT" ]]; then
  NUM_CHANNELS="$NUM_DATAFILES"
else
  NUM_CHANNELS="$CPU_COUNT"
fi

[[ "$NUM_CHANNELS" -lt 1 ]] && NUM_CHANNELS=1

# Thresholds in bytes
MAX_SECTION_SIZE_BYTES=$((MAX_SECTION_SIZE_TB * 1024 * 1024 * 1024 * 1024))
SECTION_SIZE_BYTES=$((SECTION_SIZE_GB * 1024 * 1024 * 1024))

# --- Generate RMAN script ---
cat > "$RMAN_SCRIPT" <<'RMAN_HEADER'
RUN {
RMAN_HEADER

# Allocate channels
for ((i=1; i<=NUM_CHANNELS; i++)); do
  cat >> "$RMAN_SCRIPT" <<EOF
  ALLOCATE CHANNEL ch${i} DEVICE TYPE DISK FORMAT '${BACKUP_DIR}/%U';
EOF
done

# Build BACKUP commands
BACKUP_LINES=()

while IFS='|' read -r FILE_NUM FILE_NAME FILE_BYTES; do
  [[ -z "$FILE_NUM" ]] && continue

  if [[ "$FILE_BYTES" -gt "$MAX_SECTION_SIZE_BYTES" ]]; then
    BACKUP_LINES+=(
      "    BACKUP DATAFILE ${FILE_NUM} SECTION SIZE ${SECTION_SIZE_BYTES} TAG '${BACKUP_TAG}' FORMAT '${BACKUP_DIR}/df${FILE_NUM}_%U';"
    )
  else
    BACKUP_LINES+=(
      "    BACKUP DATAFILE ${FILE_NUM} TAG '${BACKUP_TAG}' FORMAT '${BACKUP_DIR}/df${FILE_NUM}_%U';"
    )
  fi
done < "$DF_INFO"

for line in "${BACKUP_LINES[@]}"; do
  echo "$line" >> "$RMAN_SCRIPT"
done

# Release channels
for ((i=1; i<=NUM_CHANNELS; i++)); do
  echo "  RELEASE CHANNEL ch${i};" >> "$RMAN_SCRIPT"
done

echo "}" >> "$RMAN_SCRIPT"

echo "Generated RMAN script: $RMAN_SCRIPT"
echo "  CPUs detected       : $CPU_COUNT"
echo "  Datafiles           : $NUM_DATAFILES"
echo "  Channels allocated  : $NUM_CHANNELS"
echo "  Section size (GB)   : $SECTION_SIZE_GB (used for files > ${MAX_SECTION_SIZE_TB}TB)"

rm -f "$DF_INFO"
