import AppIntents
import SwiftUI
import WidgetKit

private let widgetAppGroup = "group.xyz.0xmwehehe.ImmichApp"
private let widgetFavoritesID = "__favorites__"
private let selectedAlbumsKey = "widget.album.selectedIDs"

private struct WidgetSnapshot: Decodable {
    struct Album: Decodable, Identifiable {
        let id: String
        let name: String
        let assetCount: Int
        let imageNames: [String]

        init(id: String, name: String, assetCount: Int, imageNames: [String]) {
            self.id = id
            self.name = name
            self.assetCount = assetCount
            self.imageNames = imageNames
        }

        /// Membaca juga snapshot versi pertama yang hanya punya satu cover.
        /// Widget yang sudah terpasang tidak jadi kosong saat app baru selesai
        /// diperbarui tetapi belum sempat menulis snapshot format baru.
        private enum CodingKeys: String, CodingKey {
            case id, name, assetCount, imageNames, imageName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let oldImage = try container.decodeIfPresent(String.self, forKey: .imageName)
            self.init(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                assetCount: try container.decode(Int.self, forKey: .assetCount),
                imageNames: try container.decodeIfPresent(
                    [String].self, forKey: .imageNames) ?? oldImage.map { [$0] } ?? [])
        }
    }

    struct Memory: Decodable, Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let imageName: String?
    }

    let generatedAt: Date
    let albums: [Album]
    let memories: [Memory]

    static let favorites = Album(
        id: widgetFavoritesID,
        name: String(localized: "Favorites"),
        assetCount: 0,
        imageNames: [])

    static let empty = WidgetSnapshot(
        generatedAt: .distantPast, albums: [favorites], memories: [])

    static func load() -> WidgetSnapshot {
        guard let root = rootURL,
              let data = try? Data(contentsOf: root.appendingPathComponent("snapshot.json"))
        else { return .empty }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WidgetSnapshot.self, from: data)) ?? .empty
    }

    static var rootURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: widgetAppGroup)?
            .appendingPathComponent("Widgets", isDirectory: true)
    }

    static func image(named name: String?) -> UIImage? {
        guard let name, let rootURL else { return nil }
        return UIImage(contentsOfFile: rootURL.appendingPathComponent(name).path)
    }
}

struct AlbumWidgetEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album")
    static let defaultQuery = AlbumWidgetQuery()

    let id: String
    let name: String

    static let favorites = AlbumWidgetEntity(
        id: widgetFavoritesID,
        name: String(localized: "Favorites"))

    var displayRepresentation: DisplayRepresentation {
        id == widgetFavoritesID ? DisplayRepresentation(title: "Favorites")
            : DisplayRepresentation(title: "\(name)")
    }
}

struct AlbumWidgetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumWidgetEntity] {
        availableAlbums
            .filter { identifiers.contains($0.id) }
            .map { AlbumWidgetEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [AlbumWidgetEntity] {
        availableAlbums.map {
            AlbumWidgetEntity(id: $0.id, name: $0.name)
        }
    }

    func defaultResult() async -> AlbumWidgetEntity? {
        .favorites
    }

    private var availableAlbums: [WidgetSnapshot.Album] {
        let albums = WidgetSnapshot.load().albums
        guard !albums.contains(where: { $0.id == widgetFavoritesID }) else {
            return albums
        }
        return [WidgetSnapshot.favorites] + albums
    }
}

struct AlbumWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Album"
    static let description = IntentDescription(
        "Choose an album to shuffle. Favorites is used when no album is selected.")

    @Parameter(title: "Album")
    var album: AlbumWidgetEntity?
}

private struct AlbumEntry: TimelineEntry {
    let date: Date
    let album: WidgetSnapshot.Album?
    let imageName: String?
}

private struct AlbumTimelineProvider: AppIntentTimelineProvider {
    /// WidgetKit tidak menjalankan extension sebagai slideshow real-time.
    /// Foto dijadwalkan berganti sepanjang hari dan iOS menentukan saat render
    /// persisnya berdasarkan refresh budget perangkat.
    private let rotationInterval: TimeInterval = 15 * 60
    private let scheduledEntryCount = 24

    func placeholder(in context: Context) -> AlbumEntry {
        AlbumEntry(
            date: Date(),
            album: .init(
                id: widgetFavoritesID,
                name: String(localized: "Favorites"),
                assetCount: 42,
                imageNames: []),
            imageName: nil)
    }

    func snapshot(
        for configuration: AlbumWidgetConfigurationIntent,
        in context: Context
    ) async -> AlbumEntry {
        let album = selectedAlbum(for: configuration)
        rememberSelection(album.id)
        return entry(for: album, at: Date())
    }

