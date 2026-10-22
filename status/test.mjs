import { test } from "node:test";
import assert from "node:assert/strict";
import { appBlock, lastDays, linkSeries, mergeInstances, parseTsv, reducers } from "./lib.mjs";

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

test("installs count first-time downloads only, not redownloads, updates or deletes", () => {
  const rows = parseTsv(
    tsv(
      ["Date", "Event", "Download Type", "Counts"],
      ["2026-10-01", "Install", "First-time download", "9"],
      ["2026-10-01", "Install", "Redownload", "3"],
      ["2026-10-01", "Install", "Manual update", "20"],
      ["2026-10-01", "Delete", "First-time download", "2"]
    )
  );
  assert.deepEqual(reducers.installs(rows).get("2026-10-01"), { installs: 9 });
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
  const app = appBlock({ days, sessions, installs: new Map(), clip: new Map(), latestProcessingDate: "2026-10-04" });
  assert.deepEqual(app.sessions, [null, 8, null, null, null]);
  assert.equal(app.reportedThrough, "2026-10-03");
  assert.equal(app.completeThrough, "2026-09-28");
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
