#!/bin/bash
set -euo pipefail

FUID="uoU98EFYUuNwHHen9CtDoT6BRgL2"
PROJECT="balance-408f1"
BASE="https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/users/$FUID/data"

get_entry() {
  curl -s "$BASE/entry:$1" -H "Authorization: Bearer $FB_TOKEN" | jq -r '.fields.value.stringValue // empty' 2>/dev/null
}

send_telegram() {
  local payload=$(jq -n --arg chat "$TG_CHAT" --arg text "$1" '{chat_id: ($chat|tonumber), text: $text}')
  curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -H "Content-Type: application/json; charset=utf-8" -d "$payload" > /dev/null
}

dow_kr() {
  case $(TZ=Asia/Seoul date -d "$1" +%u) in
    1) echo "월";; 2) echo "화";; 3) echo "수";; 4) echo "목";;
    5) echo "금";; 6) echo "토";; 7) echo "일";;
  esac
}

# Previous week: Mon to Sun
# Today is Monday (KST). Previous Monday = 7 days ago, Previous Sunday = yesterday
PREV_MON=$(TZ=Asia/Seoul date -d "7 days ago" +%Y-%m-%d)
PREV_SUN=$(TZ=Asia/Seoul date -d "yesterday" +%Y-%m-%d)

MON_M=$(echo "$PREV_MON" | sed 's/^[0-9]*-//;s/-.*//' | sed 's/^0//')
MON_D=$(echo "$PREV_MON" | sed 's/.*-//' | sed 's/^0//')
SUN_M=$(echo "$PREV_SUN" | sed 's/^[0-9]*-//;s/-.*//' | sed 's/^0//')
SUN_D=$(echo "$PREV_SUN" | sed 's/.*-//' | sed 's/^0//')

# Collect 7 days
DATES=()
SCORES=()
EX_DAYS=0
MED_DAYS=0
BATH_DAYS=0
TOTAL_MEALS=0
TOTAL_HYD=0
TOTAL_SLEEP=0
SLEEP_COUNT=0
MORNING_SUM=0
MORNING_COUNT=0
EVENING_SUM=0
EVENING_COUNT=0
BEST_DATE=""
BEST_SCORE=0
WORST_DATE=""
WORST_SCORE=999
PERIOD_DATES=""
RECORD_DAYS=0
EX_SCORE_SUM=0
EX_SCORE_COUNT=0
NO_EX_SCORE_SUM=0
NO_EX_SCORE_COUNT=0

