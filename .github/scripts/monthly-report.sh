#!/bin/bash
set -euo pipefail

FUID="uoU98EFYUuNwHHen9CtDoT6BRgL2"
PROJECT="balance-408f1"
BASE="https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/users/$FUID/data"

send_telegram() {
  local payload=$(jq -n --arg chat "$TG_CHAT" --arg text "$1" '{chat_id: ($chat|tonumber), text: $text}')
  curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -H "Content-Type: application/json; charset=utf-8" -d "$payload" > /dev/null
}

call_claude() {
  local prompt="$1"
  local max_tokens="${2:-500}"
  curl -s -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg p "$prompt" --argjson mt "$max_tokens" '{
      model: "claude-haiku-4-5-20251001",
      max_tokens: $mt,
      messages: [{role: "user", content: $p}]
    }')" 2>/dev/null | jq -r '.content[0].text // empty' 2>/dev/null || true
}

# Previous month
PREV_YEAR=$(TZ=Asia/Seoul date -d "last month" +%Y)
PREV_MONTH=$(TZ=Asia/Seoul date -d "last month" +%m)
PREV_MONTH_NUM=$(echo "$PREV_MONTH" | sed 's/^0//')
LAST_DAY=$(TZ=Asia/Seoul date -d "$PREV_YEAR-$PREV_MONTH-01 + 1 month - 1 day" +%d)
SUMMARY_KEY="${PREV_YEAR}-${PREV_MONTH}"

# Get monthly summary
SUMMARY_RAW=$(curl -s "$BASE/summary:$SUMMARY_KEY" -H "Authorization: Bearer $FB_TOKEN" | jq -r '.fields.value.stringValue // empty' 2>/dev/null)

if [ -z "$SUMMARY_RAW" ]; then
  send_telegram "🌿 BALANCE 먼슬리 — ${PREV_YEAR}년 ${PREV_MONTH_NUM}월

기록이 없습니다. 이번 달부터 매일 체크인 시작해보세요! 💪"
  exit 0
fi

# Parse all day scores from summary
SCORES=()
BEST_SCORE=0; BEST_DATE=""; BEST2_SCORE=0; BEST2_DATE=""; BEST3_SCORE=0; BEST3_DATE=""
RECORD_DAYS=0
WEEK1=0; W1C=0; WEEK2=0; W2C=0; WEEK3=0; W3C=0; WEEK4=0; W4C=0

