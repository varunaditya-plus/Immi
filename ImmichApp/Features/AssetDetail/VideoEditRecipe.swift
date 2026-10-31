import AVFoundation
import Foundation

struct VideoEditRecipe: Codable, Equatable, Sendable {
    var trimStart: Double = 0
    var trimEnd: Double? = nil
    var rate: Double = 1
    var isMuted = false

    var isIdentity: Bool { trimStart == 0 && trimEnd == nil && rate == 1 && !isMuted }

    enum TrimBoundary { case start, end }
    mutating func setTrimBoundary(_ boundary: TrimBoundary, to time: Double, duration: Double, frameRate: Double) {
        guard time.isFinite, duration.isFinite, duration > 0, frameRate.isFinite, frameRate > 0 else { return }
        switch boundary {
        case .start:
            let end = min(trimEnd ?? duration, duration)
            let gap = min(1 / frameRate, end)
            trimStart = min(max(time, 0), max(0, end - gap))
        case .end:
            let gap = min(1 / frameRate, duration - trimStart)
            trimEnd = min(max(time, trimStart + gap), duration)
        }
    }

    func selection(duration: Double) throws -> CMTimeRange {
        let end = trimEnd ?? duration
        guard duration.isFinite, duration > 0, trimStart.isFinite, end.isFinite,
              trimStart >= 0, trimStart < duration, end <= duration + 0.001, min(end, duration) > trimStart,
              rate.isFinite, (0.1...4).contains(rate) else { throw MediaVideoEditError.invalidSelection }
        let range = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 60_000),
            end: CMTime(seconds: min(end, duration), preferredTimescale: 60_000))
        guard range.duration.seconds > 0 else { throw MediaVideoEditError.invalidSelection }
        return range
    }
}

enum MediaVideoEditError: LocalizedError {
    case invalidSelection
    case unavailableVideo
    case exportUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidSelection: String(localized: "Choose a valid video range and playback speed.")
        case .unavailableVideo: String(localized: "This video could not be loaded.")
        case .exportUnavailable: String(localized: "This video cannot be exported in a supported format.")
        case .exportFailed: String(localized: "The edited video could not be saved.")
        }
    }
}
