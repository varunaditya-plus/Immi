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

    func validatedPhotoTime(video: VideoEditRecipe, duration: Double) throws -> Double {
        let range = try video.selection(duration: duration)
        let time = keyPhotoTime ?? min(max(duration / 2, range.start.seconds), range.end.seconds)
        guard time.isFinite, time >= range.start.seconds, time <= range.end.seconds else {
            throw MediaVideoEditError.invalidSelection
        }
        return time
    }
}