for d in $(seq 1 $((10#$LAST_DAY))); do
  DD=$(printf "%02d" $d)
  KEY="${PREV_YEAR}-${PREV_MONTH}-${DD}"
  SC=$(echo "$SUMMARY_RAW" | jq -r ".\"$KEY\".total // empty" 2>/dev/null)
  [ -z "$SC" ] && continue

  RECORD_DAYS=$((RECORD_DAYS + 1))
  SCORES+=("$SC")

  # Weekly buckets
  if [ $d -le 7 ]; then WEEK1=$((WEEK1+SC)); W1C=$((W1C+1))
  elif [ $d -le 14 ]; then WEEK2=$((WEEK2+SC)); W2C=$((W2C+1))
  elif [ $d -le 21 ]; then WEEK3=$((WEEK3+SC)); W3C=$((W3C+1))
  else WEEK4=$((WEEK4+SC)); W4C=$((W4C+1)); fi

  # Top 3
  if [ "$SC" -gt "$BEST_SCORE" ]; then
    BEST3_SCORE=$BEST2_SCORE; BEST3_DATE=$BEST2_DATE
    BEST2_SCORE=$BEST_SCORE; BEST2_DATE=$BEST_DATE
    BEST_SCORE=$SC; BEST_DATE=$KEY
  elif [ "$SC" -gt "$BEST2_SCORE" ]; then
    BEST3_SCORE=$BEST2_SCORE; BEST3_DATE=$BEST2_DATE
    BEST2_SCORE=$SC; BEST2_DATE=$KEY
  elif [ "$SC" -gt "$BEST3_SCORE" ]; then
    BEST3_SCORE=$SC; BEST3_DATE=$KEY
  fi
done

if [ ${#SCORES[@]} -eq 0 ]; then
  send_telegram "🌿 BALANCE 먼슬리 — ${PREV_YEAR}년 ${PREV_MONTH_NUM}월

점수 기록이 없습니다."
  exit 0
fi

AVG=$(( ($(IFS=+; echo "${SCORES[*]}" | bc)) / ${#SCORES[@]} ))
PCT=$((RECORD_DAYS * 100 / 10#$LAST_DAY))

# Previous month comparison
PREV2_YEAR=$PREV_YEAR
PREV2_MONTH=$((10#$PREV_MONTH - 1))
if [ $PREV2_MONTH -eq 0 ]; then
  PREV2_MONTH=12; PREV2_YEAR=$((PREV_YEAR - 1))
fi
PREV2_KEY=$(printf "%04d-%02d" $PREV2_YEAR $PREV2_MONTH)
PREV2_RAW=$(curl -s "$BASE/summary:$PREV2_KEY" -H "Authorization: Bearer $FB_TOKEN" | jq -r '.fields.value.stringValue // empty' 2>/dev/null)
PREV_AVG=""
if [ -n "$PREV2_RAW" ]; then
  PREV_SCORES=()
  for d in $(seq 1 31); do
    DD=$(printf "%02d" $d)
    PSC=$(echo "$PREV2_RAW" | jq -r ".\"$PREV2_KEY-$DD\".total // empty" 2>/dev/null)
    [ -n "$PSC" ] && PREV_SCORES+=("$PSC")
  done
  if [ ${#PREV_SCORES[@]} -gt 0 ]; then
    PREV_AVG=$(( ($(IFS=+; echo "${PREV_SCORES[*]}" | bc)) / ${#PREV_SCORES[@]} ))
  fi
fi

# Build message
MSG="🌿 BALANCE 먼슬리 — ${PREV_YEAR}년 ${PREV_MONTH_NUM}월

📈 월 평균: ${AVG}점"

if [ -n "$PREV_AVG" ]; then
  DIFF=$((AVG - PREV_AVG))
  if [ $DIFF -ge 0 ]; then
    MSG="${MSG}
   전월 대비: +${DIFF}점 ▲"
  else
    MSG="${MSG}
   전월 대비: ${DIFF}점 ▼"
  fi
fi

MSG="${MSG}
   기록률: ${RECORD_DAYS}/${LAST_DAY}일 (${PCT}%)"

# Weekly trend
MSG="${MSG}

📊 주차별 추이"
[ $W1C -gt 0 ] && MSG="${MSG}
1주: $((WEEK1/W1C))점" || MSG="${MSG}
1주: -"
[ $W2C -gt 0 ] && MSG="${MSG} → 2주: $((WEEK2/W2C))점" || MSG="${MSG} → 2주: -"
[ $W3C -gt 0 ] && MSG="${MSG} → 3주: $((WEEK3/W3C))점" || MSG="${MSG} → 3주: -"
[ $W4C -gt 0 ] && MSG="${MSG} → 4주: $((WEEK4/W4C))점" || MSG="${MSG} → 4주: -"

# Best 3
MSG="${MSG}

🏆 BEST 3일"
fmt_best() {
  local dt=$1 sc=$2
  [ -z "$dt" ] && return
  local dd=$(echo "$dt" | sed 's/.*-//' | sed 's/^0//')
  echo "${dd}일(${sc}점)"
}
BEST_LINE=$(fmt_best "$BEST_DATE" "$BEST_SCORE")
[ -n "$BEST2_DATE" ] && BEST_LINE="${BEST_LINE} / $(fmt_best "$BEST2_DATE" "$BEST2_SCORE")"
[ -n "$BEST3_DATE" ] && BEST_LINE="${BEST_LINE} / $(fmt_best "$BEST3_DATE" "$BEST3_SCORE")"
MSG="${MSG}
${BEST_LINE}"

# Detailed analysis from entries
EX_DAYS=0; MED_DAYS=0; BATH_DAYS=0; PERIOD_DAYS=0
TOTAL_SLEEP=0; SLEEP_C=0
TOTAL_MEALS=0; TOTAL_HYD=0
M_SUM=0; M_C=0; E_SUM=0; E_C=0
EX_SC_SUM=0; EX_SC_C=0; NO_EX_SC_SUM=0; NO_EX_SC_C=0

# 텍스트 분석용 — 감정, 식사, 메모 누적
MONTH_EMOTIONS=""
MONTH_MEAL_LABELS=""
MONTH_NOTES=""
ENTRY_COUNT=0

# Read all entries for the month
ALL_ENTRIES=$(curl -s "$BASE?pageSize=50" -H "Authorization: Bearer $FB_TOKEN" | jq -r '.documents[]? | select(.name | contains("entry:'$SUMMARY_KEY'")) | .fields.value.stringValue' 2>/dev/null)

while IFS= read -r ENTRY; do
  [ -z "$ENTRY" ] && continue
  DT=$(echo "$ENTRY" | jq -r '.date // empty')
  [ -z "$DT" ] && continue

  ENTRY_COUNT=$((ENTRY_COUNT + 1))

  MLV=$(echo "$ENTRY" | jq -r '.morning.level // empty')
  [ -n "$MLV" ] && { M_SUM=$((M_SUM+MLV)); M_C=$((M_C+1)); }

  ELV=$(echo "$ENTRY" | jq -r '.evening.level // empty')
  [ -n "$ELV" ] && { E_SUM=$((E_SUM+ELV)); E_C=$((E_C+1)); }

  EX=$(echo "$ENTRY" | jq '[.events[]? | select(.type=="exercise") | (.duration // 0)] | add // 0')
  MC=$(echo "$ENTRY" | jq '[.events[]? | select(.type=="meal")] | length')
  HYD=$(echo "$ENTRY" | jq '[.events[]? | select(.type=="hydration") | (.amountMl // 0)] | add // 0')
  MED=$(echo "$ENTRY" | jq '[.events[]? | select(.type=="meditation") | (.duration // 0)] | add // 0')
  BC=$(echo "$ENTRY" | jq '[.events[]? | select(.type=="bathroom")] | length')
  PER=$(echo "$ENTRY" | jq -r '.morning.period // false')

  [ "$EX" -gt 0 ] && EX_DAYS=$((EX_DAYS+1))
  [ "$MED" -gt 0 ] && MED_DAYS=$((MED_DAYS+1))
  [ "$BC" -gt 0 ] && BATH_DAYS=$((BATH_DAYS+1))
  [ "$PER" = "true" ] && PERIOD_DAYS=$((PERIOD_DAYS+1))
  TOTAL_MEALS=$((TOTAL_MEALS+MC))
  TOTAL_HYD=$((TOTAL_HYD+HYD))

  SC=$(echo "$SUMMARY_RAW" | jq -r ".\"$DT\".total // empty" 2>/dev/null)
  if [ -n "$SC" ]; then
    if [ "$EX" -gt 0 ]; then
      EX_SC_SUM=$((EX_SC_SUM+SC)); EX_SC_C=$((EX_SC_C+1))
    else
      NO_EX_SC_SUM=$((NO_EX_SC_SUM+SC)); NO_EX_SC_C=$((NO_EX_SC_C+1))
    fi
  fi

  # 텍스트 수집
  EMOTIONS=$(echo "$ENTRY" | jq -r '[.events[]? | select(.type=="emotion") | .name // ""] | join(", ")')
  MLABELS=$(echo "$ENTRY" | jq -r '[.events[]? | select(.type=="meal" and .label != null and .label != "") | .label] | join(", ")')
  MNOTE=$(echo "$ENTRY" | jq -r '.morning.note // empty')
  ENOTE=$(echo "$ENTRY" | jq -r '.evening.note // empty')

  DD_NUM=$(echo "$DT" | sed 's/.*-//' | sed 's/^0//')
  [ -n "$EMOTIONS" ] && MONTH_EMOTIONS="${MONTH_EMOTIONS}${DD_NUM}일:${EMOTIONS} "
  [ -n "$MLABELS" ] && MONTH_MEAL_LABELS="${MONTH_MEAL_LABELS}${DD_NUM}일:${MLABELS} "
  [ -n "$MNOTE" ] && MONTH_NOTES="${MONTH_NOTES}${DD_NUM}일(아침):${MNOTE} "
  [ -n "$ENOTE" ] && MONTH_NOTES="${MONTH_NOTES}${DD_NUM}일(저녁):${ENOTE} "
done <<< "$ALL_ENTRIES"

MSG="${MSG}

📋 항목별 월평균"
[ $M_C -gt 0 ] && MSG="${MSG}
🌤️ 아침: $(awk "BEGIN{printf \"%.1f\", $M_SUM/$M_C}")/5"
[ $E_C -gt 0 ] && MSG="${MSG}
🌙 저녁: $(awk "BEGIN{printf \"%.1f\", $E_SUM/$E_C}")/5"
[ $SLEEP_C -gt 0 ] && MSG="${MSG}
😴 수면: 평균 $(awk "BEGIN{printf \"%.1f\", $TOTAL_SLEEP/$SLEEP_C/60}")h"
[ $RECORD_DAYS -gt 0 ] && MSG="${MSG}
🍽️ 식사: 평균 $(awk "BEGIN{printf \"%.1f\", $TOTAL_MEALS/$RECORD_DAYS}")회/일"
[ $TOTAL_HYD -gt 0 ] && MSG="${MSG}
💧 수분: 평균 $(awk "BEGIN{printf \"%.1f\", $TOTAL_HYD/$RECORD_DAYS/1000}")L/일"
MSG="${MSG}
💪 운동: ${EX_DAYS}/${LAST_DAY}일
🧘 명상: ${MED_DAYS}/${LAST_DAY}일
🚽 화장실: ${BATH_DAYS}/${LAST_DAY}일"

[ $PERIOD_DAYS -gt 0 ] && MSG="${MSG}

🩸 생리: 총 ${PERIOD_DAYS}일"

# 패턴
MSG="${MSG}

🔍 패턴 발견"
if [ $EX_SC_C -gt 0 ] && [ $NO_EX_SC_C -gt 0 ]; then
  EX_AVG=$((EX_SC_SUM/EX_SC_C))
  NO_EX_AVG=$((NO_EX_SC_SUM/NO_EX_SC_C))
  MSG="${MSG}
• 운동한 날(${EX_DAYS}일) 평균 ${EX_AVG}점 vs 안 한 날 ${NO_EX_AVG}점"
fi

if [ $RECORD_DAYS -lt $((10#$LAST_DAY / 2)) ]; then
  MSG="${MSG}
• 기록률이 ${PCT}%로 낮아요. 꾸준한 기록이 패턴 발견의 핵심!"
fi

# 다음 달 포인트
MSG="${MSG}

💡 다음 달 포인트"
if [ $TOTAL_HYD -eq 0 ]; then
  MSG="${MSG}
1. 수분 섭취를 기록해보세요"
elif [ $RECORD_DAYS -gt 0 ]; then
  HYD_AVG_ML=$((TOTAL_HYD / RECORD_DAYS))
  [ $HYD_AVG_ML -lt 1500 ] && MSG="${MSG}
1. 수분 목표(1.5L) 달성률 높이기"
fi
[ $EX_DAYS -lt 10 ] && MSG="${MSG}
2. 운동 빈도 늘리기 (현재 월 ${EX_DAYS}일)"

# Claude 월간 총평 (텍스트 기록이 있을 때만)
if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ $ENTRY_COUNT -gt 0 ]; then
  SLEEP_AVG_TEXT=""
  [ $SLEEP_C -gt 0 ] && SLEEP_AVG_TEXT=$(awk "BEGIN{printf \"%.1f\", $TOTAL_SLEEP/$SLEEP_C/60}")

  CLAUDE_PROMPT="당신은 건강 기록 분석가예요. 아래는 ${PREV_MONTH_NUM}월 한 달간의 기록이에요.

[수치 요약]
월 평균 점수: ${AVG}점 (${RECORD_DAYS}/${LAST_DAY}일 기록)
아침 컨디션 평균: $([ $M_C -gt 0 ] && awk "BEGIN{printf \"%.1f\", $M_SUM/$M_C}" || echo "없음")/5
평균 수면: ${SLEEP_AVG_TEXT:-없음}시간
운동: ${EX_DAYS}일 | 명상: ${MED_DAYS}일 | 생리: ${PERIOD_DAYS}일

[감정 기록]
${MONTH_EMOTIONS:-없음}

[식사 기록]
${MONTH_MEAL_LABELS:-없음}

[아침·저녁 메모]
${MONTH_NOTES:-없음}

위 한 달 기록을 보고:
1. 이번 달에 반복된 패턴 (긍정적/부정적 모두)
2. 텍스트에서 보이는 신체·감정 신호
3. 다음 달에 집중할 한 가지

를 한국어로 4-5문장으로 써줘. 수치보다 텍스트와 패턴에 집중하고, 구체적으로."

  AI_INSIGHT=$(call_claude "$CLAUDE_PROMPT" 500)

  if [ -n "$AI_INSIGHT" ]; then
    MSG="${MSG}

🤖 이번 달 기록에서
${AI_INSIGHT}"
  fi
fi

send_telegram "$MSG"
echo "Monthly report sent for ${PREV_YEAR}-${PREV_MONTH}"
