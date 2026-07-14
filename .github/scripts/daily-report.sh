#!/bin/bash
set -euo pipefail

FUID="uoU98EFYUuNwHHen9CtDoT6BRgL2"
PROJECT="balance-408f1"
BASE="https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/users/$FUID/data"

get_entry() {
  local encoded_key=$(echo "entry:$1" | sed 's/:/%3A/g')
  local raw=$(curl -s "$BASE/$encoded_key" -H "Authorization: Bearer $FB_TOKEN")
  local result=$(echo "$raw" | jq -r '.fields.value.stringValue // empty' 2>/dev/null)
  if [ -z "$result" ]; then
    echo "[DEBUG] No data for $1. Raw response: $(echo "$raw" | head -c 200)" >&2
  fi
  echo "$result"
}

send_telegram() {
  local text="$1"
  local payload=$(jq -n --arg chat "$TG_CHAT" --arg text "$text" '{chat_id: ($chat|tonumber), text: $text}')
  curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload" > /dev/null
}

dow_kr() {
  case $(TZ=Asia/Seoul date -d "$1" +%u) in
    1) echo "월";; 2) echo "화";; 3) echo "수";; 4) echo "목";;
    5) echo "금";; 6) echo "토";; 7) echo "일";;
  esac
}

fmt_hm() {
  local min=$1
  printf "%02d:%02d" $((min / 60)) $((min % 60))
}

# Dates (KST)
YESTERDAY=$(TZ=Asia/Seoul date -d "yesterday" +%Y-%m-%d)
DAY_BEFORE=$(TZ=Asia/Seoul date -d "2 days ago" +%Y-%m-%d)
M=$(echo "$YESTERDAY" | sed 's/^[0-9]*-//;s/-.*//' | sed 's/^0//')
D=$(echo "$YESTERDAY" | sed 's/.*-//' | sed 's/^0//')
DOW=$(dow_kr "$YESTERDAY")

ENTRY=$(get_entry "$YESTERDAY")
PREV=$(get_entry "$DAY_BEFORE")

if [ -z "$ENTRY" ]; then
  send_telegram "🌿 BALANCE 데일리 — ${M}/${D}(${DOW})

어제는 기록이 없습니다.
오늘은 꼭 체크인 해보세요! 💪"
  echo "No entry for $YESTERDAY, sent reminder"
  exit 0
fi

# Parse entry
MORNING_LV=$(echo "$ENTRY" | jq -r '.morning.level // empty')
WAKE=$(echo "$ENTRY" | jq -r '.morning.wakeTime // empty')
MORNING_NOTE=$(echo "$ENTRY" | jq -r '.morning.note // empty')
PERIOD=$(echo "$ENTRY" | jq -r '.morning.period // false')

EVENING_LV=$(echo "$ENTRY" | jq -r '.evening.level // empty')
BED=$(echo "$ENTRY" | jq -r '.evening.bedTime // empty')

MEAL_COUNT=$(echo "$ENTRY" | jq '[.events[] | select(.type=="meal")] | length')
MEALS_FEEL=$(echo "$ENTRY" | jq -r '[.events[] | select(.type=="meal" and .feel != null) | .feel] | join(", ")')
MEAL_LABELS=$(echo "$ENTRY" | jq -r '[.events[] | select(.type=="meal" and .label != null) | .label] | join(" / ")')

HYD_ML=$(echo "$ENTRY" | jq '[.events[] | select(.type=="hydration") | (.amountMl // 0)] | add // 0')

EX_MIN=$(echo "$ENTRY" | jq '[.events[] | select(.type=="exercise") | (.duration // 0)] | add // 0')
MED_MIN=$(echo "$ENTRY" | jq '[.events[] | select(.type=="meditation") | (.duration // 0)] | add // 0')
REST_MIN=$(echo "$ENTRY" | jq '[.events[] | select(.type=="rest") | (.duration // 0)] | add // 0')

BATH_COUNT=$(echo "$ENTRY" | jq '[.events[] | select(.type=="bathroom")] | length')
BATH_FEELS=$(echo "$ENTRY" | jq -r '[.events[] | select(.type=="bathroom" and .feel != null) | .feel] | join(", ")')

# Sleep calc
PREV_BED=$(echo "$PREV" | jq -r '.evening.bedTime // empty' 2>/dev/null)
SLEEP_INFO=""
SLEEP_DETAIL=""
if [ -n "$WAKE" ] && [ -n "$PREV_BED" ]; then
  BH=$(echo "$PREV_BED" | cut -d: -f1 | sed 's/^0//')
  BM=$(echo "$PREV_BED" | cut -d: -f2 | sed 's/^0//')
  WH=$(echo "$WAKE" | cut -d: -f1 | sed 's/^0//')
  WM=$(echo "$WAKE" | cut -d: -f2 | sed 's/^0//')
  BMIN=$((BH * 60 + BM))
  WMIN=$((WH * 60 + WM))
  if [ $BMIN -gt $WMIN ]; then
    SMIN=$((1440 - BMIN + WMIN))
  else
    SMIN=$((WMIN - BMIN))
  fi
  SLEEP_INFO=$(fmt_hm $SMIN)
  SLEEP_DETAIL="   어제 취침 ${PREV_BED} → 오늘 기상 ${WAKE}"
