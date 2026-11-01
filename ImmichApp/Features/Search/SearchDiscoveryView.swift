import SwiftUI

struct SearchDiscoveryView: View {
    let people: [PersonDTO]
    let cities: [String]
    let recentStore: RecentlyViewedStore?
    let isLoading: Bool
    let error: String?
    let onSuggestion: (SearchToken) -> Void
    let onRecent: () -> Void
    let onRetry: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var personNameWidth: CGFloat = 90

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let recentStore { SearchRecentsView(store: recentStore, onOpen: onRecent) }
                if !namedPeople.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("People").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(namedPeople) { person in
                                    Button { onSuggestion(.person(person)) } label: {
                                        VStack(spacing: 8) {
                                            AuthImage(assetId: person.id, path: "/people/\(person.id)/thumbnail")
                                                .frame(width: 80, height: 80).clipShape(.circle)
                                            Text(person.name).font(.subheadline)
                                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .containerRelativeFrame(.horizontal) { width, _ in min(personNameWidth, width) }
                                        }
                                    }
                                    .buttonStyle(.plain).accessibilityLabel(person.name)
                                }
                            }
                        }
                    }
                }
                if !cities.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Places").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        SearchPlaceSuggestions(cities: Array(cities.prefix(12)), onSelect: { onSuggestion(.city($0)) })
                    }
                }
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
                if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry", action: onRetry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var namedPeople: [PersonDTO] { Array(people.filter { !$0.isHidden && !$0.name.isEmpty }.prefix(12)) }
}

private struct SearchPlaceSuggestions: View {
    let cities: [String]
    let onSelect: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(minimum: 0), alignment: .leading)]
            : [GridItem(.adaptive(minimum: 140), alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(cities, id: \.self) { city in
                Button { onSelect(city) } label: {
                    Label(city, systemImage: "mappin.and.ellipse")
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.subheadline)
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }
}
