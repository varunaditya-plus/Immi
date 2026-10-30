import SwiftUI

struct FeaturedPhotoCards<Actions: View>: View {
    let assets: [AssetLite]
    let width: CGFloat
    @ViewBuilder let actions: (AssetLite) -> Actions

    @Environment(SessionManager.self) private var session
    @Namespace private var namespace

    var body: some View {
        ForEach(assets) { asset in
            NavigationLink {
                AssetDetailView(currentAsset: asset, assets: assets,
                    visibilityPolicy: AssetVisibilityPolicy(scope: .timeline))
                    .navigationTransition(.zoom(sourceID: asset.id, in: namespace))
                    .toolbarVisibility(.hidden, for: .tabBar)
            } label: {
                AuthImage(assetId: asset.id, thumbhash: asset.thumbhash)
                    .frame(width: width, height: width)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .matchedTransitionSource(id: asset.id, in: namespace)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PhotoAssetAccessibility.label(for: asset))
            .accessibilityValue(PhotoAssetAccessibility.value(for: asset) ?? "")
            .accessibilityHint("Opens the viewer.")
            .contextMenu { actions(asset) } preview: {
                AssetContextPreview(asset: asset, session: session,
                    visibilityPolicy: AssetVisibilityPolicy(scope: .timeline))
            }
        }
    }
}
