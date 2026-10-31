import Foundation

struct PhotoSlideshowPresentation: Identifiable {
    let id = UUID()
    let assets: [AssetLite]
    var initialAssetID: String? = nil
}
