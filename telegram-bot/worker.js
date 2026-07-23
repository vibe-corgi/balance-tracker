// Balance Tracker - Telegram Bot (Cloudflare Worker)
const FUID = "uoU98EFYUuNwHHen9CtDoT6BRgL2";
const PROJECT = "balance-408f1";
const SERVICE_ACCOUNT = "firebase-adminsdk-fbsvc@balance-408f1.iam.gserviceaccount.com";
const BASE_URL = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/users/${FUID}/data`;

function bytesToBase64url(buffer) {
  const bytes = new Uint8Array(buffer instanceof ArrayBuffer ? buffer : buffer.buffer);
  let str = "";
  for (let i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i]);
  return btoa(str).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function strToBase64url(str) { return bytesToBase64url(new TextEncoder().encode(str)); }

async function getFirebaseToken(privateKeyPem) {
  const pemContents = privateKeyPem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const binaryStr = atob(pemContents);
  const keyBytes = new Uint8Array(binaryStr.length);
  for (let i = 0; i < binaryStr.length; i++) keyBytes[i] = binaryStr.charCodeAt(i);
  const key = await crypto.subtle.importKey(
    "pkcs8", keyBytes.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]
  );
  const now = Math.floor(Date.now() / 1000);
  const header = strToBase64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = strToBase64url(JSON.stringify({
    iss: SERVICE_ACCOUNT,
    scope: "https://www.googleapis.com/auth/datastore",
    aud: "https://oauth2.googleapis.com/token",
    iat: now, exp: now + 3600,
  }));
  const signingInput = `${header}.${payload}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput));
  const jwt = `${signingInput}.${bytesToBase64url(signature)}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
  });
  return (await res.json()).access_token;
}

async function getEntry(date, token) {
  const key = encodeURIComponent(`entry:${date}`);
  const res = await fetch(`${BASE_URL}/${key}`, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) return { morning: null, evening: null, events: [] };
  const value = (await res.json())?.fields?.value?.stringValue;
  try {
    const p = JSON.parse(value);
    if (!p.events) p.events = [];
    return p;
  } catch { return { morning: null, evening: null, events: [] }; }
}

async function setEntry(date, entry, token) {
  const key = encodeURIComponent(`entry:${date}`);
  await fetch(`${BASE_URL}/${key}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ fields: { value: { stringValue: JSON.stringify(entry) } } }),
  });
}

async function sendTelegram(tgToken, chatId, text) {
  await fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: parseInt(chatId), text }),
  });
}

function kstDate() { return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10); }
function kstTime() { return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(11, 16); }
function kstYesterday() { const d = new Date(Date.now() + 9 * 3600 * 1000); d.setDate(d.getDate() - 1); return d.toISOString().slice(0, 10); }

