// Builds /timer/status.json and publishes it to the Worker's KV namespace.
// Run by .github/workflows/status.yml; locally: `node status/build.mjs --out status.json`
// (with --out it writes the file and skips the KV upload).
//
// Sources:
//  1. App Store Connect Analytics Reports API — Apple's opt-in, aggregated usage data
//     (sessions, first-time installs, App Clip card views). Daily, 1–2 days behind,
//     final after five days, and rows from fewer than five people are left out by Apple.
//  2. Workers Analytics Engine — the link-preview Worker's per-request tally of
//     shared-link previews vs. browser opens (category only, nothing else).
//
// Env: ASC_ISSUER_ID, ASC_KEY_ID, ASC_PRIVATE_KEY (.p8 contents), ASC_APP_ID (numeric
// Apple ID); CF_ACCOUNT_ID, CF_API_TOKEN (Account Analytics: Read + Workers KV: Edit);
// CF_KV_NAMESPACE_ID (defaults to the id in link-preview/wrangler.toml).
// A missing source is skipped; a failing one keeps the last published numbers.

import { createSign, createPrivateKey } from "node:crypto";
import { gunzipSync } from "node:zlib";
import { readFileSync, writeFileSync } from "node:fs";
import { DAYS, appBlock, buildStatus, lastDays, linkSeries, mergeInstances, parseTsv, reducers, addDays } from "./lib.mjs";

const env = process.env;
const outIndex = process.argv.indexOf("--out");
const outFile = outIndex > 0 ? process.argv[outIndex + 1] : null;
const now = new Date();
const days = lastDays(now.toISOString().slice(0, 10));

// ---------- App Store Connect ----------

const ASC = "https://api.appstoreconnect.apple.com";
let token = null;
let tokenAt = 0;

