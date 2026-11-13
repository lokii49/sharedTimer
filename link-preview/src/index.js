// Per-link previews for shared Timer links, plus the counts behind /timer/status.
//
// Messages (and other apps) build a link preview from the page's <title> and og: tags.
// docs/t.html is static, so every link previewed as plain "Timer". This Worker serves
// the same page from GitHub Pages and only rewrites those tags from the link's own
// query string ("Pasta" / "8 min timer"). The app never calls it — it runs only when
// someone opens or previews a link.
//
// For the status page it records one data point per link request: whether it was a
// link preview or an open in a browser. Nothing else — not the link, its label, the
// IP address or the user agent. Request logs stay off. /timer/status.json is the
// summary status/build.mjs writes to KV; the page itself is a static file on Pages.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/timer/status.json") return serveStatus(env);
    const response = await fetch(request);
    if (!(url.pathname === "/timer" || url.pathname === "/timer.html") || !response.ok) {
      return response;
    }
    const preview = describe(url.search, Date.now() / 1000);
    if (!preview) return response;
    if (request.method === "GET") count(env, request.headers.get("user-agent"));
    return new HTMLRewriter()
      .on("title", { element: (e) => e.setInnerContent(`${preview.title} · Timer`) })
      .on('meta[property="og:title"]', { element: (e) => e.setAttribute("content", preview.title) })
      .on('meta[property="og:description"]', { element: (e) => e.setAttribute("content", preview.description) })
      .transform(response);
  },
};

// Messages builds its preview on the sender's phone with a user agent carrying the
// facebookexternalhit/Facebot/Twitterbot tokens; other apps' fetchers say "bot" too.
// Anything else is a person opening the link in a browser (no app, or not claimed).
const PREVIEW_AGENT = /facebookexternalhit|facebot|twitterbot|slackbot|discordbot|whatsapp|telegrambot|linkedinbot|skypeuripreview|embedly|bot\b|crawler|spider|preview/i;

export function classify(userAgent) {
  return PREVIEW_AGENT.test(userAgent || "") ? "preview" : "open";
}

function count(env, userAgent) {
  try {
    env.LINK_OPENS?.writeDataPoint({ blobs: [classify(userAgent)], indexes: ["link"] });
  } catch {
    // Counting must never break a link.
  }
}

export async function serveStatus(env) {
  const body = await env.STATUS?.get("status.json");
  if (!body) {
    return new Response(JSON.stringify({ error: "not yet published" }), {
      status: 503,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
    });
  }
  return new Response(body, {
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=300" },
  });
}

// Mirrors TimerPayload.shareSummary in TimerModel.swift, but avoids calendar dates:
// the server doesn't know the viewer's time zone, so countdowns say how far away.
// `search` is the raw query string (url.search). Returns null — no rewrite, no count —
// for a link the app's TimerPayload.from(url:) rejects, which docs/t.html shows as
// "No timer data" or "invalid": it needs an id, a label item and an end, and a dur or
// paused that parses must be in range. The sequence/recurrence JSON is only checked for
// shape here; docs/t.html validates it fully.
export function describe(search, now) {
  const raw = queryItems(search);
  const params = new URLSearchParams(search);
  const id = raw.get("id");
  const end = swiftDouble(raw.get("end"));
  const duration = swiftDouble(raw.get("dur"));
  const paused = swiftDouble(raw.get("paused"));
  if (!id || new TextEncoder().encode(id).length > 512 || raw.get("label") === null ||
      end === null || !Number.isFinite(end) || Math.abs(end) > 253402300799 ||
      (duration !== null && !(Number.isFinite(duration) && duration > 0 && duration <= 1e12)) ||
      (paused !== null && !(Number.isFinite(paused) && paused >= 0 && paused <= 1e12))) {
    return null;
  }
  // The title follows what the page shows (URLSearchParams: "+" is a space).
  const label = (params.get("label") || "").trim().slice(0, 80) || "Timer";
  const kind = params.get("kind") === "countdown" ? "countdown" : "timer";
  const isPaused = paused !== null;

  let sequence = null;
  if (params.has("seq")) {
    sequence = parseSequence(params.get("seq"));
    if (!sequence) return null;
  }
  // Yearly rides in `annual`, daily/weekly/monthly in `repeat` (never both, countdowns
  // only, never with a sequence). The page rolls a past end on to the next occurrence,
  // so a repeating countdown is never "finished"; the date math stays in the page.
  let frequency = null;
  if (params.has("annual") || params.has("repeat")) {
    if (kind !== "countdown" || sequence || (params.has("annual") && params.has("repeat"))) return null;
    const rule = parseRecurrence(params.get(params.has("annual") ? "annual" : "repeat"));
    if (!rule) return null;
    frequency = params.has("annual") ? "yearly" : rule.frequency;
    if (!EVERY[frequency] || frequency === "yearly" && params.has("repeat")) return null;
  }

  let description;
  if (sequence) {
    const loops = sequence.loopCount === 1 ? "1 loop" : `${sequence.loopCount} loops`;
    description = `${sequence.phases.length} phases · ${loops}`;
  } else if (kind === "countdown") {
    const left = isPaused ? paused : end - now;
    if (frequency) {
      description = left > 0 ? `${roughly(left)} to go · ${EVERY[frequency]}` : `${frequency[0].toUpperCase()}${frequency.slice(1)} countdown`;
    } else {
      description = left > 0 ? `${roughly(left)} to go` : "Countdown finished";
    }
  } else {
    // Same wording as the app's shareSummary: seconds under a minute ("20 sec timer").
    description = duration === null ? "Timer"
      : duration < 60 ? `${Math.max(1, Math.round(duration))} sec timer`
      : `${Math.round(duration / 60)} min timer`;
  }
  if (isPaused) description += " · paused";
  return { title: label, description };
}

