import { test } from "node:test";
import assert from "node:assert/strict";
import { appBlock, firstReportedDate, lastDays, linkSeries, mergeInstances, parseTsv, reducers, salesBlock, salesInstalls } from "./lib.mjs";

const tsv = (head, ...rows) => [head.join("\t"), ...rows.map((r) => r.join("\t"))].join("\n") + "\n";

test("parses Apple's TSV by header name, case-insensitively", () => {
  const rows = parseTsv(tsv(["Date", "App Name", "Sessions", "Unique Devices"], ["2026-10-01", "Timer", "12", "7"]));
  assert.deepEqual(rows, [{ date: "2026-10-01", "app name": "Timer", sessions: "12", "unique devices": "7" }]);
  assert.deepEqual(parseTsv(""), []);
});

test("sessions sum across dimension rows per date", () => {
  const rows = parseTsv(
    tsv(
      ["Date", "Device", "Territory", "Sessions", "Unique Devices"],
      ["2026-10-01", "iPhone", "US", "10", "5"],
      ["2026-10-01", "iPad", "US", "4", "2"],
      ["2026-10-02", "iPhone", "IN", "6", "5"]
    )
  );
  const m = reducers.sessions(rows);
  assert.deepEqual(m.get("2026-10-01"), { sessions: 14, devices: 7 });
  assert.deepEqual(m.get("2026-10-02"), { sessions: 6, devices: 5 });
});

test("sales installs: this app's first-time downloads only, not redownloads, updates, IAP or other apps", () => {
  const rows = parseTsv(
    tsv(
      ["Provider", "SKU", "Product Type Identifier", "Units", "Apple Identifier", "Parent Identifier", "Country Code"],
      ["APPLE", "timer", "1", "4", "6804558361", " ", "US"],
      ["APPLE", "timer", "1", "2", "6804558361", " ", "IN"],
      ["APPLE", "timer", "1F", "1", "6804558361", " ", "DE"],
      ["APPLE", "timer", "3", "5", "6804558361", " ", "US"],
      ["APPLE", "timer", "7", "40", "6804558361", " ", "US"],
      ["APPLE", "timer.tip", "IA1", "1", "6800000001", "timer", "US"],
      ["APPLE", "other", "1", "9", "6700000000", " ", "US"]
    )
  );
  assert.equal(salesInstalls(rows, 6804558361), 7);
  assert.equal(salesInstalls(rows.filter((r) => r["product type identifier"] === "3"), "6804558361"), 0);
});

test("sales days: a 404 before the newest posted day is 0, after it null", () => {
  const days = lastDays("2026-10-05", 5);
  const block = salesBlock(new Map([["2026-10-01", 3], ["2026-10-02", null], ["2026-10-03", 0], ["2026-10-04", null], ["2026-10-05", null]]), days);
  assert.equal(block.reportedThrough, "2026-10-03");
  assert.deepEqual(block.installs, [3, 0, 0, null, null]);
  assert.deepEqual(salesBlock(new Map(days.map((d) => [d, null])), days).installs, [null, null, null, null, null]);
});

test("App Clip counts card views only", () => {
  const rows = parseTsv(
    tsv(["Date", "App Clip Event Type", "Source Type", "Counts"], ["2026-10-01", "Views", "Messages", "11"], ["2026-10-01", "Sessions", "Messages", "8"])
  );
  assert.deepEqual(reducers.clip(rows).get("2026-10-01"), { clipViews: 11 });
});

test("a newer instance replaces a date instead of adding to it", () => {
  const merged = mergeInstances([
    { processingDate: "2026-10-03", byDate: new Map([["2026-10-01", { sessions: 20 }], ["2026-10-02", { sessions: 5 }]]) },
    { processingDate: "2026-10-02", byDate: new Map([["2026-10-01", { sessions: 15 }]]) },
  ]);
  assert.deepEqual(merged.get("2026-10-01"), { sessions: 20 });
  assert.deepEqual(merged.get("2026-10-02"), { sessions: 5 });
});

test("days Apple has no row for stay null, never 0", () => {
  const days = lastDays("2026-10-05", 5);
  assert.deepEqual(days, ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05"]);
  const sessions = new Map([["2026-10-02", { sessions: 8, devices: 6 }]]);
  const app = appBlock({ days, sessions, clip: new Map(), latestProcessingDate: "2026-10-04" });
  assert.deepEqual(app.sessions, [null, 8, null, null, null]);
  assert.equal(app.reportedThrough, "2026-10-03");
  assert.equal(app.completeThrough, "2026-09-28");
  assert.equal(app.reportedFrom, null);
});

test("reporting start: earliest row of the first instance ever, null once it's out of range", () => {
  const parsed = [
    { processingDate: "2026-10-23", byDate: new Map([["2026-10-22", {}]]) },
    { processingDate: "2026-10-22", byDate: new Map([["2026-10-20", {}], ["2026-10-18", {}]]) },
  ];
  assert.equal(firstReportedDate(parsed, "2026-10-22"), "2026-10-18");
  assert.equal(firstReportedDate(parsed, "2026-09-01"), null);
  assert.equal(firstReportedDate([{ processingDate: "2026-10-22", byDate: new Map() }], "2026-10-22"), null);
  assert.equal(firstReportedDate([], undefined), null);
});

test("link counts: zero after the counter started, null before it", () => {
  const days = lastDays("2026-10-05", 5);
  const at = (d) => String(Date.parse(d + "T00:00:00Z") / 1000);
  const links = linkSeries(
    [
      { day: at("2026-10-03"), kind: "preview", n: "4" },
      { day: at("2026-10-03"), kind: "open", n: "1" },
      { day: at("2026-10-05"), kind: "preview", n: 2 },
    ],
    days
  );
  assert.equal(links.since, "2026-10-03");
  assert.deepEqual(links.previews, [null, null, 4, 0, 2]);
  assert.deepEqual(links.opens, [null, null, 1, 0, 0]);
  assert.deepEqual(linkSeries([], days).previews, [null, null, null, null, null]);
});