for i in $(seq 0 6); do
  D=$(TZ=Asia/Seoul date -d "$PREV_MON + $i days" +%Y-%m-%d)
  PREV_D=$(TZ=Asia/Seoul date -d "$PREV_MON + $((i-1)) days" +%Y-%m-%d)
  DATES+=("$D")

  ENTRY=$(get_entry "$D")
  [ -z "$ENTRY" ] && continue
  RECORD_DAYS=$((RECORD_DAYS + 1))

  # Get score from summary
  SK=$(echo "$D" | cut -c1-7)
  SUMMARY=$(curl -s "$BASE/summary:$SK" -H "Authorization: Bearer $FB_TOKEN" | jq -r '.fields.value.stringValue // empty' 2>/dev/null)
  SC=$(echo "$SUMMARY" | jq -r ".\"$D\".total // empty" 2>/dev/null)

  if [ -n "$SC" ]; then
    SCORES+=("$SC")
    [ "$SC" -gt "$BEST_SCORE" ] && BEST_SCORE=$SC && BEST_DATE=$D
    [ "$SC" -lt "$WORST_SCORE" ] && WORST_SCORE=$SC && WORST_DATE=$D
  fi

  # Morning
  MLV=$(echo "$ENTRY" | jq -r '.morning.level // empty')
  if [ -n "$MLV" ]; then
    MORNING_SUM=$((MORNING_SUM + MLV))
    MORNING_COUNT=$((MORNING_COUNT + 1))
  fi

  # Evening
  ELV=$(echo "$ENTRY" | jq -r '.evening.level // empty')
  if [ -n "$ELV" ]; then
    EVENING_SUM=$((EVENING_SUM + ELV))
    EVENING_COUNT=$((EVENING_COUNT + 1))
  fi

  # Exercise
  EX=$(echo "$ENTRY" | jq '[.events[] | select(.type=="exercise") | (.duration // 0)] | add // 0')
  HAS_EX=false
  if [ "$EX" -gt 0 ]; then
    EX_DAYS=$((EX_DAYS + 1))
    HAS_EX=true
  fi

  # Track exercise vs score correlation
  if [ -n "$SC" ]; then
    if [ "$HAS_EX" = true ]; then
      EX_SCORE_SUM=$((EX_SCORE_SUM + SC))
      EX_SCORE_COUNT=$((EX_SCORE_COUNT + 1))
    else
      NO_EX_SCORE_SUM=$((NO_EX_SCORE_SUM + SC))
      NO_EX_SCORE_COUNT=$((NO_EX_SCORE_COUNT + 1))
    fi
  fi

  # Meditation
  MED=$(echo "$ENTRY" | jq '[.events[] | select(.type=="meditation") | (.duration // 0)] | add // 0')
  [ "$MED" -gt 0 ] && MED_DAYS=$((MED_DAYS + 1))

  # Meals
  MC=$(echo "$ENTRY" | jq '[.events[] | select(.type=="meal")] | length')
  TOTAL_MEALS=$((TOTAL_MEALS + MC))

  # Hydration
  HYD=$(echo "$ENTRY" | jq '[.events[] | select(.type=="hydration") | (.amountMl // 0)] | add // 0')
  TOTAL_HYD=$((TOTAL_HYD + HYD))

  # Bathroom
  BC=$(echo "$ENTRY" | jq '[.events[] | select(.type=="bathroom")] | length')
  [ "$BC" -gt 0 ] && BATH_DAYS=$((BATH_DAYS + 1))

  # Sleep
  WAKE=$(echo "$ENTRY" | jq -r '.morning.wakeTime // empty')
  PREV_ENTRY=$(get_entry "$PREV_D")
  PBED=$(echo "$PREV_ENTRY" | jq -r '.evening.bedTime // empty' 2>/dev/null)
  if [ -n "$WAKE" ] && [ -n "$PBED" ]; then
    BH=$(echo "$PBED" | cut -d: -f1 | sed 's/^0//'); BM=$(echo "$PBED" | cut -d: -f2 | sed 's/^0//')
    WH=$(echo "$WAKE" | cut -d: -f1 | sed 's/^0//'); WM=$(echo "$WAKE" | cut -d: -f2 | sed 's/^0//')
    BMIN=$((BH*60+BM)); WMIN=$((WH*60+WM))
    [ $BMIN -gt $WMIN ] && SMIN=$((1440-BMIN+WMIN)) || SMIN=$((WMIN-BMIN))
    TOTAL_SLEEP=$((TOTAL_SLEEP + SMIN))
    SLEEP_COUNT=$((SLEEP_COUNT + 1))
  fi

  # Period
  PER=$(echo "$ENTRY" | jq -r '.morning.period // false')
  if [ "$PER" = "true" ]; then
    DD=$(echo "$D" | sed 's/.*-//' | sed 's/^0//')
    PERIOD_DATES="${PERIOD_DATES}${DD}일 "
  fi
done