const EVERY = { yearly: "every year", monthly: "every month", weekly: "every week", daily: "every day" };

// A query value the way the app's URLComponents.queryItems reads it: percent-decoded,
// "+" kept literal, null when absent or written without "=".
export function queryItems(search) {
  const items = [];
  const decode = (text) => {
    try {
      return decodeURIComponent(text);
    } catch {
      return null;
    }
  };
  for (const piece of String(search || "").replace(/^\?/, "").split("&")) {
    const eq = piece.indexOf("=");
    items.push([decode(eq < 0 ? piece : piece.slice(0, eq)), eq < 0 ? null : decode(piece.slice(eq + 1))]);
  }
  return { get: (name) => items.find(([key]) => key === name)?.[1] ?? null };
}

// Swift's Double(_:): null when it can't parse (no surrounding whitespace, no "0b" or
// "0X"); Infinity/NaN for "inf"/"nan", which parse and then fail the range checks.
// Same as swiftDouble in docs/t.html.
export function swiftDouble(text) {
  if (text === null || text === undefined) return null;
  if (/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)) return Number(text);
  const hex = /^([+-]?)0x([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?\d+))?$/.exec(text);
  if (hex && (hex[2] || hex[3])) {
    let value = 0;
    for (const digit of hex[2] + (hex[3] || "")) value = value * 16 + parseInt(digit, 16);
    if (value) value *= 2 ** (Number(hex[4] || 0) - 4 * (hex[3] || "").length);
    return hex[1] === "-" ? -value : value;
  }
  if (/^[+-]?inf(?:inity)?$/i.test(text)) return text[0] === "-" ? -Infinity : Infinity;
  if (/^[+-]?s?nan(?:\((?:0x[0-9a-fA-F]*|\d*)\))?$/i.test(text)) return NaN;
  return null;
}

function parseSequence(json) {
  try {
    const s = JSON.parse(json).sequence;
    return s && Array.isArray(s.phases) && s.phases.length > 0 && Number.isInteger(s.loopCount ?? 1) ? { ...s, loopCount: s.loopCount ?? 1 } : null;
  } catch {
    return null;
  }
}

function parseRecurrence(json) {
  try {
    const envelope = JSON.parse(json);
    return envelope && envelope.recurrence && typeof envelope.recurrence === "object" ? envelope.recurrence : null;
  } catch {
    return null;
  }
}

function roughly(seconds) {
  const days = Math.floor(seconds / 86400);
  if (days >= 2) return `${days} days`;
  const hours = Math.floor(seconds / 3600);
  if (hours >= 2) return `${hours} hours`;
  return `${Math.max(1, Math.round(seconds / 60))} min`;
}