    func timeline(
        for configuration: AlbumWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<AlbumEntry> {
        let album = selectedAlbum(for: configuration)
        rememberSelection(album.id)

        let now = Date()
        let entries = (0..<scheduledEntryCount).map { offset in
            let date = now.addingTimeInterval(Double(offset) * rotationInterval)
            return entry(for: album, at: date)
        }
        let reloadDate = now.addingTimeInterval(
            Double(scheduledEntryCount) * rotationInterval)
        return Timeline(entries: entries, policy: .after(reloadDate))
    }

    private func selectedAlbum(
        for configuration: AlbumWidgetConfigurationIntent
    ) -> WidgetSnapshot.Album {
        let snapshot = WidgetSnapshot.load()
        return configuration.album.flatMap { selected in
            snapshot.albums.first { $0.id == selected.id }
        } ?? snapshot.albums.first(where: { $0.id == widgetFavoritesID })
            ?? WidgetSnapshot.favorites
    }

    private func entry(
        for album: WidgetSnapshot.Album,
        at date: Date
    ) -> AlbumEntry {
        let imageName: String?
        if album.imageNames.isEmpty {
            imageName = nil
        } else {
            let index = Int(date.timeIntervalSince1970 / rotationInterval)
            imageName = album.imageNames[index % album.imageNames.count]
        }
        return AlbumEntry(date: date, album: album, imageName: imageName)
    }

    private func rememberSelection(_ id: String) {
        guard let defaults = UserDefaults(suiteName: widgetAppGroup) else { return }
        var selected = Set(defaults.stringArray(forKey: selectedAlbumsKey) ?? [])
        selected.insert(id)
        defaults.set(Array(selected).sorted(), forKey: selectedAlbumsKey)
    }
}

private struct AlbumWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AlbumEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            widgetPhoto(entry.imageName)

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Label("Album", systemImage: "rectangle.stack.fill")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .opacity(0.82)
                Text(entry.album?.id == widgetFavoritesID ? String(localized: "Favorites")
                    : entry.album?.name ?? String(localized: "Open SelfPhotos"))
                    .font(family == .systemSmall ? .headline : .title3.bold())
                    .lineLimit(2)
                if let count = entry.album?.assetCount {
                    Text("\(count) photos")
                        .font(.caption)
                        .opacity(0.82)
                }
            }
            .foregroundStyle(.white)
            .padding()
        }
        .containerBackground(.black, for: .widget)
        .widgetURL(albumURL)
    }

    private var albumURL: URL? {
        guard let id = entry.album?.id else { return URL(string: "selfphotos://favorites") }
        if id == widgetFavoritesID { return URL(string: "selfphotos://favorites") }
        return URL(string: "selfphotos://album/\(id)")
    }
}

private struct MemoriesEntry: TimelineEntry {
    let date: Date
    let memory: WidgetSnapshot.Memory?
}

private struct MemoriesTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoriesEntry {
        MemoriesEntry(
            date: Date(),
            memory: .init(
                id: "preview", title: String(localized: "\(5) years ago"),
                subtitle: (Calendar(identifier: .gregorian).date(
                    from: DateComponents(year: 2021, month: 8, day: 9)) ?? .now)
                    .formatted(date: .long, time: .omitted), imageName: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoriesEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoriesEntry>) -> Void) {
        let entry = currentEntry()
        let nextMidnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> MemoriesEntry {
        let snapshot = WidgetSnapshot.load()
        let memory = Calendar.current.isDate(snapshot.generatedAt, inSameDayAs: Date())
            ? snapshot.memories.first
            : nil
        return MemoriesEntry(date: Date(), memory: memory)
    }
}

private struct MemoriesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MemoriesEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            widgetPhoto(entry.memory?.imageName)

            LinearGradient(
                colors: [.black.opacity(0.2), .clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                Label("On This Day", systemImage: "clock.arrow.circlepath")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .opacity(0.9)
                Text(entry.memory?.title ?? String(localized: "No memories today"))
                    .font(family == .systemSmall ? .headline : .title2.bold())
                    .lineLimit(2)
                if let subtitle = entry.memory?.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .opacity(0.82)
                }
            }
            .foregroundStyle(.white)
            .padding()
        }
        .containerBackground(.black, for: .widget)
        .widgetURL(URL(string: "selfphotos://memories"))
    }
}

@ViewBuilder
private func widgetPhoto(_ imageName: String?) -> some View {
    if let image = WidgetSnapshot.image(named: imageName) {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
    } else {
        ZStack {
            LinearGradient(
                colors: [.cyan, .blue, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

struct AlbumWidget: Widget {
    let kind = "ImmichesAlbumWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: AlbumWidgetConfigurationIntent.self,
            provider: AlbumTimelineProvider()
        ) { entry in
            AlbumWidgetView(entry: entry)
        }
        .configurationDisplayName("Album")
        .description("Keep a favorite album on your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct MemoriesWidget: Widget {
    let kind = "ImmichesMemoriesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MemoriesTimelineProvider()) { entry in
            MemoriesWidgetView(entry: entry)
        }
        .configurationDisplayName("Memories")
        .description("Rediscover photos taken on this day in past years.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct ImmichWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AlbumWidget()
        MemoriesWidget()
    }
}
