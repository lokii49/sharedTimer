import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { describe, classify, serveStatus } from "./src/index.js";

const now = 1_800_000_000;
// describe() takes the raw query string, as the Worker passes url.search.
const p = (q) => "?id=t1&" + (typeof q === "string" ? q : new URLSearchParams(q).toString());
const rule = (r = {}) => encodeURIComponent(JSON.stringify({ version: 1, recurrence: { month: 3, day: 1, hour: 9, minute: 0, second: 0, timeZoneID: "GMT", ...r } }));

test("plain timer", () => {
  assert.deepEqual(describe(p("label=Pasta&end=1&dur=480&kind=timer"), now), { title: "Pasta", description: "8 min timer" });
});

test("countdown says how far away, not a date", () => {
  assert.equal(describe(p(`label=Trip&end=${now + 10 * 86400}&dur=1&kind=countdown`), now).description, "10 days to go");
  assert.equal(describe(p(`label=Trip&end=${now - 5}&dur=1&kind=countdown`), now).description, "Countdown finished");
});

test("paused and annual", () => {
  assert.equal(describe(p("label=Tea&end=1&dur=300&kind=timer&paused=120"), now).description, "5 min timer · paused");
  assert.equal(describe(p(`label=Mum&end=${now + 3 * 86400}&dur=1&kind=countdown&annual=${rule()}`), now).description, "3 days to go · every year");
});

test("a repeating countdown past its end is never finished: the page rolls it on", () => {
  const past = `label=Mum&end=${now - 5}&dur=1&kind=countdown`;
  assert.equal(describe(p(`${past}&annual=${rule()}`), now).description, "Yearly countdown");
  assert.equal(describe(p(`${past}&repeat=${rule({ frequency: "daily" })}`), now).description, "Daily countdown");
  assert.equal(describe(p(`${past}&repeat=${rule({ frequency: "weekly", weekday: 2 })}`), now).description, "Weekly countdown");
  assert.equal(describe(p(`${past}&repeat=${rule({ frequency: "monthly" })}`), now).description, "Monthly countdown");
  assert.equal(describe(p(`label=Gym&end=${now + 3 * 3600}&dur=1&kind=countdown&repeat=${rule({ frequency: "weekly", weekday: 2 })}`), now).description, "3 hours to go · every week");
  // The app rejects these, so the page shows "invalid" and nothing is rewritten.
  assert.equal(describe(p(`${past}&repeat=notjson`), now), null);
  assert.equal(describe(p(`label=Mum&end=1&dur=1&kind=timer&annual=${rule()}`), now), null);
  assert.equal(describe(p(`${past}&annual=${rule()}&repeat=${rule({ frequency: "daily" })}`), now), null);
});

test("sequence", () => {
  const seq = JSON.stringify({ version: 1, sequence: { phases: [{ label: "Focus" }, { label: "Break" }], loopCount: 4, phaseIndex: 0, loopIndex: 0 } });
  assert.equal(describe(p({ label: "Focus", end: "1", dur: "1500", kind: "timer", seq }), now).description, "2 phases · 4 loops");
  assert.equal(describe(p({ label: "Focus", end: "1", dur: "1500", kind: "timer", seq: "{" }), now), null);
});

test("no label or bad end leaves the page alone", () => {
  assert.equal(describe(p("end=1"), now), null);
  assert.equal(describe(p("label=X&end=abc"), now), null);
});

// TimerPayload.from(url:) needs an id, a label item and an end Double(_:) parses, in
// range; a parsed dur/paused must be in range too. The page shows "No timer data" or
// "invalid" for these, so they are neither rewritten nor counted.
test("links the app rejects are left alone", () => {
  for (const q of [
    "?label=x",
    "?id=t1&label=x",
    "?id=t1&label=x&dur=60",
    "?label=Pasta&end=1&dur=480",
    "?id=&label=Pasta&end=1&dur=480",
    `?id=${"a".repeat(513)}&label=Pasta&end=1&dur=480`,
    "?id=t1&end=1&dur=480",
    "?id=t1&label&end=1&dur=480",
    "?id=t1&label=x&end=",
    "?id=t1&label=x&end=%201",
    "?id=t1&label=x&end=1e300",
    "?id=t1&label=x&end=inf",
    "?id=t1&label=x&end=1&dur=0",
    "?id=t1&label=x&end=1&dur=1e13",
    "?id=t1&label=x&end=1&dur=nan",
    "?id=t1&label=x&end=1&dur=60&paused=-1",
    "?id=t1&label=x&end=1&dur=60&paused=1e13",
  ]) {
    assert.equal(describe(q, now), null, q);
  }
  // …and these it accepts: no dur, an unparseable dur or pause (ignored), "+" kept, an empty label.
  assert.equal(describe("?id=t1&label=x&end=1", now).description, "Timer");
  assert.equal(describe("?id=t1&label=x&end=1&dur=abc", now).description, "Timer");
  assert.equal(describe("?id=t1&label=x&end=1&dur=60&paused=abc", now).description, "1 min timer");
  assert.equal(describe("?id=t1&label=x&end=+1&dur=60", now).description, "1 min timer");
  assert.equal(describe("?id=t1&label=&end=1&dur=60", now).title, "Timer");
});

test("link previews and browser opens are told apart by user agent", () => {
  const messages = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0";
  assert.equal(classify(messages), "preview");
  assert.equal(classify("Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)"), "preview");
  assert.equal(classify("Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"), "preview");
  assert.equal(classify("Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"), "open");
  assert.equal(classify(null), "open");
});

// Runs the real fetch handler against a stubbed origin and bindings.
async function run(path, { ua = "Safari", method = "GET", status = 200, kv = {} } = {}) {
  const points = [];
  const env = {
    LINK_OPENS: { writeDataPoint: (p) => points.push(p) },
    STATUS: { get: async (k) => kv[k] ?? null },
  };
  const realFetch = globalThis.fetch;
  globalThis.HTMLRewriter ??= class { on() { return this; } transform(r) { return r; } };
  globalThis.fetch = async () => new Response("<title>Timer</title>", { status });
  try {
    const res = await worker.fetch(new Request("https://mirrornotes.org" + path, { method, headers: { "user-agent": ua } }), env);
    return { res, points };
  } finally {
    globalThis.fetch = realFetch;
  }
}

test("a timer link records exactly one point with only its category", async () => {
  const { points } = await run("/timer?id=t1&label=Pasta&end=1&dur=480&kind=timer", { ua: "facebookexternalhit/1.1 Facebot Twitterbot/1.0" });
  assert.deepEqual(points, [{ blobs: ["preview"], indexes: ["link"] }]);
  assert.equal(JSON.stringify(points).includes("Pasta"), false);
});

test("nothing is counted for other pages, bad links, errors or HEAD", async () => {
  for (const [path, opts] of [
    ["/timer/privacy", {}],
    ["/timer/status", {}],
    ["/timer?end=1", {}],
    ["/timer?label=x", {}],
    ["/timer?id=t1&label=Pasta&end=1", { status: 404 }],
    ["/timer?id=t1&label=Pasta&end=1", { method: "HEAD" }],
  ]) {
    assert.deepEqual((await run(path, opts)).points, [], path);
  }
});

test("status.json comes from KV, with a 503 until the first publish", async () => {
  const empty = await serveStatus({ STATUS: { get: async () => null } });
  assert.equal(empty.status, 503);
  const { res } = await run("/timer/status.json", { kv: { "status.json": '{"version":1}' } });
  assert.equal(res.status, 200);
  assert.equal(await res.text(), '{"version":1}');
  assert.match(res.headers.get("cache-control"), /max-age=300/);
});