# Calculate averages
if [ ${#SCORES[@]} -eq 0 ]; then
  send_telegram "🌿 BALANCE 위클리 — ${MON_M}/${MON_D}~${SUN_M}/${SUN_D}

이번 주 기록이 없습니다. 다음 주에는 매일 체크인 해보세요! 💪"
  exit 0
fi

AVG_SCORE=$(( ($(IFS=+; echo "${SCORES[*]}" | bc)) / ${#SCORES[@]} ))

MSG="🌿 BALANCE 위클리 — ${MON_M}/${MON_D}~${SUN_M}/${SUN_D}

📈 주간 평균: ${AVG_SCORE}점
   기록: ${RECORD_DAYS}/7일
"

if [ -n "$BEST_DATE" ]; then
  BD=$(echo "$BEST_DATE" | sed 's/.*-//' | sed 's/^0//')
  BDOW=$(dow_kr "$BEST_DATE")
  MSG="${MSG}
🏆 가장 좋았던 날: ${BD}일(${BDOW}) ${BEST_SCORE}점"
fi

if [ -n "$WORST_DATE" ] && [ "$WORST_DATE" != "$BEST_DATE" ]; then
  WD=$(echo "$WORST_DATE" | sed 's/.*-//' | sed 's/^0//')
  WDOW=$(dow_kr "$WORST_DATE")
  MSG="${MSG}
😥 가장 낮았던 날: ${WD}일(${WDOW}) ${WORST_SCORE}점"
fi

MSG="${MSG}

📋 항목별 요약"

if [ $MORNING_COUNT -gt 0 ]; then
  MAVG=$(awk "BEGIN{printf \"%.1f\", $MORNING_SUM/$MORNING_COUNT}")
  MSG="${MSG}
🌤️ 아침: ${MAVG}/5"
fi
if [ $EVENING_COUNT -gt 0 ]; then
  EAVG=$(awk "BEGIN{printf \"%.1f\", $EVENING_SUM/$EVENING_COUNT}")
  MSG="${MSG}
🌙 저녁: ${EAVG}/5"
fi
if [ $SLEEP_COUNT -gt 0 ]; then
  SAVG=$(awk "BEGIN{printf \"%.1f\", $TOTAL_SLEEP/$SLEEP_COUNT/60}")
  MSG="${MSG}
😴 수면: 평균 ${SAVG}h"
fi
if [ $RECORD_DAYS -gt 0 ]; then
  MEAL_AVG=$(awk "BEGIN{printf \"%.1f\", $TOTAL_MEALS/$RECORD_DAYS}")
  MSG="${MSG}
🍽️ 식사: 평균 ${MEAL_AVG}회/일"
  if [ $TOTAL_HYD -gt 0 ]; then
    HYD_AVG=$(awk "BEGIN{printf \"%.1f\", $TOTAL_HYD/$RECORD_DAYS/1000}")
    MSG="${MSG}
💧 수분: 평균 ${HYD_AVG}L/일"
  fi
fi

MSG="${MSG}
💪 운동: ${EX_DAYS}/7일
🧘 명상: ${MED_DAYS}/7일
🚽 화장실: ${BATH_DAYS}/7일"

[ -n "$PERIOD_DATES" ] && MSG="${MSG}

🩸 생리: ${PERIOD_DATES}"

# Correlation insights
MSG="${MSG}

🔗 컨디션 연결고리"
if [ $EX_SCORE_COUNT -gt 0 ] && [ $NO_EX_SCORE_COUNT -gt 0 ]; then
  EX_AVG=$((EX_SCORE_SUM / EX_SCORE_COUNT))
  NO_EX_AVG=$((NO_EX_SCORE_SUM / NO_EX_SCORE_COUNT))
  MSG="${MSG}
• 운동한 날 평균 ${EX_AVG}점 vs 안 한 날 ${NO_EX_AVG}점"
fi

# Simple insight
if [ $RECORD_DAYS -lt 4 ]; then
  MSG="${MSG}

💡 이번 주 기록이 ${RECORD_DAYS}일뿐이에요. 매일 체크인하면 더 정확한 패턴 분석이 가능해요!"
elif [ $AVG_SCORE -ge 75 ]; then
  MSG="${MSG}

💡 좋은 한 주였어요! 이 리듬을 유지해보세요 ✨"
else
  MSG="${MSG}

💡 다음 주는 가장 약한 항목에 조금 더 신경 써보세요."
fi

send_telegram "$MSG"
echo "Weekly report sent for $PREV_MON ~ $PREV_SUN"
