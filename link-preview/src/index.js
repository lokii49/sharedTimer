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
    const preview = describe(url.searchParams, Date.now() / 1000);
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
export function describe(params, now) {
  const label = (params.get("label") || "").trim().slice(0, 80);
  const end = Number(params.get("end"));
  if (!label || !Number.isFinite(end)) return null;
  const kind = params.get("kind") === "countdown" ? "countdown" : "timer";
  const duration = Number(params.get("dur"));
  const paused = params.get("paused") === null ? NaN : Number(params.get("paused"));

  let description;
  const sequence = parseSequence(params.get("seq"));
  if (sequence) {
    const loops = sequence.loopCount === 1 ? "1 loop" : `${sequence.loopCount} loops`;
    description = `${sequence.phases.length} phases · ${loops}`;
  } else if (kind === "countdown") {
    const left = Number.isFinite(paused) ? paused : end - now;
    description = left > 0 ? `${roughly(left)} to go` : "Countdown finished";
    if (params.get("annual") !== null) description += " · every year";
  } else {
    description = Number.isFinite(duration) && duration > 0 ? `${Math.max(1, Math.round(duration / 60))} min timer` : "Timer";
  }
  if (Number.isFinite(paused)) description += " · paused";
  return { title: label, description };
}

function parseSequence(json) {
  if (json === null) return null;
  try {
    const s = JSON.parse(json).sequence;
    return s && Array.isArray(s.phases) && s.phases.length > 0 && Number.isInteger(s.loopCount) ? s : null;
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
