import Foundation

/// Versioned UTF-8 JSON used by both the seq URL parameter and CloudKit's
/// sequenceData field. Existing scalar fields remain usable by older clients.
enum TimerSequenceWire {
    struct Envelope: Codable {
        let version: Int
        let sequence: SequenceInfo
    }
    static let maximumBytes = 65_536
    static let maximumPhases = 64
    static let maximumLoops = 99
    static let maximumOccurrences = maximumPhases * maximumLoops

    static func isValid(_ sequence: SequenceInfo) -> Bool {
        guard (1...maximumPhases).contains(sequence.phases.count),
              (1...maximumLoops).contains(sequence.loopCount),
              (0..<sequence.phases.count).contains(sequence.phaseIndex),
              (0...sequence.loopCount).contains(sequence.loopIndex) else { return false }
        return sequence.phases.allSatisfy {
            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.utf8.count <= 512 &&
            $0.duration.isFinite && (1...31_536_000).contains($0.duration)
        }
    }

    static func encode(_ sequence: SequenceInfo) -> Data? {
        guard isValid(sequence), let data = try? JSONEncoder().encode(Envelope(version: 1, sequence: sequence)),
              data.count <= maximumBytes else { return nil }
        return data
    }
    static func decode(_ data: Data) -> SequenceInfo? {
        guard data.count <= maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, isValid(envelope.sequence) else { return nil }
        return envelope.sequence
    }
}
