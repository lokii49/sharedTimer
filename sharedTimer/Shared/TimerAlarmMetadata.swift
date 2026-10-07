//
//  TimerAlarmMetadata.swift
//  Shared
//
//  Payload carried on an AlarmKit alarm so the alarm's Live Activity / alert can name
//  the timer it belongs to, and so a fired alarm can be traced back to its TimerPayload.
//  Lives in Shared/, compiled by sharedTimer (schedules the alarm) and sharedTimerWidget
//  (renders the AlarmAttributes Live Activity) only.
//

import AlarmKit

struct TimerAlarmMetadata: AlarmMetadata {
    let timerID: String
    let label: String
    /// Optional: an alarm scheduled by an older build (before AlarmKit handled
    /// `.countdown` too) has no `kind` in its persisted metadata. Decodes as nil;
    /// treat nil as `.timer`, the only kind that could have scheduled one back then.
    let kind: TimerKind?
    /// Sequence phases only (nil for a plain timer, and for any alarm scheduled before
    /// 1.0.4): "Phase 1 of 2 · Loop 1 of 4" under the label, plus what the card's
    /// second button needs — the occurrence's global index for "Next"
    /// (`AdvanceSequenceIntent`), and whether it's the last one (then "Cancel",
    /// `EndSequenceIntent`). Optional with defaults so old persisted metadata decodes.
    var sequenceCaption: String? = nil
    var phaseIndex: Int? = nil
    var isFinalPhase: Bool? = nil
}
