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
function page(extra = {}, env = {}) {
  let now = epoch;
  let callback;
  let intervalCount = 0;
  const elements = Object.fromEntries(['label', 'clock', 'status', 'phase', 'calendar', 'open'].map(id => [id, { textContent: '', hidden: true }]));
  const classes = new Set();
  const document = { title: '', getElementById: id => elements[id], body: { dataset: {}, style: {}, classList: {
    toggle(name, value) { value ? classes.add(name) : classes.delete(name); }
  } } };
  const params = new URLSearchParams({ id: 'test-id', label: 'Sequence', end: String(epoch + 60), dur: '60', kind: 'timer', ...extra });
  // env.search: a raw query string, as the app's URLComponents would see it.
  const search = env.search !== undefined ? env.search : '?' + params;
  class TestDate extends Date { static now() { return now * 1000; } }
  const context = vm.createContext({ document, window: { location: { search, host: env.host || 'mirrornotes.org' } }, Date: TestDate,
    ...(env.navigator ? { navigator: env.navigator } : {}),
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
  // Over an hour past the end: no overtime count, so nothing left to tick.
  const p = page({ end: String(epoch - 3601) });
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
test('numbers parse strictly and out-of-range values are rejected like the app', () => {
  assert.equal(page({ end: String(epoch + 60) + 'abc' }).elements.status.textContent, 'No timer data in this link.');
  assert(page({ paused: '-5' }).elements.status.textContent.includes('invalid'));
  assert(page({ dur: '0' }).elements.status.textContent.includes('invalid'));
  assert.equal(page({ paused: '80' }).elements.clock.textContent, '01:20');
});
// Verdicts from the app's own TimerPayload.from(url:) (TimerModel.swift,
// TimerSequenceWire.swift and AnnualRecurrence.swift compiled with swiftc on macOS,
// fed these exact query strings, 2026-11-13). The page must accept exactly the same.
test('the page accepts exactly the links the app accepts', () => {
  const E = 4102444800;
  const ph = (o = {}) => ({ label: 'Work', kind: 'timer', duration: 60, alarmEnabled: true, vibrationEnabled: false, ...o });
  const sq = (ps, extra = {}) => encodeURIComponent(JSON.stringify({ version: 1, sequence: { phases: ps, loopCount: 2, phaseIndex: 0, loopIndex: 0, ...extra } }));
  const base = `id=a&label=L&end=${E}&dur=60`;
  const cases = [
    ['plain', base, true],
    ['no dur', `id=a&label=L&end=${E}`, true],
    ['end 1e300', 'id=a&label=L&end=1e300&dur=60', false],
    ['end inf', 'id=a&label=L&end=inf&dur=60', false],
    ['end %20n', `id=a&label=L&end=%20${E}&dur=60`, false],
    ['end +n', `id=a&label=L&end=+${E}&dur=60`, true],
    ['end hex', 'id=a&label=L&end=0xF486C380&dur=60', true],
    ['end 0X hex', 'id=a&label=L&end=0XF486C380&dur=60', false],
    ['end trailing %20', `id=a&label=L&end=${E}%20&dur=60`, false],
    ['end empty', 'id=a&label=L&end=&dur=60', false],
    ['dur 1e13', `id=a&label=L&end=${E}&dur=1e13`, false],
    ['dur 1e12', `id=a&label=L&end=${E}&dur=1e12`, true],
    ['dur nan', `id=a&label=L&end=${E}&dur=nan`, false],
    ['dur inf', `id=a&label=L&end=${E}&dur=inf`, false],
    ['dur abc', `id=a&label=L&end=${E}&dur=abc`, true],
    ['dur 0', `id=a&label=L&end=${E}&dur=0`, false],
    ['dur %2060', `id=a&label=L&end=${E}&dur=%2060`, true],
    ['paused 1e13', `${base}&paused=1e13`, false],
    ['paused 1e12', `${base}&paused=1e12`, true],
    ['paused -1', `${base}&paused=-1`, false],
    ['paused nan', `${base}&paused=NaN`, false],
    ['paused abc', `${base}&paused=abc`, true],
    ['ext 1e300', `${base}&ext=1e300`, true],
    ['no id', `label=L&end=${E}&dur=60`, false],
    ['empty id', `id=&label=L&end=${E}&dur=60`, false],
    ['id 513 bytes', `id=${'a'.repeat(513)}&label=L&end=${E}&dur=60`, false],
    ['id 512 bytes', `id=${'a'.repeat(512)}&label=L&end=${E}&dur=60`, true],
    ['no label', `id=a&end=${E}&dur=60`, false],
    ['label without =', `id=a&label&end=${E}&dur=60`, false],
    ['empty label', `id=a&label=&end=${E}&dur=60`, true],
    ['phase label U+0085', `${base}&seq=${sq([ph({ label: '\u0085' })])}`, false],
    ['phase label U+200B', `${base}&seq=${sq([ph({ label: '\u200B' })])}`, false],
    ['phase label U+FEFF', `${base}&seq=${sq([ph({ label: '\uFEFF' })])}`, true],
    ['phase label U+3000', `${base}&seq=${sq([ph({ label: '\u3000' })])}`, false],
    ['phase without kind', `${base}&seq=${sq([{ label: 'W', duration: 60, alarmEnabled: true, vibrationEnabled: true }])}`, true],
    ['phase without toggles', `${base}&seq=${sq([{ label: 'W', kind: 'countdown', duration: 60 }])}`, true],
    ['phase null kind', `${base}&seq=${sq([ph({ kind: null })])}`, true],
    ['phase bad kind', `${base}&seq=${sq([ph({ kind: 'bogus' })])}`, false],
    ['phase numeric toggle', `${base}&seq=${sq([ph({ alarmEnabled: 1 })])}`, false],
    ['phase string duration', `${base}&seq=${sq([ph({ duration: '60' })])}`, false],
    ['sequence without indices', `${base}&seq=${encodeURIComponent(JSON.stringify({ version: 1, sequence: { phases: [ph()] } }))}`, true],
    ['sequence loopCount 2.5', `${base}&seq=${sq([ph()], { loopCount: 2.5 })}`, false],
    ['start empty', `${base}&seq=${sq([ph()])}&start=`, false],
    ['start abc', `${base}&seq=${sq([ph()])}&start=abc`, false],
    ['start without =', `${base}&seq=${sq([ph()])}&start`, true],
    ['start past', `${base}&seq=${sq([ph()])}&start=1000`, true],
    ['start ignored without seq', `${base}&start=abc`, true],
  ];
  for (const [name, query, accepted] of cases) {
    const p = page({}, { search: '?' + query });
    const status = p.elements.status.textContent;
    const rendered = !status.includes('invalid') && status !== 'No timer data in this link.';
    assert.equal(rendered, accepted, `${name}: ${status}`);
    assert.equal(p.elements.open.hidden, !accepted, `${name}: Open in Timer`);
  }
  // Defaults the app fills in for a phase are what the page shows.
  const p = page({}, { search: `?${base}&seq=${sq([{ label: 'W', duration: 90 }])}` });
  assert.equal(p.elements.label.textContent, 'W');
  assert.equal(p.elements.phase.textContent, 'Phase 1 of 1 · Loop 1 of 2');
});
test('an extended link drains against the whole run without throwing', () => {
  const p = page({ end: String(epoch + 240), dur: '300', ext: '300' });
  assert.equal(p.elements.clock.textContent, '04:00');
  assert.equal(p.intervalCount, 1);
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
test('a finished plain timer counts up for an hour, then stops', () => {
  const p = page({});  // ends at epoch + 60
  p.advance(60 + 133);
  assert.equal(p.elements.clock.textContent, '+02:13');
  assert(p.classes.has('done') && p.classes.has('overtime'));
  p.advance(60 + 3600);
  assert.equal(p.elements.clock.textContent, '00:00');
  assert(!p.classes.has('overtime'));
});
test('sequences and paused timers never show overtime', () => {
  const s = page({ seq: seq(), end: String(epoch - 1000) });
  assert(!s.classes.has('overtime'));
  const paused = page({ paused: '0', end: String(epoch - 10) });
  assert(!paused.classes.has('overtime'));
});
test('Open in Timer goes through the old host on iPhone and to the App Store elsewhere', () => {
  const iphone = { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X)', platform: 'iPhone', maxTouchPoints: 5 };
  const onPhone = page({}, { navigator: iphone });
  assert.equal(onPhone.elements.open.hidden, false);
  assert(onPhone.elements.open.href.startsWith('https://lokii49.github.io/sharedTimer/t.html?'));
  assert(onPhone.elements.open.href.includes('end=' + (epoch + 60)));
  const oldHost = page({}, { navigator: iphone, host: 'lokii49.github.io' });
  assert.equal(oldHost.elements.open.href, 'https://apps.apple.com/app/id6804558361');
  const android = page({}, { navigator: { userAgent: 'Mozilla/5.0 (Linux; Android 15)', platform: 'Linux', maxTouchPoints: 5 } });
  assert.equal(android.elements.open.href, 'https://apps.apple.com/app/id6804558361');
  assert.equal(android.elements.open.textContent, 'Get Timer for iPhone');
  const invalid = page({ seq: 'bad' }, { navigator: iphone });
  assert.equal(invalid.elements.open.hidden, true);
});
test('weekly and monthly repeats follow their rule and export a matching RRULE', () => {
  const weekly = annualRule({ frequency: 'weekly', weekday: 3, month: 1, day: 5, hour: 9, minute: 0 });  // Tuesdays 09:00
  const p = page({ kind: 'countdown', repeat: weekly, end: String(Date.parse('2027-01-05T09:00:00Z') / 1000) });
  assert.equal(p.elements.phase.textContent, 'Repeats weekly · GMT');
  assert.equal(evaluate(p, 'nextAnnual(recurrence, Date.parse("2027-03-10T10:00:00Z") / 1000)'), Date.parse('2027-03-16T09:00:00Z') / 1000);
  const ics = evaluate(p, 'calendarICS("Standup", Date.parse("2027-03-16T09:00:00Z") / 1000, recurrence, "x")');
  assert(ics.includes('RRULE:FREQ=WEEKLY;BYDAY=TU'));

  const monthly = annualRule({ frequency: 'monthly', month: 1, day: 31, hour: 9, minute: 0 });
  const m = page({ kind: 'countdown', repeat: monthly, end: String(Date.parse('2027-01-31T09:00:00Z') / 1000) });
  assert.equal(evaluate(m, 'nextAnnual(recurrence, Date.parse("2027-02-01T00:00:00Z") / 1000)'), Date.parse('2027-02-28T09:00:00Z') / 1000);
  assert(evaluate(m, 'calendarICS("Rent", Date.parse("2027-02-28T09:00:00Z") / 1000, recurrence, "x")').includes('BYMONTHDAY=28,29,30,31;BYSETPOS=-1'));
});
test('an extended daily or weekly occurrence exports the rule series plus a moved date', () => {
  const daily = annualRule({ frequency: 'daily', month: 1, day: 4, hour: 9, minute: 0 });
  const p = page({ kind: 'countdown', repeat: daily, end: String(Date.parse('2027-01-04T09:15:00Z') / 1000) });
  const ics = evaluate(p, 'calendarICS("Standup", Date.parse("2027-01-04T09:15:00Z") / 1000, recurrence, "x")');
  assert(ics.includes('DTSTART;TZID=GMT:20270104T090000'), ics);
  assert(ics.includes('EXDATE:20270104T090000Z') && ics.includes('RDATE:20270104T091500Z'));
  // Unextended: no EXDATE/RDATE.
  const plain = evaluate(p, 'calendarICS("Standup", Date.parse("2027-01-05T09:00:00Z") / 1000, recurrence, "x")');
  assert(plain.includes('DTSTART;TZID=GMT:20270105T090000') && !plain.includes('EXDATE') && !plain.includes('RDATE'));
  // Weekly Tuesday 23:30 extended past midnight stays a Tuesday-23:30 series.
  const weekly = annualRule({ frequency: 'weekly', weekday: 3, month: 1, day: 5, hour: 23, minute: 30 });
  const w = page({ kind: 'countdown', repeat: weekly, end: String(Date.parse('2027-01-06T00:30:00Z') / 1000) });
  const wics = evaluate(w, 'calendarICS("Late", Date.parse("2027-01-06T00:30:00Z") / 1000, recurrence, "x")');
  assert(wics.includes('DTSTART;TZID=GMT:20270105T233000') && wics.includes('RDATE:20270106T003000Z'), wics);
});
test('a daily series whose first occurrence falls in a spring gap starts on the rule time', () => {
  // 02:30 doesn't exist in New York on 2027-03-14; the app moves it to 03:00 EDT (07:00Z).
  const daily = annualRule({ frequency: 'daily', month: 3, day: 13, hour: 2, minute: 30, timeZoneID: 'America/New_York' });
  const p = page({ kind: 'countdown', repeat: daily, end: String(Date.parse('2027-03-14T07:00:00Z') / 1000) });
  const ics = evaluate(p, 'calendarICS("Early", Date.parse("2027-03-14T07:00:00Z") / 1000, recurrence, "x")');
  assert(ics.includes('DTSTART;TZID=America/New_York:20270315T023000'), ics);
  // The moved first one is only an RDATE (it's before DTSTART, nothing to exclude);
  // later spring-forward days get their own correction.
  assert(ics.includes('RDATE:20270314T070000Z') && !ics.includes('EXDATE:20270314'), ics);
  assert(ics.includes('RDATE:20280312T070000Z') && ics.includes('EXDATE:20280312T073000Z'), ics);
});
test('a daily series corrects every later spring gap and autumn repeat, in UTC', () => {
  // 02:30 daily in New York: the app rings at 03:00 EDT (07:00Z) on spring-forward days.
  const gap = annualRule({ frequency: 'daily', month: 1, day: 4, hour: 2, minute: 30, timeZoneID: 'America/New_York' });
  const p = page({ kind: 'countdown', repeat: gap, end: String(Date.parse('2027-01-04T07:30:00Z') / 1000) });
  const ics = evaluate(p, 'calendarICS("Early", Date.parse("2027-01-04T07:30:00Z") / 1000, recurrence, "x")');
  assert(ics.includes('DTSTART;TZID=America/New_York:20270104T023000\r\n'), ics);
  for (const day of ['20270314', '20280312', '20290311']) {
    assert(ics.includes(`RDATE:${day}T070000Z\r\n`), day);
    // Both readings of the nonexistent 02:30 are excluded; the app's 03:00 is not.
    assert(ics.includes(`EXDATE:${day}T063000Z\r\n`) && ics.includes(`EXDATE:${day}T073000Z\r\n`), day);
    assert(!ics.includes(`EXDATE:${day}T070000Z`), day);
  }
  // Ordinary days and autumn (02:30 isn't repeated) get nothing.
  assert(!/(EXDATE|RDATE):2027031[35]/.test(ics) && !/(EXDATE|RDATE):20271107/.test(ics));
  // 01:30 daily: the fall-back day's first copy (EDT, 05:30Z) is the app's; the second goes.
  const repeat = annualRule({ frequency: 'daily', month: 1, day: 4, hour: 1, minute: 30, timeZoneID: 'America/New_York' });
  const r = page({ kind: 'countdown', repeat, end: String(Date.parse('2027-01-04T06:30:00Z') / 1000) });
  const rics = evaluate(r, 'calendarICS("Late", Date.parse("2027-01-04T06:30:00Z") / 1000, recurrence, "x")');
  for (const day of ['20271107', '20281105', '20291104']) {
    assert(rics.includes(`RDATE:${day}T053000Z\r\n`), day);
    assert(rics.includes(`EXDATE:${day}T063000Z\r\n`), day);
    assert(!rics.includes(`EXDATE:${day}T053000Z`), day);
  }
  assert(!/(EXDATE|RDATE):20270314/.test(rics), 'spring 01:30 exists');
  // Weekly only on its weekday; monthly only on its day.
  const weekly = annualRule({ frequency: 'weekly', weekday: 1, month: 1, day: 3, hour: 2, minute: 30, timeZoneID: 'America/New_York' }); // Sundays
  const w = page({ kind: 'countdown', repeat: weekly, end: String(Date.parse('2027-01-03T07:30:00Z') / 1000) });
  const wics = evaluate(w, 'calendarICS("Sun", Date.parse("2027-01-03T07:30:00Z") / 1000, recurrence, "x")');
  assert(wics.includes('RDATE:20280312T070000Z\r\n'));
  const tuesday = annualRule({ frequency: 'weekly', weekday: 3, month: 1, day: 5, hour: 2, minute: 30, timeZoneID: 'America/New_York' });
  const t = page({ kind: 'countdown', repeat: tuesday, end: String(Date.parse('2027-01-05T07:30:00Z') / 1000) });
  assert(!evaluate(t, 'calendarICS("Tue", Date.parse("2027-01-05T07:30:00Z") / 1000, recurrence, "x")').includes('RDATE'));
  const monthly = annualRule({ frequency: 'monthly', month: 1, day: 12, hour: 2, minute: 30, timeZoneID: 'America/New_York' });
  const m = page({ kind: 'countdown', repeat: monthly, end: String(Date.parse('2027-01-12T07:30:00Z') / 1000) });
  const mics = evaluate(m, 'calendarICS("12th", Date.parse("2027-01-12T07:30:00Z") / 1000, recurrence, "x")');
  assert(mics.includes('RDATE:20280312T070000Z\r\n') && !mics.includes('20270314T07'));
  assert(mics.split('\r\n').every(line => Buffer.byteLength(line) <= 75));
});
test('a link carrying both annual and repeat, or repeat on a timer, is invalid', () => {
  const weekly = annualRule({ frequency: 'weekly', weekday: 3 });
  assert.equal(page({ kind: 'countdown', annual: annualRule(), repeat: weekly }).elements.clock.textContent, '--:--');
  assert.equal(page({ kind: 'timer', repeat: weekly }).elements.clock.textContent, '--:--');
  assert.equal(page({ kind: 'countdown', repeat: annualRule({ frequency: 'yearly' }) }).elements.clock.textContent, '--:--');
});
