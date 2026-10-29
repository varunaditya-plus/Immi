import Foundation

struct WidgetMemory: Codable, Identifiable {
    let id: String
    // Compatibility captions for older widget readers.
    let title: String
    let subtitle: String
    let imageName: String?
    let memoryAt: Date?
    let yearsAgo: Int?

    init(id: String, title: String = "", subtitle: String = "", imageName: String?,
         memoryAt: Date? = nil, yearsAgo: Int? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.imageName = imageName
        self.memoryAt = memoryAt
        self.yearsAgo = yearsAgo
    }

    func localizedTitle(bundle: Bundle = .main, locale: Locale = .current) -> String {
        // Select the lproj explicitly; Locale alone can keep the process language.
        let language = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [locale.language.maximalIdentifier]).first
        let localizedBundle = language.flatMap { bundle.url(forResource: $0, withExtension: "lproj") }
            .flatMap { Bundle(url: $0) } ?? bundle
        guard let yearsAgo else { return String(localized: "Memories", bundle: localizedBundle, locale: locale) }
        return yearsAgo > 0
            ? String(localized: "\(yearsAgo) years ago", bundle: localizedBundle, locale: locale)
            : String(localized: "This year", bundle: localizedBundle, locale: locale)
    }

    func localizedSubtitle(locale: Locale = .current) -> String? {
        guard let memoryAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        // memoryAt is a UTC calendar date; timezone conversion would change the day.
        formatter.timeZone = .gmt
        return formatter.string(from: memoryAt)
    }
}
