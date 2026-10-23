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
  // App Store Installations and Deletions: Event (Install/Delete), Download Type, Counts.
  // Only first-time downloads count as a new install — not redownloads, updates or restores.
  installs(rows) {
    return sumByDate(rows, (r) =>
      /^install$/i.test(r["event"]) && /^first-time download$/i.test(r["download type"]) ? { installs: num(r["counts"]) } : { installs: 0 }
    );
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

export function buildStatus({ now, app, links }) {
  const today = now.toISOString().slice(0, 10);
  return { version: 1, computedAt: now.toISOString(), days: lastDays(today), app, links };
}

// App block from merged per-report maps. reportedThrough = the last date Apple has
// processed (the newest instance's processingDate − 1); Apple says data is complete
// five days after that. reportedFrom (or null) = the first date Apple covers; days
// before it were never reported, which is not the same as under the five-person floor.
export function appBlock({ days, sessions, installs, clip, latestProcessingDate, reportedFrom = null }) {
  const reportedThrough = latestProcessingDate ? addDays(latestProcessingDate, -1) : null;
  return {
    available: true,
    reportedFrom,
    reportedThrough,
    completeThrough: reportedThrough ? addDays(reportedThrough, -5) : null,
    sessions: series(sessions, days, "sessions"),
    devices: series(sessions, days, "devices"),
    installs: series(installs, days, "installs"),
    clipViews: series(clip, days, "clipViews"),
  };
}
