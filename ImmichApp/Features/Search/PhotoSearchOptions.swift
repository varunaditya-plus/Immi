import Foundation

struct PhotoSearchOptions: Equatable, Sendable {
    let sortOrder: LibrarySort
    let favoritesOnly: Bool
    let editedOnly: Bool

    init(sortOrder: LibrarySort = .dateCaptured,
         favoritesOnly: Bool = false, editedOnly: Bool = false) {
        self.sortOrder = sortOrder
        self.favoritesOnly = favoritesOnly
        self.editedOnly = editedOnly
    }

    var libraryOptions: LibraryBrowseOptions {
        var filters = Set<LibraryFilter>()
        if favoritesOnly { filters.insert(.favorites) }
        if editedOnly { filters.insert(.edited) }
        return LibraryBrowseOptions(sort: sortOrder, filters: filters, showsScreenshots: true)
    }
}

enum PhotoSearchError: LocalizedError {
    case missingAddedDates
    case missingEditInformation
    case incompletePage
    case missingCachedSearch
    case unsupportedAlbumVisualSearch

    var errorDescription: String? {
        switch self {
        case .missingAddedDates: String(localized: "The server did not provide added dates for every photo.")
        case .missingEditInformation: String(localized: "The server did not provide edit information for every photo.")
        case .incompletePage: String(localized: "Search returned an incomplete page. Please try again.")
        case .missingCachedSearch: String(localized: "This search changed. Please search again.")
        case .unsupportedAlbumVisualSearch: String(localized: "Visual search within albums requires a stable Immich Server v3.2 or newer.")
        }
    }
}
