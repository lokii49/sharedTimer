//
//  SharedTimerWidgetBundle.swift
//  sharedTimerWidget
//

import WidgetKit
import SwiftUI

@main
struct SharedTimerWidgetBundle: WidgetBundle {
    var body: some Widget {
        SharedTimerWidget()
        SharedTimerCountdownWidget()
        TimerLiveActivityWidget()
    }
}
