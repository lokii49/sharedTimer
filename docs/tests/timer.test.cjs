const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const script = fs.readFileSync(path.join(__dirname, '../t.html'), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const epoch = 1800000000;
const phases = [
  { label: 'Work & focus 💫', kind: 'timer', duration: 60, alarmEnabled: true, vibrationEnabled: false },
  { label: 'Rest / tea', kind: 'timer', duration: 30, alarmEnabled: false, vibrationEnabled: true }
];
function page(extra = {}) {
  let now = epoch;
  let callback;
  let intervalCount = 0;
  const elements = Object.fromEntries(['label', 'clock', 'status', 'phase', 'calendar'].map(id => [id, { textContent: '', hidden: true }]));
  const classes = new Set();
  const document = { title: '', getElementById: id => elements[id], body: { dataset: {}, style: {}, classList: {
    toggle(name, value) { value ? classes.add(name) : classes.delete(name); }
  } } };
  const params = new URLSearchParams({ label: 'Sequence', end: String(epoch + 60), dur: '60', kind: 'timer', ...extra });
  class TestDate extends Date { static now() { return now * 1000; } }
  const context = vm.createContext({ document, window: { location: { search: '?' + params } }, Date: TestDate,
    URLSearchParams, TextEncoder, Blob, URL: { createObjectURL() { return 'blob:calendar'; }, revokeObjectURL() {} }, setInterval(fn) { intervalCount++; callback = fn; return 1; }, clearInterval() { callback = null; } });
  vm.runInContext(script, context);
  return { context, elements, document, classes, intervalCount, advance(seconds) { now = epoch + seconds; if (callback) callback(); } };
}
function seq(overrides = {}) {
  return JSON.stringify({ version: 1, sequence: { phases, loopCount: 3, phaseIndex: 0, loopIndex: 0, ...overrides } });
}
test('sequence changes phases and loops from its shared boundary', () => {
  const p = page({ seq: seq() });
  assert.equal(p.elements.label.textContent, phases[0].label);
  assert.equal(p.elements.phase.textContent, 'Phase 1 of 2 · Loop 1 of 3');
  p.advance(60);
  assert.equal(p.elements.label.textContent, phases[1].label);
  assert.equal(p.elements.phase.textContent, 'Phase 2 of 2 · Loop 1 of 3');
  p.advance(200);
  assert.equal(p.elements.phase.textContent, 'Phase 1 of 2 · Loop 3 of 3');
  p.advance(270);
  assert.equal(p.elements.phase.textContent, 'Sequence complete');
  assert.equal(p.elements.clock.textContent, '00:00');
  assert(p.classes.has('done'));
});
test('late opening catches up across several phase boundaries', () => {
  const p = page({ seq: seq(), end: String(epoch - 150) });
  assert.equal(p.elements.phase.textContent, 'Phase 1 of 2 · Loop 3 of 3');
  assert.equal(p.elements.clock.textContent, '00:30');
});
test('paused sequence preserves its current phase and frozen time', () => {
  const p = page({ seq: seq({ phaseIndex: 1, loopIndex: 1 }), end: String(epoch - 100), paused: '25' });
  assert.equal(p.elements.phase.textContent, 'Phase 2 of 2 · Loop 2 of 3');
  assert.equal(p.elements.status.textContent, 'Paused');
  assert.equal(p.elements.clock.textContent, '00:25');
  assert.equal(p.intervalCount, 0);
});
test('scheduled sequence counts to start before showing phase time', () => {
  const p = page({ seq: seq(), start: String(epoch + 120), end: String(epoch + 180) });
  assert.equal(p.elements.phase.textContent, '2 phases · 3 loops');
  assert(p.elements.status.textContent.startsWith('Starts '));
  assert.equal(p.elements.clock.textContent, '02:00');
  p.advance(120);
  assert.equal(p.elements.phase.textContent, 'Phase 1 of 2 · Loop 1 of 3');
  assert.equal(p.elements.clock.textContent, '01:00');
});
test('plain running and paused links retain their display', () => {
  const p = page();
  assert.equal(p.elements.clock.textContent, '01:00');
  assert.equal(p.elements.phase.hidden, true);
  assert.equal(page({ paused: '80' }).elements.clock.textContent, '01:20');
});
test('expired links render without starting an interval or throwing', () => {
  const p = page({ end: String(epoch - 1) });
  assert.equal(p.elements.status.textContent, "Time's up");
  assert.equal(p.intervalCount, 0);
  const done = page({ seq: seq(), end: String(epoch - 1000) });
  assert.equal(done.elements.phase.textContent, 'Sequence complete');
  assert.equal(done.intervalCount, 0);
});
test('invalid definitions and unsupported versions fail clearly', () => {
  for (const value of ['bad', '{}', JSON.stringify({ version: 2, sequence: { phases, loopCount: 3, phaseIndex: 0, loopIndex: 0 } }), seq({ loopCount: 1e20 }), seq({ phases: [] }), seq({ phaseIndex: -1 })]) {
    const p = page({ seq: value });
    assert.equal(p.elements.clock.textContent, '--:--');
    assert.equal(p.intervalCount, 0);
    assert(p.elements.status.textContent.includes('invalid'));
  }
});
test('Unicode and HTML in phase labels remain plain text', () => {
  const p = page({ seq: seq({ phases: [{ ...phases[0], label: '<script>alert(1)</script> 💫' }] }) });
  assert.equal(p.elements.label.textContent, '<script>alert(1)</script> 💫');
});

function annualRule(overrides = {}) {
  return JSON.stringify({ version: 1, recurrence: { month: 2, day: 29, hour: 9, minute: 30, second: 0, timeZoneID: 'GMT', ...overrides } });
}
function evaluate(p, js) { return vm.runInContext(js, p.context); }
test('yearly links catch up missed years and keep paused occurrences frozen', () => {
  const p = page({ kind: 'countdown', annual: annualRule(), end: String(Date.parse('2020-02-29T09:30:00Z') / 1000) });
  assert.equal(p.elements.phase.textContent, 'Repeats yearly · GMT');
  assert(!p.classes.has('done'));
  assert.equal(evaluate(p, 'nextAnnual(recurrence, Date.parse("2029-02-28T09:30:00Z") / 1000)'), Date.parse('2030-02-28T09:30:00Z') / 1000);
  const paused = page({ kind: 'countdown', annual: annualRule(), end: String(epoch - 100), paused: '25' });
  assert.equal(paused.elements.clock.textContent, '00:25');
  assert.equal(paused.intervalCount, 0);
  assert(paused.elements.calendar.hidden);
});
test('yearly leap day and daylight-saving match the native calendar rules', () => {
  const p = page();
  const leap = JSON.parse(annualRule()).recurrence;
  p.context.rule = leap;
  assert.equal(evaluate(p, 'annualDate(rule, 2029)'), Date.parse('2029-02-28T09:30:00Z') / 1000);
  assert.equal(evaluate(p, 'annualDate(rule, 2032)'), Date.parse('2032-02-29T09:30:00Z') / 1000);
  p.context.rule = { ...leap, month: 3, day: 14, hour: 2, minute: 30, timeZoneID: 'America/New_York' };
  assert.equal(evaluate(p, 'annualDate(rule, 2027)'), Date.parse('2027-03-14T07:00:00Z') / 1000);
  p.context.rule = { ...leap, month: 11, day: 1, hour: 1, minute: 30, timeZoneID: 'America/New_York' };
  assert.equal(evaluate(p, 'annualDate(rule, 2026)'), Date.parse('2026-11-01T05:30:00Z') / 1000);
});
test('invalid annual links and mixed sequences are rejected', () => {
  for (const annual of [annualRule({ month: 13 }), annualRule({ day: 30 }), annualRule({ hour: 24 }), annualRule({ timeZoneID: 'No/Such_Zone' }), '{}', 'x'.repeat(2049)]) {
    const p = page({ kind: 'countdown', annual });
    assert(p.elements.status.textContent.includes('invalid'));
    assert(p.elements.calendar.hidden);
  }
  assert(page({ seq: seq(), annual: annualRule() }).elements.status.textContent.includes('invalid'));
  assert(page({ annual: annualRule() }).elements.status.textContent.includes('invalid'));
});
test('plain Calendar export is a UTC event with escaped and folded text', () => {
  const p = page({ kind: 'countdown' });
  p.context.title = 'Birthday 🎉 '.repeat(12) + '\r\nBEGIN:VEVENT;hello,world\\';
  const ics = evaluate(p, 'calendarICS(title, 1800000000, null, "test-id")');
  assert(ics.startsWith('BEGIN:VCALENDAR\r\nVERSION:2.0\r\n'));
  assert(ics.endsWith('END:VCALENDAR\r\n'));
  assert(ics.includes('DTSTART:20270115T080000Z\r\n'));
  assert.equal((ics.match(/\r\nBEGIN:VEVENT\r\n/g) || []).length, 1);
  assert(ics.includes('\\nBEGIN:VEVENT\\;hello\\,world\\\\'));
  assert(ics.split('\r\n').every(line => Buffer.byteLength(line) <= 75));
  assert(!ics.includes('RRULE:'));
});
test('annual Calendar export carries its time zone and leap-day recurrence', () => {
  const p = page();
  p.context.rule = JSON.parse(annualRule({ timeZoneID: 'America/New_York' })).recurrence;
  const ics = evaluate(p, 'calendarICS("Birthday", annualDate(rule, 2028), rule, "annual-id")');
  assert(ics.includes('BEGIN:VTIMEZONE\r\nTZID:America/New_York\r\n'));
  assert(ics.includes('BEGIN:DAYLIGHT\r\n'));
  assert(ics.includes('BEGIN:STANDARD\r\n'));
  assert(ics.includes('DTSTART;TZID=America/New_York:20280229T093000\r\n'));
  assert(ics.includes('RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1\r\n'));
  assert(ics.split('\r\n').every(line => Buffer.byteLength(line) <= 75));
});
test('a shifted first occurrence does not shift subsequent Calendar anniversaries', () => {
  const p = page();
  p.context.rule = JSON.parse(annualRule()).recurrence;
  const ics = evaluate(p, 'calendarICS("Birthday", annualDate(rule, 2028) + 60, rule)');
  assert(ics.includes('DTSTART;TZID=GMT:20280229T093000\r\n'));
  assert(ics.includes('EXDATE:20280229T093000Z\r\n'));
  assert(ics.includes('RDATE:20280229T093100Z\r\n'));
});
test('Calendar download appears for countdowns and stays hidden for timers and pauses', () => {
  const countdown = page({ kind: 'countdown' });
  assert(!countdown.elements.calendar.hidden);
  assert.equal(countdown.elements.calendar.href, 'blob:calendar');
  assert(page().elements.calendar.hidden);
  assert(page({ kind: 'countdown', paused: '10' }).elements.calendar.hidden);
});
test('Calendar export explicitly includes anniversary times inside a daylight-saving gap', () => {
  const p = page();
  p.context.rule = JSON.parse(annualRule({ month: 3, day: 14, hour: 2, minute: 30, timeZoneID: 'America/New_York' })).recurrence;
  const ics = evaluate(p, 'calendarICS("Anniversary", annualDate(rule, 2026), rule)');
  assert(ics.includes('EXDATE:20270314T073000Z\r\n'));
  assert(ics.includes('RDATE:20270314T070000Z\r\n'));
  const initialGap = evaluate(p, 'calendarICS("Anniversary", annualDate(rule, 2027), rule)');
  assert(initialGap.includes('DTSTART;TZID=America/New_York:20280314T023000\r\n'));
  assert(initialGap.includes('RDATE:20270314T070000Z\r\n'));
  assert(!initialGap.includes('EXDATE:20280314T063000Z\r\n'));
});
test('Calendar export never excludes the valid time replacing a spring gap', () => {
  const p = page();
  p.context.rule = JSON.parse(annualRule({ month: 3, day: 14, hour: 2, minute: 0, timeZoneID: 'America/New_York' })).recurrence;
  const ics = evaluate(p, 'calendarICS("Anniversary", annualDate(rule, 2026), rule)');
  assert(ics.includes('RDATE:20270314T070000Z\r\n'));
  assert(!ics.includes('EXDATE:20270314T070000Z\r\n'));
});
test('Calendar export chooses the first autumn time without excluding it', () => {
  const p = page();
  p.context.rule = JSON.parse(annualRule({ month: 11, day: 1, hour: 1, minute: 30, timeZoneID: 'America/New_York' })).recurrence;
  const ics = evaluate(p, 'calendarICS("Anniversary", annualDate(rule, 2026), rule)');
  assert(ics.includes('RDATE:20261101T053000Z\r\n'));
  assert(ics.includes('EXDATE:20261101T063000Z\r\n'));
  assert(!ics.includes('EXDATE:20261101T053000Z\r\n'));
});
test('fixed-offset time zones from Calendar remain valid on the web and in export', () => {
  const p = page({ kind: 'countdown', annual: annualRule({ timeZoneID: 'GMT+0530' }) });
  assert(!p.elements.status.textContent.includes('invalid'));
  p.context.rule = JSON.parse(annualRule({ timeZoneID: 'GMT+0530' })).recurrence;
  assert.equal(evaluate(p, 'annualDate(rule, 2029)'), Date.parse('2029-02-28T04:00:00Z') / 1000);
  const ics = evaluate(p, 'calendarICS("Birthday", annualDate(rule, 2029), rule)');
  assert(ics.includes('TZID:GMT+0530\r\n'));
  assert(ics.includes('TZOFFSETTO:+0530\r\n'));
});
