#!/usr/bin/env bash
set -euo pipefail

# Flags:
#   --src-transfer-id   <ID>   (обяз.) Исходный transfer ID
#   --target-id         <ID>   (обяз.) Новый target endpoint ID
#   --name              <STR>  (обяз.) Имя нового transfer
#   --description       <STR>  (обяз.) Описание
#   --type              <TYPE> (необ.) SNAPSHOT_ONLY|INCREMENT_ONLY|SNAPSHOT_AND_INCREMENT (допускается kebab-case)
#   --jobs              <N>    (необ.) runtime.ycRuntime.jobCount
#   --upload-jobs       <N>    (необ.) runtime.ycRuntime.uploadShardParams.jobCount
#   --upload-proc|--proc <N>   (необ.) runtime.ycRuntime.uploadShardParams.processCount
#   --salt              <STR>  (необ.) Соль для maskFunctionHash.userDefinedSalt (если надо)
#   --schedule          <CRON> (необ.) cron-выражение, напр. "0 0 * * *" (локальное время узла с cron)
#   --daily             <HH:MM>(необ.) шорткат для ежедневного запуска в локальное время, напр. "00:00"
#
# Env fallback:
#   DT_MASK_SALT — соль по умолчанию, если не передана флагом
#
# Примечания:
# - cron использует таймзону машины с cron.
# - Таймеры Cloud Functions (альтернатива cron) используют UTC cron. :contentReference[oaicite:2]{index=2}

usage() {
  cat <<EOF
Usage:
  $0 \\
    --src-transfer-id dttAAAA... \\
    --target-id dteBBBB... \\
    --name "my-new-transfer" \\
    --description "copy with new target" \\
    [--type SNAPSHOT_ONLY|INCREMENT_ONLY|SNAPSHOT_AND_INCREMENT] \\
    [--jobs 1] [--upload-jobs 1] [--upload-proc 4] \\
    [--salt "QlFUqjyw18wGhPZ"] \\
    [--schedule "0 0 * * *"] | [--daily "00:00"]
EOF
  exit 1
}

# ---------- parse flags ----------
SRC_TRANSFER_ID=""; TARGET_ID=""; NEW_NAME=""; NEW_DESC=""
DT_TYPE=""; DT_JOBS=""; DT_UP_JOBS=""; DT_UP_PROC=""
MASK_SALT="${DT_MASK_SALT:-}"
CRON_EXPR=""; DAILY_TIME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-transfer-id) SRC_TRANSFER_ID="${2:-}"; shift 2;;
    --target-id)       TARGET_ID="${2:-}"; shift 2;;
    --name)            NEW_NAME="${2:-}"; shift 2;;
    --description)     NEW_DESC="${2:-}"; shift 2;;
    --type)            DT_TYPE="${2:-}"; shift 2;;
    --jobs)            DT_JOBS="${2:-}"; shift 2;;
    --upload-jobs)     DT_UP_JOBS="${2:-}"; shift 2;;
    --upload-proc|--proc) DT_UP_PROC="${2:-}"; shift 2;;
    --salt)            MASK_SALT="${2:-}"; shift 2;;
    --schedule)        CRON_EXPR="${2:-}"; shift 2;;
    --daily)           DAILY_TIME="${2:-}"; shift 2;;
    -h|--help)         usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

# required
[[ -n "$SRC_TRANSFER_ID" && -n "$TARGET_ID" && -n "$NEW_NAME" && -n "$NEW_DESC" ]] || usage

# normalize TYPE
if [[ -n "$DT_TYPE" ]]; then
  DT_TYPE="${DT_TYPE//-/_}"; DT_TYPE="${DT_TYPE^^}"
  case "$DT_TYPE" in
    SNAPSHOT_ONLY|INCREMENT_ONLY|SNAPSHOT_AND_INCREMENT) : ;;
    *) echo "Invalid --type: $DT_TYPE"; exit 1;;
  esac
fi