function parseMessage(text, now) {
  const trimmed = text.trim();
  const firstSpace = trimmed.indexOf(" ");
  const rawFirst = firstSpace === -1 ? trimmed : trimmed.slice(0, firstSpace);
  const afterFirst = firstSpace === -1 ? "" : trimmed.slice(firstSpace + 1).trim();
  const dashIdx = rawFirst.indexOf("-");
  const category = dashIdx === -1 ? rawFirst : rawFirst.slice(0, dashIdx);
  const subTag = dashIdx === -1 ? "" : rawFirst.slice(dashIdx + 1);
  const allRest = [subTag, afterFirst].filter(Boolean).join(" ");
  const words = allRest ? allRest.split(/\s+/).filter(Boolean) : [];

  const timePattern = /^\d{1,2}:\d{2}$/;
  let timeVal = null, timeIdx = -1, levelVal = null, levelIdx = -1, bigNumVal = null, bigNumIdx = -1;
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    if (timePattern.test(w) && timeVal === null) { timeVal = w; timeIdx = i; continue; }
    const n = parseInt(w);
    if (!isNaN(n) && String(n) === w) {
      if (n >= 1 && n <= 5 && levelVal === null) { levelVal = n; levelIdx = i; }
      else if (n > 5) { bigNumVal = n; bigNumIdx = i; }
    }
  }

  const used = new Set();
  const mark = (...idxs) => idxs.forEach(i => { if (i !== -1) used.add(i); });
  const restText = () => words.filter((_, i) => !used.has(i)).join(" ");
  const findWord = (...targets) => {
    const idx = words.findIndex(w => targets.includes(w));
    if (idx !== -1) used.add(idx);
    return idx;
  };
  const yesterdayIdx = findWord("어제");
  const useYesterday = yesterdayIdx !== -1;

  switch (category) {
    case "아침": {
      mark(levelIdx, timeIdx);
      const periodIdx = findWord("생리중", "생리");
      const stretchIdx = findWord("스트레칭");
      const saltIdx = findWord("소금가글", "소금");
      const morningRoutineIdx = findWord("아침디톡스", "디톡스");
      const note = restText();
      return {
        type: "morning",
        update: {
          ...(levelVal !== null && { level: levelVal }),
          ...(timeVal !== null && { wakeTime: timeVal }),
          ...(periodIdx !== -1 && { period: true }),
          ...(stretchIdx !== -1 && { stretch: true }),
          ...(saltIdx !== -1 && { saltGargle: true }),
          ...(morningRoutineIdx !== -1 && { morningRoutine: true }),
          ...(note && { note }),
        },
        reply: ["✅ 아침 체크인 저장",
          levelVal !== null ? `컨디션 ${levelVal}/5` : null,
          timeVal ? `기상 ${timeVal}` : null,
          periodIdx !== -1 ? "🩸생리중" : null,
          stretchIdx !== -1 ? "🤸스트레칭" : null,
          saltIdx !== -1 ? "🧂소금가글" : null,
          morningRoutineIdx !== -1 ? "📵아침디톡스" : null,
          note || null,
        ].filter(Boolean).join(" · "),
      };
    }

    case "저녁": {
      mark(levelIdx, timeIdx);
      const stretchIdx = findWord("스트레칭");
      const eveningRoutineIdx = findWord("저녁디톡스", "디톡스");
      const note = restText();
      const isAfterMidnight = timeVal && parseInt(timeVal.split(":")[0]) < 6;
      return {
        type: "evening",
        useYesterday: yesterdayIdx !== -1,
        update: {
          ...(levelVal !== null && { level: levelVal }),
          ...(timeVal !== null && { bedTime: timeVal }),
          ...(yesterdayIdx !== -1 && isAfterMidnight && { bedNextDay: true }),
          ...(stretchIdx !== -1 && { stretch: true }),
          ...(eveningRoutineIdx !== -1 && { eveningRoutine: true }),
          ...(note && { note }),
        },
        reply: ["✅ 저녁 체크인 저장",
          yesterdayIdx !== -1 ? "📅 어제 날짜로 저장" : null,
          levelVal !== null ? `컨디션 ${levelVal}/5` : null,
          timeVal ? `취침 ${timeVal}` : null,
          stretchIdx !== -1 ? "🤸스트레칭" : null,
          eveningRoutineIdx !== -1 ? "📵저녁디톡스" : null,
          note || null,
        ].filter(Boolean).join(" · "),
      };
    }

    case "수분": {
      mark(bigNumIdx, timeIdx);
      const t = timeVal || now;
      const hydTypeMap = [
        { keys: ["물"], type: "water", name: "물" },
        { keys: ["차", "녹차", "보이차", "허브차", "홍차", "루이보스"], type: "tea", name: "차" },
        { keys: ["커피", "아메리카노", "라떼", "에스프레소"], type: "coffee", name: "커피" },
        { keys: ["음료", "우유", "두유", "귀리", "오트"], type: "milk", name: "음료" },
        { keys: ["시판", "이온음료", "주스", "과일주스", "에이드"], type: "commercial", name: "시판" },
        { keys: ["건강", "건강음료"], type: "health", name: "건강음료" },
        { keys: ["술", "맥주", "와인", "소주", "막걸리"], type: "alcohol", name: "술" },
      ];
      let hydType = "water", hydName = "물";
      for (const { keys, type, name } of hydTypeMap) {
        if (findWord(...keys) !== -1) { hydType = type; hydName = name; break; }
      }
      const isWaterTea = hydType === "water" || hydType === "tea";
      const isHealth = hydType === "health";
      if (isHealth && levelVal !== null) mark(levelIdx);
      const label = restText() || null;
      return {
        type: "event",
        event: {
          type: "hydration", time: t, hydType,
          ...(label && { label }),
          ...(isWaterTea && bigNumVal !== null && { amountMl: bigNumVal }),
          ...(isHealth && levelVal !== null && { cups: levelVal }),
        },
        reply: `✅ 수분 저장 · ${hydName}${label ? ` ${label}` : ""}${isHealth && levelVal ? ` ${levelVal}잔` : isWaterTea && bigNumVal ? ` ${bigNumVal}ml` : ""} · ${t}`,
      };
    }

    case "식사": {
      mark(timeIdx);
      const t = timeVal || now;
      const mealKeywords = new Set(["아침", "점심", "저녁", "간식", "야식", "브런치"]);
      let mealType = "";
      const mealTypeIdx = words.findIndex(w => mealKeywords.has(w));
      if (mealTypeIdx !== -1) { mealType = words[mealTypeIdx]; used.add(mealTypeIdx); }
      const feelMap = { "클린": "클린", "보통": "보통", "정크": "정크", "폭식": "폭식" };
      const hungerMap = { "배고팠음": "🌟 배고팠음", "배고픔": "🌟 배고팠음", "그냥먹음": "😐 그냥먹음", "그냥": "😐 그냥먹음", "안배고픔": "😞 안배고픔", "안배고팠음": "😞 안배고픔" };
      let feel = null, hunger = null;
      const feelIdx = words.findIndex(w => feelMap[w]);
      if (feelIdx !== -1) { feel = feelMap[words[feelIdx]]; used.add(feelIdx); }
      const hungerIdx = words.findIndex(w => hungerMap[w]);
      if (hungerIdx !== -1) { hunger = hungerMap[words[hungerIdx]]; used.add(hungerIdx); }
      const snack = mealType === "간식";
      const label = restText();
      return {
        type: "event", useYesterday,
        event: { type: "meal", time: t, ...(mealType && { mealType }), ...(label && { label }), ...(feel && { feel }), ...(hunger && { hunger }), ...(snack && { snack }) },
        reply: `✅ 식사 저장 · ${[mealType, label].filter(Boolean).join(" ") || "식사"}${feel ? ` · ${feel}` : ""}${hunger ? ` · ${hunger}` : ""}${snack ? " · 🍬 간식" : ""}${useYesterday ? " · 📅 어제" : ""} · ${t}`,
      };
    }

    case "운동": {
      mark(bigNumIdx, timeIdx);
      const t = timeVal || now;
      const exTypeList = ["달리기", "산책", "요가", "스트레칭", "근력운동"];
      const foundExTypes = exTypeList.filter(et => findWord(et) !== -1);
      const memo = restText();
      return {
        type: "event", useYesterday,
        event: { type: "exercise", time: t, ...(bigNumVal !== null && { duration: bigNumVal }), ...(memo && { memo }), ...(foundExTypes.length > 0 && { exTypes: foundExTypes }) },
        reply: `✅ 운동 저장 · ${foundExTypes.length ? foundExTypes.join(", ") : memo || "운동"}${bigNumVal ? ` ${bigNumVal}분` : ""}${useYesterday ? " · 📅 어제" : ""} · ${t}`,
      };
    }

    case "활동": {
      mark(bigNumIdx, timeIdx);
      const t = timeVal || now;
      const coldShowerIdx = findWord("찬물샤워", "찬샤워");
      const label = restText();
      return {
        type: "event", useYesterday,
        event: { type: "activity", time: t, ...(bigNumVal !== null && { duration: bigNumVal }), ...(coldShowerIdx !== -1 && { coldShower: true }), ...(label && { label }) },
        reply: `✅ 활동 저장 · ${coldShowerIdx !== -1 ? "🚿찬물샤워" : label || "활동"}${bigNumVal ? ` ${bigNumVal}분` : ""}${useYesterday ? " · 📅 어제" : ""} · ${t}`,
      };
    }

    case "명상": {
      mark(bigNumIdx, timeIdx);
      const lotusIdx = findWord("결가부좌");
      const mantraIdx = findWord("진언", "만트라");
      const t = timeVal || now;
      const dur = bigNumVal ?? null;
      return {
        type: "event", useYesterday,
        event: { type: "meditation", time: t, ...(dur !== null && { duration: dur }), ...(lotusIdx !== -1 && { lotus: true }), ...(mantraIdx !== -1 && { mantra: true }) },
        reply: `✅ 명상 저장${dur ? ` · ${dur}분` : ""}${lotusIdx !== -1 ? " · 🧘 결가부좌" : ""}${mantraIdx !== -1 ? " · 🔔 진언/만트라" : ""}${useYesterday ? " · 📅 어제" : ""} · ${t}`,
      };
    }

    case "휴식": {
      mark(bigNumIdx, timeIdx);
      const napIdx = findWord("수면", "낮잠");
      const zoneOutIdx = findWord("멍때리기", "멍때림");
      const t = timeVal || now;
      const dur = bigNumVal ?? null;
      return {
        type: "event", useYesterday,
        event: { type: "rest", time: t, ...(dur !== null && { duration: dur }), ...(napIdx !== -1 && { nap: true }), ...(zoneOutIdx !== -1 && { zoneOut: true }) },
        reply: `✅ 휴식 저장${dur ? ` · ${dur}분` : ""}${napIdx !== -1 ? " · 😴 수면" : ""}${zoneOutIdx !== -1 ? " · 🌀 멍때리기" : ""}${useYesterday ? " · 📅 어제" : ""} · ${t}`,
      };
    }

    case "감정": {
      mark(timeIdx);
      const t = timeVal || now;
      const name = subTag || (words.length > 0 ? words[0] : "");
      if (!subTag && words.length > 0) used.add(0);
      const memo = restText();
      return {
        type: "event", useYesterday,
        event: { type: "emotion", time: t, ...(name && { name }), ...(memo && { memo }) },
        reply: `✅ 감정 저장 · ${name || "감정"}${memo ? ` · ${memo}` : ""}${useYesterday ? " · 📅 어제" : ""} · ${t}`,
      };
    }

    case "화장실": {
      mark(timeIdx);
      const t = timeVal || now;
      const feelMap = {
        "아주편함": "아주 편함", "편함": "편함", "보통": "보통", "불편": "불편", "아주불편": "아주 불편",
        "최고": "아주 편함", "좋음": "편함", "별로": "불편", "최악": "아주 불편",
      };
      const feelIdx = words.findIndex(w => feelMap[w]);
      let feel = null;
      if (feelIdx !== -1) { feel = feelMap[words[feelIdx]]; used.add(feelIdx); }
      const memo = restText();
      const finalFeel = feel || memo || null;
      return {
        type: "event",
        event: { type: "bathroom", time: t, ...(finalFeel && { feel: finalFeel }) },
        reply: `✅ 화장실 저장${finalFeel ? ` · ${finalFeel}` : ""} · ${t}`,
      };
    }

    default:
      return null;
  }
}

