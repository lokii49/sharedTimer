//
//  TimerAlarmMetadata.swift
//  sharedTimer
//
//  Payload carried on an AlarmKit alarm so the alarm's Live Activity / alert can name
//  the timer it belongs to, and so a fired alarm can be traced back to its TimerPayload.
//  Verbatim copy in sharedTimerWidget (the widget renders the AlarmAttributes Live
//  Activity) — keep the two in sync, same rule as the other duplicated model files.
//

import AlarmKit

struct TimerAlarmMetadata: AlarmMetadata {
    let timerID: String
    let label: String
}
