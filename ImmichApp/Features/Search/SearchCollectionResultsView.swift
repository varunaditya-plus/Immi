import SwiftUI

enum SearchResultKind: String { case photos, collections }

enum SearchCollectionDestination: Identifiable {
    case album(AlbumResponseDTO)
    case person(PersonDTO)
    case group(PeopleGroup)
    case folder(AlbumFolder)
    case recentlyViewed

    var id: String {
        switch self {
        case .album(let album): "album:\(album.id)"
        case .person(let person): "person:\(person.id)"
        case .group(let group): "group:\(group.id)"
        case .folder(let folder): "folder:\(folder.id)"
        case .recentlyViewed: "recently-viewed"
        }
    }
}

struct SearchCollectionResultsView: View {
    let people: [PersonDTO]
    let albums: [AlbumResponseDTO]
    let groups: [PeopleGroup]
    let folders: [AlbumFolder]
    let allPeople: [PersonDTO]
    var isLoading = false
    var error: String? = nil
    var onRetry: () -> Void = {}
    let onOpen: (SearchCollectionDestination) -> Void

    var body: some View {
        if people.isEmpty && albums.isEmpty && groups.isEmpty && folders.isEmpty {
            if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error {
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("Retry", action: onRetry) }
            } else {
                ContentUnavailableView("No Results", systemImage: "rectangle.stack",
                    description: Text("Try a different search."))
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !people.isEmpty {
                        sectionTitle("People")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
                            ForEach(people) { person in
                                Button { onOpen(.person(person)) } label: {
                                    VStack(spacing: 8) {
                                        AuthImage(assetId: person.id, path: "/people/\(person.id)/thumbnail")
                                            .frame(width: 90, height: 90).clipShape(.circle)
                                        Text(person.name).font(.subheadline).lineLimit(2)
                                    }
                                }
                                .buttonStyle(.plain).accessibilityLabel(person.name)
                            }
                        }
                    }
                    if !albums.isEmpty {
                        sectionTitle("Albums")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 18) {
                            ForEach(albums) { album in
                                Button { onOpen(.album(album)) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        albumCover(album)
                                        Text(album.albumName).font(.subheadline.weight(.medium)).lineLimit(2)
                                        Text(album.assetCount.formatted()).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain).accessibilityLabel(album.albumName)
                            }
                        }
                    }
                    if !groups.isEmpty {
                        sectionTitle("Groups")
                        ForEach(groups) { group in
                            Button { onOpen(.group(group)) } label: {
                                Label(group.title(in: allPeople), systemImage: "person.3.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !folders.isEmpty {
                        sectionTitle("Folders")
                        ForEach(folders) { folder in
                            Button { onOpen(.folder(folder)) } label: {
                                Label(folder.name, systemImage: "folder.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    private func albumCover(_ album: AlbumResponseDTO) -> some View {
        Color(.tertiarySystemFill).aspectRatio(1, contentMode: .fit)
            .overlay {
                if let id = album.albumThumbnailAssetId, AssetVisibilityPolicy(scope: .timeline).allows(id: id) {
                    AuthImage(assetId: id).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } else { Image(systemName: "rectangle.stack.fill").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .clipShape(.rect(cornerRadius: 16))
    }
}
