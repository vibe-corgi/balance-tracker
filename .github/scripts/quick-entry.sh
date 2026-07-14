#!/bin/bash
set -euo pipefail

FUID="uoU98EFYUuNwHHen9CtDoT6BRgL2"
PROJECT="balance-408f1"
BASE="https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/users/$FUID/data"

PAYLOAD="$EVENT_PAYLOAD"
ENTRY_TYPE=$(echo "$PAYLOAD" | jq -r '.entry_type')
DATE=$(echo "$PAYLOAD" | jq -r '.date // empty')
LEVEL=$(echo "$PAYLOAD" | jq -r '.level // empty')
TIME=$(echo "$PAYLOAD" | jq -r '.time // empty')
NOTE=$(echo "$PAYLOAD" | jq -r '.note // empty')
EVENT_TYPE=$(echo "$PAYLOAD" | jq -r '.event_type // empty')
DURATION=$(echo "$PAYLOAD" | jq -r '.duration // empty')
END_TIME=$(echo "$PAYLOAD" | jq -r '.end_time // empty')

# Default to today KST if no date provided
[ -z "$DATE" ] && DATE=$(TZ=Asia/Seoul date +%Y-%m-%d)
[ -z "$TIME" ] && TIME=$(TZ=Asia/Seoul date +%H:%M)

echo "Writing: type=$ENTRY_TYPE, date=$DATE, level=$LEVEL, time=$TIME"

# Fetch existing entry
ENCODED=$(echo "entry:$DATE" | sed 's/:/%3A/g')
RAW=$(curl -s "$BASE/$ENCODED" -H "Authorization: Bearer $FB_TOKEN")
EXISTING=$(echo "$RAW" | jq -r '.fields.value.stringValue // empty')

if [ -z "$EXISTING" ]; then
  EXISTING=$(jq -n --arg date "$DATE" '{"date":$date,"morning":null,"evening":null,"events":[]}')
fi

# Merge into entry
case "$ENTRY_TYPE" in
  morning)
    UPDATED=$(echo "$EXISTING" | jq \
      --argjson lv "${LEVEL:-3}" --arg wt "$TIME" --arg note "$NOTE" \
      '.morning = {"level":$lv,"wakeTime":$wt,"note":$note,"period":false}')
    MSG="아침 컨디션 ${LEVEL}/5 기록 완료 (기상 $TIME)"
    ;;
  evening)
    UPDATED=$(echo "$EXISTING" | jq \
      --argjson lv "${LEVEL:-3}" --arg bt "$TIME" --arg note "$NOTE" \
      '.evening = {"level":$lv,"bedTime":$bt,"note":$note}')
    MSG="저녁 컨디션 ${LEVEL}/5 기록 완료 (취침 $TIME)"
    ;;
  event)
    EVENT_ID=$(date +%s)
    case "$EVENT_TYPE" in
      exercise)
        DUR="${DURATION:-30}"
        ET="${END_TIME:-$TIME}"
        UPDATED=$(echo "$EXISTING" | jq \
          --arg id "$EVENT_ID" --arg type "$EVENT_TYPE" \
          --arg time "$TIME" --arg endTime "$ET" \
          --argjson dur "${DUR}" --arg memo "$NOTE" \
          '.events += [{"id":$id,"type":$type,"time":$time,"endTime":$endTime,"duration":$dur,"memo":$memo}]')
        MSG="운동 ${DUR}분 기록 완료 ($TIME)"
        ;;
      meal)
        ET="${END_TIME:-$TIME}"
        UPDATED=$(echo "$EXISTING" | jq \
          --arg id "$EVENT_ID" --arg type "$EVENT_TYPE" \
          --arg time "$TIME" --arg endTime "$ET" --arg label "$NOTE" \
          '.events += [{"id":$id,"type":$type,"time":$time,"endTime":$endTime,"label":$label}]')
        MSG="식사 기록 완료 ($TIME)"
        ;;
      meditation)
        DUR="${DURATION:-10}"
        ET="${END_TIME:-$TIME}"
        UPDATED=$(echo "$EXISTING" | jq \
          --arg id "$EVENT_ID" --arg type "$EVENT_TYPE" \
          --arg time "$TIME" --arg endTime "$ET" --argjson dur "${DUR}" \
          '.events += [{"id":$id,"type":$type,"time":$time,"endTime":$endTime,"duration":$dur}]')
        MSG="명상 ${DUR}분 기록 완료"
        ;;
      bathroom)
        UPDATED=$(echo "$EXISTING" | jq \
          --arg id "$EVENT_ID" --arg type "$EVENT_TYPE" \
          --arg time "$TIME" --arg memo "$NOTE" \
          '.events += [{"id":$id,"type":$type,"time":$time,"memo":$memo}]')
        MSG="화장실 기록 완료"
        ;;
      *)
        UPDATED=$(echo "$EXISTING" | jq \
          --arg id "$EVENT_ID" --arg type "$EVENT_TYPE" \
          --arg time "$TIME" --arg memo "$NOTE" \
          '.events += [{"id":$id,"type":$type,"time":$time,"memo":$memo}]')
        MSG="$EVENT_TYPE 기록 완료"
        ;;
    esac
    ;;
  *)
    echo "Unknown entry_type: $ENTRY_TYPE"
    exit 1
    ;;
esac

# Write back to Firestore
VALUE=$(echo "$UPDATED" | jq -c '.')
BODY=$(jq -n --arg val "$VALUE" '{"fields":{"value":{"stringValue":$val}}}')

RESULT=$(curl -s -X PATCH "$BASE/$ENCODED" \
  -H "Authorization: Bearer $FB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BODY")

if echo "$RESULT" | jq -e '.fields' > /dev/null 2>&1; then
  echo "SUCCESS: $MSG"
  # Telegram 알림
  if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg chat "$TG_CHAT" --arg text "✅ BALANCE $MSG" '{chat_id:($chat|tonumber),text:$text}')" > /dev/null
  fi
else
  echo "ERROR: $(echo "$RESULT" | head -c 300)"
  exit 1
fi