# build CRON from --daily if задан
if [[ -z "$CRON_EXPR" && -n "$DAILY_TIME" ]]; then
  if [[ "$DAILY_TIME" =~ ^([0-1][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    H="${BASH_REMATCH[1]}"; M="${BASH_REMATCH[2]}"
    CRON_EXPR="${M} ${H} * * *"
  else
    echo "Bad --daily format, expected HH:MM, got: $DAILY_TIME"; exit 1
  fi
fi

TMP_SRC="src-transfer.json"
CREATE_JSON="create.json"

echo "[1/5] get source transfer..."
yc datatransfer transfer get "$SRC_TRANSFER_ID" --format json > "$TMP_SRC"

# detect mask_function_hash
HAS_MASK=$(
  jq -e '(.transformation.transformers // [])
         | any(.mask_field? and (.mask_field.function.mask_function_hash? != null))' "$TMP_SRC" >/dev/null \
    && echo yes || echo no
)

# generate salt if needed
if [[ "$HAS_MASK" == "yes" && -z "${MASK_SALT}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    MASK_SALT="$(openssl rand -hex 16)"
    echo "[i] maskFunctionHash detected; generated salt: ${MASK_SALT}"
  else
    echo "❌ Need salt for maskFunctionHash; pass --salt or set DT_MASK_SALT"; exit 1
  fi
fi

echo "[2/5] build create.json..."
jq \
  --arg newTargetId "$TARGET_ID" \
  --arg newName "$NEW_NAME" \
  --arg newDesc "$NEW_DESC" \
  --arg newType "${DT_TYPE:-}" \
  --arg jobs "${DT_JOBS:-}" \
  --arg upJobs "${DT_UP_JOBS:-}" \
  --arg upProc "${DT_UP_PROC:-}" \
  --arg maskSalt "${MASK_SALT:-}" '
  del(.id, .status)
  | .folderId = (.folder_id // .folderId) | del(.folder_id)
  | .sourceId = (.source.id // .sourceId) | del(.source)
  | .targetId = $newTargetId | del(.target)
  | .name = $newName
  | .description = $newDesc
  | if .runtime and .runtime.yc_runtime then
      .runtime = {
        ycRuntime: {
          jobCount: (.runtime.yc_runtime.job_count // .runtime.yc_runtime.jobCount),
          uploadShardParams: {
            jobCount:    (.runtime.yc_runtime.upload_shard_params.job_count    // .runtime.yc_runtime.upload_shard_params.jobCount),
            processCount:(.runtime.yc_runtime.upload_shard_params.process_count // .runtime.yc_runtime.upload_shard_params.processCount)
          }
        }
      }
    else . end
  | if .data_objects then
      .dataObjects = { includeObjects: ((.data_objects.include_objects // .data_objects.includeObjects) // []) }
      | del(.data_objects)
    else . end
  | if .transformation and .transformation.transformers then
      .transformation.transformers |= (map(
        if has("mask_field") then
          {
            maskField: {
              tables: {
                includeTables: (((.mask_field.tables.include_tables // .mask_field.tables.includeTables) // []) | unique),
                excludeTables: (((.mask_field.tables.exclude_tables // .mask_field.tables.excludeTables) // []))
              },
              columns: (((.mask_field.columns // []) | map(select(. != "")) | unique)),
              function: (
                if (.mask_field.function.mask_function_hash // null) != null then
                  if ($maskSalt | length) > 0 then
                    { maskFunctionHash: { userDefinedSalt: $maskSalt } }
                  else
                    { maskFunctionHash: {} }
                  end
                else
                  .mask_field.function
                end
              )
            }
          }
        else
          .
        end
      ))
    else . end
  | if ($newType | length) > 0 then .type = $newType else . end
  | if (($jobs|length)>0 or ($upJobs|length)>0 or ($upProc|length)>0) then
      .runtime = (.runtime // {}) |
      .runtime.ycRuntime = (.runtime.ycRuntime // {}) |
      (if ($jobs|length)>0    then .runtime.ycRuntime.jobCount = $jobs          else . end) |
      .runtime.ycRuntime.uploadShardParams = (.runtime.ycRuntime.uploadShardParams // {}) |
      (if ($upJobs|length)>0  then .runtime.ycRuntime.uploadShardParams.jobCount    = $upJobs  else . end) |
      (if ($upProc|length)>0  then .runtime.ycRuntime.uploadShardParams.processCount= $upProc  else . end)
    else . end
' "$TMP_SRC" > "$CREATE_JSON"

echo "[3/5] create transfer..."
CREATE_OUT="$(yc datatransfer transfer create --file "$CREATE_JSON" --format json)"
NEW_TID="$(jq -r '.response.id // .id // .metadata.transfer_id // empty' <<<"$CREATE_OUT")"
if [[ -z "${NEW_TID}" ]]; then
  echo "❌ Could not parse new transfer id from create output"; echo "$CREATE_OUT"; exit 1
fi
echo "[i] New transfer id: ${NEW_TID}"

# ----- Optional: schedule with cron -----
if [[ -n "$CRON_EXPR" ]]; then
  echo "[4/5] installing cron schedule: '${CRON_EXPR}' (local TZ)"

  # deps
  command -v crontab >/dev/null 2>&1 || { echo "❌ crontab not found"; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "❌ jq not found"; exit 1; }

  RUN_DIR="$HOME/.local/bin"
  LOG_DIR="$HOME/.local/var/log/yc-dt"
  mkdir -p "$RUN_DIR" "$LOG_DIR"

  RUN_SCRIPT="$RUN_DIR/yc-run-transfer-$NEW_TID.sh"
  cat > "$RUN_SCRIPT" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TID="__TID__"
# Если трансфер уже RUNNING — не стартуем второй раз.
STATUS="$(yc datatransfer transfer get "$TID" --format json | jq -r '.status // ""')"
if [[ "$STATUS" == "RUNNING" ]]; then
  echo "$(date -Is) [$TID] already RUNNING, skip."
  exit 0
fi
yc datatransfer transfer activate "$TID" --async
echo "$(date -Is) [$TID] activated."
EOS
  sed -i "s/__TID__/$NEW_TID/g" "$RUN_SCRIPT"
  chmod +x "$RUN_SCRIPT"

  # убрать старые строки для этого скрипта и добавить новую
  ( crontab -l 2>/dev/null | grep -v "$RUN_SCRIPT" || true; echo "$CRON_EXPR $RUN_SCRIPT >> $LOG_DIR/$NEW_TID.log 2>&1" ) | crontab -
  echo "[i] cron installed. Log: $LOG_DIR/$NEW_TID.log"
else
  echo "[4/5] no --schedule/--daily specified; skipping cron setup."
fi

echo "[5/5] done. Files: $CREATE_JSON"
