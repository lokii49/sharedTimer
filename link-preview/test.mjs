import { test } from "node:test";
import assert from "node:assert/strict";
import { describe } from "./src/index.js";

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
