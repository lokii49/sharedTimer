//
//  ShareCounter.swift
//  sharedTimer
//
//  Anonymous count of shared timer links. Each completed share sends one empty POST;
//  the server (share-counter/ at the repo root) only adds 1 to today's total. No timer
//  data, identifiers or device details are sent. App + Messages only: excluded from the
//  Clip (never shares) and the Widget (must stay network-free).
//

import Foundation

enum ShareCounter {
    private static let endpoint = URL(string: "https://mirrornotes.org/api/timer/share")!

    /// Fire-and-forget; a failed count is simply lost. Debug builds don't count, so
    /// development and testing never inflate the numbers.
    static func recordShare() {
        #if !DEBUG
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request).resume()
        session.finishTasksAndInvalidate()
        #endif
    }
}