fi

# Get score from summary
SUMMARY_KEY=$(echo "$YESTERDAY" | cut -c1-7)
SUMMARY_RAW=$(curl -s "$BASE/summary:$SUMMARY_KEY" -H "Authorization: Bearer $FB_TOKEN" | jq -r '.fields.value.stringValue // empty' 2>/dev/null)
SCORE=$(echo "$SUMMARY_RAW" | jq -r ".\"$YESTERDAY\".total // empty" 2>/dev/null)

# Build message
MSG="🌿 BALANCE 데일리 — ${M}/${D}(${DOW})
"

[ -n "$SCORE" ] && MSG="${MSG}
📊 오늘의 점수: ${SCORE}점
"

MSG="${MSG}
"

# Morning
if [ -n "$MORNING_LV" ]; then
  MSG="${MSG}🌤️ 아침 컨디션: ${MORNING_LV}/5
"
fi

# Evening
if [ -n "$EVENING_LV" ]; then
  MSG="${MSG}🌙 저녁 컨디션: ${EVENING_LV}/5
"
else
  MSG="${MSG}🌙 저녁 컨디션: 기록 없음
"
fi

# Sleep
if [ -n "$SLEEP_INFO" ]; then
  MSG="${MSG}😴 수면: ${SLEEP_INFO}
${SLEEP_DETAIL}
"
fi

# Meals
if [ "$MEAL_COUNT" -gt 0 ]; then
  MSG="${MSG}🍽️ 식사: ${MEAL_COUNT}회"
  [ -n "$MEALS_FEEL" ] && MSG="${MSG} · ${MEALS_FEEL}"
  MSG="${MSG}
"
  [ -n "$MEAL_LABELS" ] && MSG="${MSG}   ${MEAL_LABELS}
"
else
  MSG="${MSG}🍽️ 식사: 기록 없음
"
fi

# Hydration
if [ "$HYD_ML" -gt 0 ]; then
  HYD_L=$(awk "BEGIN{printf \"%.1f\", $HYD_ML/1000}")
  MSG="${MSG}💧 수분: ${HYD_L}L
"
else
  MSG="${MSG}💧 수분: 기록 없음
"
fi

# Exercise
if [ "$EX_MIN" -gt 0 ]; then
  MSG="${MSG}💪 운동: $(fmt_hm $EX_MIN)
"
else
  MSG="${MSG}💪 운동: 기록 없음
"
fi

# Meditation
if [ "$MED_MIN" -gt 0 ]; then
  MSG="${MSG}🧘 명상: $(fmt_hm $MED_MIN)
"
else
  MSG="${MSG}🧘 명상: 기록 없음
"
fi

# Bathroom
if [ "$BATH_COUNT" -gt 0 ]; then
  MSG="${MSG}🚽 화장실: ${BATH_COUNT}회"
  [ -n "$BATH_FEELS" ] && MSG="${MSG} · ${BATH_FEELS}"
  MSG="${MSG}
"
else
  MSG="${MSG}🚽 화장실: 기록 없음
"
fi

# Period
[ "$PERIOD" = "true" ] && MSG="${MSG}🩸 생리중
"

# Morning note
if [ -n "$MORNING_NOTE" ] && [ "$MORNING_NOTE" != "null" ]; then
  MSG="${MSG}
📝 ${MORNING_NOTE}
"
fi

# Insight
MISSING=0
[ -z "$EVENING_LV" ] && MISSING=$((MISSING + 1))
[ "$HYD_ML" -eq 0 ] && MISSING=$((MISSING + 1))
[ "$EX_MIN" -eq 0 ] && MISSING=$((MISSING + 1))
[ "$MED_MIN" -eq 0 ] && MISSING=$((MISSING + 1))
[ "$BATH_COUNT" -eq 0 ] && MISSING=$((MISSING + 1))

if [ "$MISSING" -ge 3 ]; then
  MSG="${MSG}
💡 기록이 적은 날이에요. 조금씩 채워가면 더 정확한 컨디션 파악이 가능해요!"
elif [ "$HYD_ML" -gt 0 ] && [ "$HYD_ML" -lt 1500 ]; then
  MSG="${MSG}
💡 수분 섭취가 목표보다 부족해요. 한 잔 더 챙겨보세요!"
elif [ -n "$SCORE" ] && [ "$SCORE" -ge 80 ]; then
  MSG="${MSG}
💡 좋은 하루였어요! 이 패턴을 유지해보세요 ✨"
elif [ -n "$SCORE" ] && [ "$SCORE" -lt 50 ]; then
  MSG="${MSG}
💡 컨디션이 낮았던 날이에요. 내일은 수면과 수분에 신경 써보세요."
fi

send_telegram "$MSG"
echo "Daily report sent for $YESTERDAY"