const HELP_TEXT = `📋 BALANCE 입력 가이드
카테고리만 고정, 나머지 순서 자유 / 시간 생략 시 현재 시각 저장
"어제" 추가 시 전날 날짜로 저장

🌤️ 아침
아침 [컨디션1-5] [기상시간HH:MM] [키워드] [메모]
키워드: 스트레칭 · 소금가글 · 아침디톡스 · 생리중
예) 아침 4 07:30 스트레칭 소금가글 아침디톡스
예) 아침 어제 3 07:00 생리중

🌙 저녁
저녁 [컨디션1-5] [취침시간HH:MM] [키워드] [메모]
키워드: 스트레칭 · 저녁디톡스
예) 저녁 4 23:00 스트레칭 저녁디톡스
예) 저녁 어제 3 23:30 오늘 좋았음

💧 수분 (물·차만 점수 반영)
수분-[종류] [ml 또는 잔] [시간]
종류: 물(ml) · 차(ml) · 커피 · 음료 · 시판 · 건강(잔) · 술
예) 수분-물 300
예) 수분-차 200 보이차 09:00
예) 수분-커피 아메리카노
예) 수분-건강 2

🍽️ 식사
식사-[끼니] [메뉴] [건강도] [배고픔] [시간]
끼니: 아침·점심·저녁·간식(→자동 간식체크)
건강도: 클린 · 보통 · 정크 · 폭식
배고픔: 배고팠음 · 그냥먹음 · 안배고픔
예) 식사-점심 비빔밥 클린 배고팠음 13:00
예) 식사-간식 과자 보통

💪 운동
운동 [종류키워드] [분] [메모] [시간]
종류키워드: 달리기·산책·요가·스트레칭·근력운동
예) 운동 달리기 30 18:00
예) 운동 근력운동 산책 45

📖 활동
활동 [내용] [분] [시간]
특수키워드: 찬물샤워 (점수 반영)
예) 활동 찬물샤워
예) 활동-독서 30 14:00

🧘 명상
명상 [분] [키워드] [시간]
키워드: 결가부좌 · 진언(또는 만트라)
예) 명상 20 결가부좌
예) 명상 30 진언 22:00

😴 휴식
휴식 [분] [키워드] [시간]
키워드: 수면(또는 낮잠) · 멍때리기(또는 멍때림)
예) 휴식 60 수면 14:00
예) 휴식 20 멍때리기

💭 감정
감정-[이름] [메모] [시간]
예) 감정-행복
예) 감정-불안 발표 때문에 10:00

🚽 화장실
화장실 [상태] [시간]
상태: 아주편함·편함·보통·불편·아주불편
단축: 최고=아주편함 · 좋음=편함 · 별로=불편 · 최악=아주불편
예) 화장실 편함  /  화장실 불편 09:30`;

