// Pure helpers for status/build.mjs: parse Apple's report files, merge report
// instances the way Apple says to, and shape the JSON /timer/status reads.
// No network or clock reads here, so everything is testable with fixtures.

export const DAYS = 30;

// Apple's report segments are gzip'd tab-separated text with a header row.
export function parseTsv(text) {
  const lines = text.replace(/\r/g, "").split("\n").filter((l) => l.length);
  if (!lines.length) return [];
  const head = lines[0].split("\t").map((h) => h.trim().replace(/^"|"$/g, "").toLowerCase());
  return lines.slice(1).map((line) => {
    const cells = line.split("\t");
    const row = {};
    head.forEach((h, i) => (row[h] = (cells[i] ?? "").trim().replace(/^"|"$/g, "")));
    return row;
  });
}

const num = (v) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

// Per-report reducers: rows of one instance → Map(date → { field: n }).
// Column names are from Apple's report docs (developer.apple.com/documentation/analytics-reports).
export const reducers = {
  // App Sessions: Sessions, Unique Devices.
  sessions(rows) {
    return sumByDate(rows, (r) => ({ sessions: num(r["sessions"]), devices: num(r["unique devices"]) }));
  },
  // App Clip Usage: App Clip Event Type (Views/Installations/Sessions/Crashes), Counts.
  clip(rows) {
    return sumByDate(rows, (r) => (/view/i.test(r["app clip event type"]) ? { clipViews: num(r["counts"]) } : { clipViews: 0 }));
  },
};

function sumByDate(rows, pick) {
  const out = new Map();
  for (const r of rows) {
    const date = (r["date"] || "").slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) continue;
    const add = pick(r);
    const acc = out.get(date) || {};
    for (const [k, v] of Object.entries(add)) acc[k] = (acc[k] || 0) + v;
    out.set(date, acc);
  }
  return out;
}

// Apple: "Instances from a more recent processingDate overwrite instances with an
// earlier processingDate … Don't merge records for a Date across two report
// instances." So each date takes its numbers from the newest instance that has it.
export function mergeInstances(instances) {
  const out = new Map();
  for (const inst of [...instances].sort((a, b) => a.processingDate.localeCompare(b.processingDate))) {
    for (const [date, values] of inst.byDate) out.set(date, values);
  }
  return out;
}

export function lastDays(today, n = DAYS) {
  const end = Date.parse(today + "T00:00:00Z");
  return Array.from({ length: n }, (_, i) => new Date(end - (n - 1 - i) * 86400000).toISOString().slice(0, 10));
}

export function addDays(date, n) {
  return new Date(Date.parse(date + "T00:00:00Z") + n * 86400000).toISOString().slice(0, 10);
}

// Earliest dated row in the first instance Apple ever made for a report, or null once
// that instance is older than the ones fetched (reporting began before the window).
export function firstReportedDate(parsed, firstEverProcessingDate) {
  const first = parsed.find((p) => p.processingDate === firstEverProcessingDate);
  return first ? [...first.byDate.keys()].sort()[0] ?? null : null;
}

// A date Apple has reported but has no row for means "under the five-person floor"
// (or truly zero — the report can't tell them apart), so it stays null, never 0.
export function series(merged, days, field) {
  return days.map((d) => {
    const v = merged.get(d)?.[field];
    return v === undefined ? null : v;
  });
}

// Sales and Trends daily summary rows → one app's first-time downloads that day. Product
// types starting with 1 are first-time downloads (1, 1F, 1T …); 3* are redownloads, 7*
// updates, IA* in-app purchases. It's every customer, unlike the analytics reports.
export function salesInstalls(rows, appId) {
  return rows
    .filter((r) => r["apple identifier"] === String(appId) && /^1/.test(r["product type identifier"]))
    .reduce((n, r) => n + num(r["units"]), 0);
}

// Per-day results (a number, or null for a 404: no report file) → the sales block.
// A 404 after the newest day Apple has posted means not posted yet (null); before it,
// the vendor sold nothing that day (0).
export function salesBlock(results, days) {
  const reportedThrough = [...results].filter(([, v]) => v !== null).map(([d]) => d).sort().pop() ?? null;
  return {
    available: true,
    reportedThrough,
    installs: days.map((d) => (!reportedThrough || d > reportedThrough ? null : results.get(d) ?? 0)),
  };
}

// Analytics Engine SQL rows ({ day: epoch seconds, kind, n }) → per-day counts.
// Days before the first counted day are null (the counter wasn't running yet).
export function linkSeries(rows, days) {
  const byDay = new Map();
  for (const r of rows) {
    const day = new Date(Number(r.day) * 1000).toISOString().slice(0, 10);
    const acc = byDay.get(day) || { preview: 0, open: 0 };
    if (r.kind === "preview" || r.kind === "open") acc[r.kind] += Number(r.n) || 0;
    byDay.set(day, acc);
  }
  const first = [...byDay.keys()].sort()[0];
  const pick = (kind) => days.map((d) => (first === undefined || d < first ? null : byDay.get(d)?.[kind] ?? 0));
  return { since: first ?? null, previews: pick("preview"), opens: pick("open") };
}

export function buildStatus({ now, app, sales, links }) {
  const today = now.toISOString().slice(0, 10);
  return { version: 1, computedAt: now.toISOString(), days: lastDays(today), app, sales, links };
}

// App block from merged per-report maps. reportedThrough = the last date Apple has
// processed (the newest instance's processingDate − 1); Apple says data is complete
// five days after that. reportedFrom (or null) = the first date Apple covers; days
// before it were never reported, which is not the same as under the five-person floor.
export function appBlock({ days, sessions, clip, latestProcessingDate, reportedFrom = null }) {
  const reportedThrough = latestProcessingDate ? addDays(latestProcessingDate, -1) : null;
  return {
    available: true,
    reportedFrom,
    reportedThrough,
    completeThrough: reportedThrough ? addDays(reportedThrough, -5) : null,
    sessions: series(sessions, days, "sessions"),
    devices: series(sessions, days, "devices"),
    clipViews: series(clip, days, "clipViews"),
  };
}