function ascToken() {
  // Apple allows at most 20 minutes; refresh well before that on a long run.
  if (token && Date.now() - tokenAt < 10 * 60 * 1000) return token;
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const iat = Math.floor(Date.now() / 1000);
  const unsigned = `${b64({ alg: "ES256", kid: env.ASC_KEY_ID, typ: "JWT" })}.${b64({ iss: env.ASC_ISSUER_ID, iat, exp: iat + 15 * 60, aud: "appstoreconnect-v1" })}`;
  const key = createPrivateKey(env.ASC_PRIVATE_KEY.replace(/\\n/g, "\n"));
  const sig = createSign("SHA256").update(unsigned).sign({ key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  token = `${unsigned}.${sig}`;
  tokenAt = Date.now();
  return token;
}

async function request(url, init = {}, tries = 4) {
  for (let i = 0; ; i++) {
    const res = await fetch(url, init);
    if (res.ok) return res;
    if (i + 1 >= tries || !(res.status === 429 || res.status >= 500)) {
      throw new Error(`${init.method || "GET"} ${url.split("?")[0]} → ${res.status}: ${(await res.text()).slice(0, 300)}`);
    }
    await new Promise((r) => setTimeout(r, 2000 * 2 ** i));
  }
}

async function asc(path, init = {}) {
  const res = await request(path.startsWith("http") ? path : ASC + path, {
    ...init,
    headers: { authorization: `Bearer ${ascToken()}`, "content-type": "application/json", ...init.headers },
  });
  return res.json();
}

async function ascAll(path) {
  const out = [];
  for (let next = path; next; ) {
    const page = await asc(next);
    out.push(...page.data);
    next = page.links?.next || null;
  }
  return out;
}

// An ONGOING request makes Apple generate reports every day. Creating one needs an
// Admin key once; after that Apple stops it only if nobody reads it for a long time.
async function ongoingRequestId() {
  const existing = await ascAll(`/v1/apps/${env.ASC_APP_ID}/analyticsReportRequests?filter[accessType]=ONGOING`);
  const live = existing.find((r) => !r.attributes?.stoppedDueToInactivity);
  if (live) return { id: live.id, created: false };
  const made = await asc("/v1/analyticsReportRequests", {
    method: "POST",
    body: JSON.stringify({
      data: {
        type: "analyticsReportRequests",
        attributes: { accessType: "ONGOING" },
        relationships: { app: { data: { type: "apps", id: String(env.ASC_APP_ID) } } },
      },
    }),
  });
  return { id: made.data.id, created: true };
}

// Report names as the API lists them; matched loosely and logged, since Apple's docs
// give the page titles ("App Sessions") rather than the exact API names.
const WANTED = {
  sessions: (n) => /app sessions/i.test(n),
  installs: (n) => /install/i.test(n) && /delet/i.test(n) && !/platform/i.test(n),
  clip: (n) => /app clip usage/i.test(n),
};

async function appStats() {
  const { id, created } = await ongoingRequestId();
  if (created) console.log("Created an ONGOING analytics report request; Apple's first reports take 24–48 hours.");
  const reports = await ascAll(`/v1/analyticsReportRequests/${id}/reports?filter[category]=APP_USAGE&limit=200`);
  console.log("APP_USAGE reports:", reports.map((r) => r.attributes.name).join(" | ") || "(none yet)");

  const since = addDays(days[0], -10); // instances processed before the window can't hold its dates
  const merged = {};
  let latestProcessingDate = null;
  for (const [key, matches] of Object.entries(WANTED)) {
    const report = reports.find((r) => matches(r.attributes.name) && /standard/i.test(r.attributes.name));
    if (!report) {
      console.warn(`No standard report found for ${key}`);
      merged[key] = new Map();
      continue;
    }
    const instances = (await ascAll(`/v1/analyticsReports/${report.id}/instances?filter[granularity]=DAILY&limit=200`)).filter(
      (i) => i.attributes.processingDate >= since
    );
    const parsed = [];
    for (const inst of instances) {
      const segments = await ascAll(`/v1/analyticsReportInstances/${inst.id}/segments`);
      const rows = [];
      for (const seg of segments) {
        // Segment URLs are pre-signed and expire after five minutes: download at once.
        const raw = Buffer.from(await (await request(seg.attributes.url)).arrayBuffer());
        rows.push(...parseTsv((raw[0] === 0x1f && raw[1] === 0x8b ? gunzipSync(raw) : raw).toString("utf8")));
      }
      parsed.push({ processingDate: inst.attributes.processingDate, byDate: reducers[key](rows) });
      if (!latestProcessingDate || inst.attributes.processingDate > latestProcessingDate) latestProcessingDate = inst.attributes.processingDate;
    }
    console.log(`${report.attributes.name}: ${instances.length} daily instances`);
    merged[key] = mergeInstances(parsed);
  }
  return appBlock({ days, ...merged, latestProcessingDate });
}

// ---------- Cloudflare ----------

const CF = `https://api.cloudflare.com/client/v4/accounts/${env.CF_ACCOUNT_ID}`;
const cfAuth = () => ({ authorization: `Bearer ${env.CF_API_TOKEN}` });

async function linkStats() {
  const sql = `SELECT intDiv(toUInt32(timestamp), 86400) * 86400 AS day, blob1 AS kind, SUM(_sample_interval) AS n
FROM timer_link_opens
WHERE timestamp >= NOW() - INTERVAL '${DAYS + 1}' DAY
GROUP BY day, kind
FORMAT JSON`;
  const res = await request(`${CF}/analytics_engine/sql`, { method: "POST", headers: cfAuth(), body: sql });
  return { available: true, ...linkSeries((await res.json()).data, days) };
}

function kvNamespaceId() {
  if (env.CF_KV_NAMESPACE_ID) return env.CF_KV_NAMESPACE_ID;
  const toml = readFileSync(new URL("../link-preview/wrangler.toml", import.meta.url), "utf8");
  const id = toml.match(/binding\s*=\s*"STATUS"\s*\n\s*id\s*=\s*"([0-9a-f]{32})"/)?.[1];
  if (!id) throw new Error("No KV namespace id: set CF_KV_NAMESPACE_ID or the STATUS id in link-preview/wrangler.toml");
  return id;
}

const kvUrl = () => `${CF}/storage/kv/namespaces/${kvNamespaceId()}/values/status.json`;

async function previous() {
  try {
    const res = await fetch(kvUrl(), { headers: cfAuth() });
    return res.ok ? await res.json() : null;
  } catch {
    return null;
  }
}

// ---------- Run ----------

const haveCF = env.CF_ACCOUNT_ID && env.CF_API_TOKEN;
const haveASC = env.ASC_ISSUER_ID && env.ASC_KEY_ID && env.ASC_PRIVATE_KEY && env.ASC_APP_ID;
const last = haveCF && !outFile ? await previous() : null;
let failed = false;

// On failure, carry the last published series over, re-aligned to today's window.
function carried(block) {
  if (!block?.available || !last?.days) return { available: false };
  const out = { ...block, staleSince: block.staleSince || last.computedAt };
  for (const [k, v] of Object.entries(block)) {
    if (Array.isArray(v) && v.length === last.days.length) out[k] = days.map((d) => v[last.days.indexOf(d)] ?? null);
  }
  return out;
}

async function attempt(name, have, run, lastBlock) {
  if (!have) {
    console.warn(`${name}: credentials not set, skipped`);
    return { available: false };
  }
  try {
    return await run();
  } catch (e) {
    failed = true;
    console.error(`${name} failed:`, e.message);
    return carried(lastBlock);
  }
}

const status = buildStatus({
  now,
  app: await attempt("App Store Connect", haveASC, appStats, last?.app),
  links: await attempt("Link counts", haveCF, linkStats, last?.links),
});
const json = JSON.stringify(status);

if (outFile) {
  writeFileSync(outFile, JSON.stringify(status, null, 2));
  console.log(`Wrote ${outFile}`);
} else if (haveCF) {
  await request(kvUrl(), { method: "PUT", headers: { ...cfAuth(), "content-type": "text/plain" }, body: json });
  console.log("Published status.json to KV");
} else {
  // Not set up yet (no secrets): stay green rather than failing every three hours.
  console.log("::warning::Status page not set up: add CF_ACCOUNT_ID and CF_API_TOKEN secrets (see CLAUDE.md, Status page)");
  process.exit(0);
}
// A failed source still publishes the rest, but the workflow run shows red.
if (failed) process.exit(1);
