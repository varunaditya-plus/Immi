import Foundation

enum SearchToken: Identifiable, Hashable {
    case person(PersonDTO)
    case city(String)
    case state(String)
    case country(String)
    case date(SearchDateRange)
    case media(SearchMediaType)
    case album(AlbumResponseDTO)

    var id: String {
        switch self {
        case .person(let person): "person:\(person.id)"
        case .city(let value): "city:\(value)"
        case .state(let value): "state:\(value)"
        case .country(let value): "country:\(value)"
        case .date(let value): "date:\(value)"
        case .media(let value): "media:\(value.rawValue)"
        case .album(let album): "album:\(album.id)"
        }
    }

    var title: String {
        switch self {
        case .person(let person): person.displayName
        case .city(let value), .state(let value), .country(let value): value
        case .date(let value): value.label
        case .media(let value): value.label
        case .album(let album): album.albumName
        }
    }

    var systemImage: String {
        switch self {
        case .person: "person.crop.circle.fill"
        case .city, .state, .country: "mappin.and.ellipse"
        case .date: "calendar"
        case .media(.video): "video.fill"
        case .media(.live): "livephoto"
        case .media: "photo.fill"
        case .album: "rectangle.stack.fill"
        }
    }
}

enum SearchSuggestions {
    static func committedToken(for text: String, now: Date = .now, calendar: Calendar = .current,
                               locale: Locale = .current) -> SearchToken? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let media: [(String, SearchMediaType)] = [
            (String(localized: "Photos", locale: locale), .image),
            (String(localized: "Videos", locale: locale), .video),
            (String(localized: "Live Photos", locale: locale), .live),
        ]
        var tokens = media.filter { exactlyMatches(query, title: $0.0, locale: locale) }.map { SearchToken.media($0.1) }
        tokens += dateTokens(for: query, now: now, calendar: calendar, locale: locale, allowPrefix: false)
        var seen = Set<String>()
        tokens = tokens.filter { seen.insert($0.id).inserted }
        return tokens.count == 1 ? tokens.first : nil
    }

    static func tokens(for query: String, people: [PersonDTO], cities: [String], states: [String],
                       countries: [String], albums: [AlbumResponseDTO], selected: [SearchToken] = [],
                       now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> [SearchToken] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var candidates = people.filter { !$0.isHidden && !$0.name.isEmpty }.map(SearchToken.person)
        candidates += cities.map(SearchToken.city) + states.map(SearchToken.state) + countries.map(SearchToken.country)
        candidates += albums.map(SearchToken.album)
        candidates += [SearchMediaType.image, .video, .live].map(SearchToken.media)
        candidates = candidates.filter { matches(query, title: $0.title, locale: locale) }
        candidates += dateTokens(for: query, now: now, calendar: calendar, locale: locale)
        let selectedIDs = Set(selected.map(\.id))
        var seen = selectedIDs
        return candidates.filter { seen.insert($0.id).inserted }.sorted {
            let first = $0.title.compare($1.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale)
            return first == .orderedSame ? $0.id < $1.id : first == .orderedAscending
        }
    }

    static func remainingQuery(_ query: String, after token: SearchToken, now: Date = .now,
                               calendar: Calendar = .current, locale: Locale = .current) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if matches(trimmed, title: token.title, locale: locale) { return "" }
        if dateTokens(for: trimmed, now: now, calendar: calendar, locale: locale).contains(where: { $0.id == token.id }) { return "" }
        guard let range = trimmed.range(of: token.title, options: [.caseInsensitive, .diacriticInsensitive], locale: locale),
              (range.lowerBound == trimmed.startIndex || !trimmed[trimmed.index(before: range.lowerBound)].isLetter),
              (range.upperBound == trimmed.endIndex || !trimmed[range.upperBound].isLetter) else { return query }
        return trimmed.replacingCharacters(in: range, with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func matches(_ query: String, title: String, locale: Locale = .current) -> Bool {
        title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
    }

    static func exactlyMatches(_ query: String, title: String, locale: Locale = .current) -> Bool {
        title.compare(query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) == .orderedSame
    }

    private static func dateTokens(for query: String, now: Date, calendar: Calendar, locale: Locale,
                                   allowPrefix: Bool = true) -> [SearchToken] {
        var result: [SearchToken] = []
        let year = calendar.component(.year, from: now)
        if query.count == 4, query.allSatisfy(\.isNumber), let value = Int(query), (1...9999).contains(value) {
            result.append(.date(.year(value)))
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.isLenient = false
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let monthWords = words.filter { Int($0) == nil }
        let explicitYear = words.compactMap(Int.init).first
        let yearWord = words.first { Int($0) != nil }
        for (index, name) in formatter.monthSymbols.enumerated() {
            let short = formatter.shortMonthSymbols[index]
            if monthWords.count == 1, let monthWord = monthWords.first, monthWord.count >= 2,
               words.count == 1 || (words.count == 2 && explicitYear != nil),
               explicitYear.map({ (1...9999).contains($0) }) ?? true,
               yearWord == nil || (yearWord?.count == 4 && yearWord?.allSatisfy(\.isNumber) == true) {
                let matchesMonth = allowPrefix
                    ? (name.range(of: monthWord, options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: locale) != nil
                       || short.range(of: monthWord, options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: locale) != nil)
                    : exactlyMatches(monthWord, title: name, locale: locale)
                if matchesMonth { result.append(.date(.month(year: explicitYear ?? year, month: index + 1))) }
            }
        }
        for format in ["yyyy-MM-dd", "MMMM d, yyyy", "d MMMM yyyy", "MMM d, yyyy", "d MMM yyyy"] {
            formatter.dateFormat = format
            guard let date = formatter.date(from: query),
                  formatter.string(from: date).compare(query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) == .orderedSame else { continue }
            result.append(.date(.day(calendar.startOfDay(for: date))))
            break
        }
        if result.isEmpty {
            for template in ["yyyyMMMMd", "yyyyMMMd"] {
                formatter.setLocalizedDateFormatFromTemplate(template)
                guard let date = formatter.date(from: query),
                      exactlyMatches(query, title: formatter.string(from: date), locale: locale) else { continue }
                result.append(.date(.day(calendar.startOfDay(for: date))))
                break
            }
        }
        if result.isEmpty, query.allSatisfy({ $0.isNumber || $0.isWhitespace || "/.-".contains($0) }) {
            formatter.setLocalizedDateFormatFromTemplate("yyyyMd")
            if let date = formatter.date(from: query) {
                let numbers: (String) -> [Int] = { $0.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
                let parts = query.split(whereSeparator: { !$0.isNumber })
                if parts.count == 3, parts.contains(where: { $0.count == 4 }),
                   numbers(query) == numbers(formatter.string(from: date)) {
                    result.append(.date(.day(calendar.startOfDay(for: date))))
                }
            }
        }
        let relative: [(String, SearchDateRange)] = [
            (String(localized: "Today", locale: locale), .day(calendar.startOfDay(for: now))),
            (String(localized: "Yesterday", locale: locale), .day(calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: now) ?? now))),
            (String(localized: "This Year"), .year(year)),
            (String(localized: "Last Year"), .year(year - 1)),
            (SearchDateRange.lastMonth.label, .lastMonth),
            (SearchDateRange.last3Months.label, .last3Months),
            (SearchDateRange.last9Months.label, .last9Months),
        ]
        result += relative.enumerated().filter {
            allowPrefix ? matches(query, title: $0.element.0, locale: locale)
                : ($0.offset < 2 && exactlyMatches(query, title: $0.element.0, locale: locale))
        }.map { .date($0.element.1) }
        return result
    }
}
