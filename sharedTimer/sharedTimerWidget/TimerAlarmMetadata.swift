//
//  TimerAlarmMetadata.swift
//  sharedTimerWidget
//
//  Payload carried on an AlarmKit alarm so the alarm's Live Activity / alert can name
//  the timer it belongs to, and so a fired alarm can be traced back to its TimerPayload.
//  Verbatim copy in sharedTimer (the app that schedules the alarm) — keep the two in
//  sync, same rule as the other duplicated model files.
//

import AlarmKit

struct TimerAlarmMetadata: AlarmMetadata {
    let timerID: String
    let label: String
    /// Optional: an alarm scheduled by an older build (before AlarmKit handled
    /// `.countdown` too) has no `kind` in its persisted metadata. Decodes as nil;
    /// treat nil as `.timer`, the only kind that could have scheduled one back then.
    let kind: TimerKind?
}
