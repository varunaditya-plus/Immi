import Foundation
import CoreMedia

struct LivePhotoEditRecipe: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case live, off, loop, bounce, longExposure
        var id: Self { self }
        var title: String {
            switch self {
            case .live: String(localized: "Live")
            case .off: String(localized: "Live Off")
            case .loop: String(localized: "Loop")
            case .bounce: String(localized: "Bounce")
            case .longExposure: String(localized: "Long Exposure")
            }
        }
    }

    var mode: Mode = .live
    var keyPhotoTime: Double? = nil
    var isIdentity: Bool { mode == .live && keyPhotoTime == nil }

    mutating func selectKeyPhoto(at time: Double, originalPhotoTime: Double, selection: CMTimeRange) {
        guard time.isFinite, originalPhotoTime.isFinite,
              time >= selection.start.seconds, time <= selection.end.seconds else { return }
        let selected = CMTime(seconds: time, preferredTimescale: 60_000)
        let original = CMTime(seconds: originalPhotoTime, preferredTimescale: 60_000)
        let isOriginal = originalPhotoTime >= selection.start.seconds && originalPhotoTime < selection.end.seconds
            && CMTimeCompare(selected, original) == 0
        keyPhotoTime = isOriginal ? nil : time
    }

    func validatedPhotoTime(video: VideoEditRecipe, duration: Double) throws -> Double {
        let range = try video.selection(duration: duration)
        let time = keyPhotoTime ?? min(max(duration / 2, range.start.seconds), range.end.seconds)
        guard time.isFinite, time >= range.start.seconds, time <= range.end.seconds else {
            throw MediaVideoEditError.invalidSelection
        }
        return time
    }
}
