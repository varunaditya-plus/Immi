import AVFoundation
import Photos

@MainActor
enum EditedLivePhotoResult {
    case original
    case off
    case native(PHLivePhoto, isMuted: Bool, ownedURLs: [URL])
    case movie(AVPlayerItem, isMuted: Bool, loops: Bool, ownedURLs: [URL])
    case unavailable

    var ownedURLs: [URL] {
        switch self {
        case .native(_, _, let urls), .movie(_, _, _, let urls): urls
        default: []
        }
    }
}
