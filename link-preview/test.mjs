import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { describe, classify, serveStatus } from "./src/index.js";

const now = 1_800_000_000;
const p = (q) => new URLSearchParams(q);

test("plain timer", () => {
  assert.deepEqual(describe(p("label=Pasta&end=1&dur=480&kind=timer"), now), { title: "Pasta", description: "8 min timer" });
});

test("countdown says how far away, not a date", () => {
  assert.equal(describe(p(`label=Trip&end=${now + 10 * 86400}&dur=1&kind=countdown`), now).description, "10 days to go");
  assert.equal(describe(p(`label=Trip&end=${now - 5}&dur=1&kind=countdown`), now).description, "Countdown finished");
});

test("paused and annual", () => {
  assert.equal(describe(p("label=Tea&end=1&dur=300&kind=timer&paused=120"), now).description, "5 min timer · paused");
  assert.equal(describe(p(`label=Mum&end=${now + 3 * 86400}&dur=1&kind=countdown&annual={}`), now).description, "3 days to go · every year");
});

test("sequence", () => {
  const seq = JSON.stringify({ version: 1, sequence: { phases: [{ label: "Focus" }, { label: "Break" }], loopCount: 4, phaseIndex: 0, loopIndex: 0 } });
  assert.equal(describe(p({ label: "Focus", end: "1", dur: "1500", kind: "timer", seq }), now).description, "2 phases · 4 loops");
});

test("no label or bad end leaves the page alone", () => {
  assert.equal(describe(p("end=1"), now), null);
  assert.equal(describe(p("label=X&end=abc"), now), null);
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
  const { points } = await run("/timer?label=Pasta&end=1&dur=480&kind=timer", { ua: "facebookexternalhit/1.1 Facebot Twitterbot/1.0" });
  assert.deepEqual(points, [{ blobs: ["preview"], indexes: ["link"] }]);
  assert.equal(JSON.stringify(points).includes("Pasta"), false);
});

test("nothing is counted for other pages, bad links, errors or HEAD", async () => {
  for (const [path, opts] of [
    ["/timer/privacy", {}],
    ["/timer/status", {}],
    ["/timer?end=1", {}],
    ["/timer?label=Pasta&end=1", { status: 404 }],
    ["/timer?label=Pasta&end=1", { method: "HEAD" }],
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