export default {
  async fetch(request, env) {
    if (request.method !== "POST") return new Response("OK");
    let update;
    try { update = await request.json(); } catch { return new Response("Bad Request", { status: 400 }); }
    const message = update?.message;
    if (!message?.text) return new Response("OK");
    const chatId = message.chat?.id?.toString();
    const text = message.text.trim();
    if (chatId !== env.TG_CHAT) return new Response("OK");
    const date = kstDate();
    const now = kstTime();
    if (text === "/help" || text === "/start") {
      await sendTelegram(env.TG_TOKEN, chatId, HELP_TEXT);
      return new Response("OK");
    }
    const parsed = parseMessage(text, now);
    if (!parsed) {
      await sendTelegram(env.TG_TOKEN, chatId, `❓ 인식 못했어요.\n/help 로 사용법 확인`);
      return new Response("OK");
    }
    try {
      const firebaseKey = JSON.parse(env.FIREBASE_KEY_JSON);
      const fbToken = await getFirebaseToken(firebaseKey.private_key);
      const entryDate = parsed.useYesterday ? kstYesterday() : date;
      const entry = await getEntry(entryDate, fbToken);
      if (parsed.type === "morning") {
        entry.morning = { ...entry.morning, ...parsed.update };
      } else if (parsed.type === "evening") {
        entry.evening = { ...entry.evening, ...parsed.update };
      } else if (parsed.type === "event") {
        entry.events.push(parsed.event);
      }
      await setEntry(entryDate, entry, fbToken);
      await sendTelegram(env.TG_TOKEN, chatId, parsed.reply);
    } catch (err) {
      await sendTelegram(env.TG_TOKEN, chatId, `⚠️ 저장 실패: ${err.message}`);
    }
    return new Response("OK");
  },
};
