import Foundation
import SwiftUI

/// Rentang tanggal yang bisa dipilih di pencarian.
///
/// Rentang relatifnya dihitung dari HARI INI setiap kali dipakai, bukan disimpan
/// sebagai dua tanggal saat dipilih. Pencarian yang dibiarkan terbuka semalaman
/// lalu diulang harus berarti "tiga bulan terakhir" menurut hari itu, bukan
/// menurut kemarin.
enum SearchDateRange: Hashable {
    case lastMonth
    case last3Months
    case last9Months
    /// Sepanjang satu tahun kalender.
    case year(Int)
    case month(year: Int, month: Int)
    case day(Date)
    case custom(from: Date, to: Date)

    var label: String {
        switch self {
        case .lastMonth: String(localized: "Last Month")
        case .last3Months: String(localized: "Last 3 Months")
        case .last9Months: String(localized: "Last 9 Months")
        case .year(let year): String(localized: "In \(String(year))")
        case .month(let year, let month):
            Self.monthFormatter.string(from: Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now)
        case .day(let date): Self.short.string(from: date)
        case .custom(let from, let to):
            "\(Self.short.string(from: from)) – \(Self.short.string(from: to))"
        }
    }

    /// Batas bawah dan atasnya, dihitung saat diminta.
    ///
    /// `to` untuk rentang relatif sengaja nil: "tiga bulan terakhir" berakhir
    /// SEKARANG, dan mengirim batas atas berarti foto yang masuk beberapa detik
    /// setelah pencarian dijalankan justru tersaring keluar.
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date?) {
        switch self {
        case .lastMonth:
            (calendar.date(byAdding: .month, value: -1, to: now) ?? now, nil)
        case .last3Months:
            (calendar.date(byAdding: .month, value: -3, to: now) ?? now, nil)
        case .last9Months:
            (calendar.date(byAdding: .month, value: -9, to: now) ?? now, nil)
        case .year(let year):
            (
                calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now,
                calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? now
            )
        case .month(let year, let month):
            monthBounds(year: year, month: month, calendar: calendar, fallback: now)
        case .day(let date):
            (calendar.startOfDay(for: date), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)))
        case .custom(let from, let to):
            // Batas atasnya digeser ke AKHIR hari yang dipilih. Pemilih tanggal
            // menghasilkan tengah malam, dan tanpa pergeseran ini memilih
            // "sampai 5 Agustus" justru membuang seluruh foto tanggal 5.
            (
                calendar.startOfDay(for: from),
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))
            )
        }
    }

    /// Tahun-tahun yang ditawarkan sebagai pilihan cepat.
    static func recentYears(_ count: Int = 6, now: Date = Date()) -> [Int] {
        let thisYear = Calendar.current.component(.year, from: now)
        return (0..<count).map { thisYear - $0 }
    }

    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    private func monthBounds(year: Int, month: Int, calendar: Calendar, fallback: Date) -> (from: Date, to: Date?) {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? fallback
        return (start, calendar.date(byAdding: .month, value: 1, to: start))
    }
}

/// Jenis media yang dicari.
enum SearchMediaType: String, CaseIterable, Identifiable {
    case all, image, video, live

    var id: Self { self }

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .image: String(localized: "Photos")
        case .video: String(localized: "Videos")
        case .live: String(localized: "Live Photos")
        }
    }

    /// Nilai `type` yang dimengerti server; nil berarti tidak disaring.
    var requestValue: String? {
        switch self {
        case .all: nil
        case .image, .live: "IMAGE"
        case .video: "VIDEO"
        }
    }
}

/// Seluruh penyaring yang sedang berlaku di layar pencarian.
struct SearchFilters: Equatable {
    var people: [PersonDTO] = []
    /// Nama kota, diambil dari saran server.
    var city: String?
    var state: String?
    var country: String?
    var album: AlbumResponseDTO?
    var dateRange: SearchDateRange?
    var mediaType: SearchMediaType = .all

    /// Ada penyaring yang benar-benar mempersempit hasil.
    ///
    /// `mediaType == .all` TIDAK dihitung: itu keadaan bawaan, bukan pilihan.
    var isActive: Bool {
        !people.isEmpty || city != nil || state != nil || country != nil || album != nil || dateRange != nil || mediaType != .all
    }

    static func == (lhs: SearchFilters, rhs: SearchFilters) -> Bool {
        lhs.people.map(\.id) == rhs.people.map(\.id)
            && lhs.city == rhs.city
            && lhs.state == rhs.state
            && lhs.country == rhs.country
            && lhs.album?.id == rhs.album?.id
            && lhs.dateRange == rhs.dateRange
            && lhs.mediaType == rhs.mediaType
    }

    /// Menerjemahkan penyaring jadi permintaan pencarian.
    ///
    /// Tanggalnya dikirim sebagai ISO8601 karena `takenAfter`/`takenBefore` di
    /// DTO berbentuk teks — server yang memutuskan bagaimana membacanya, dan
    /// mengubahnya jadi `Date` di sini hanya menambah satu tempat lagi yang bisa
    /// salah zona waktu.
    func apply(to request: inout SearchRequestDTO, now: Date = Date(), calendar: Calendar = .current) {
        request.type = mediaType.requestValue
        request.isMotion = mediaType == .live ? true : nil
        request.city = city
        request.state = state
        request.country = country
        request.albumIds = album.map { [$0.id] }
        request.personIds = people.isEmpty ? nil : people.map(\.id)

        request.takenAfter = nil
        request.takenBefore = nil
        request.exclusiveTakenBefore = nil
        guard let dateRange else { return }
        let bounds = dateRange.bounds(now: now, calendar: calendar)
        request.takenAfter = Self.iso.string(from: bounds.from)
        request.takenBefore = bounds.to.map(Self.iso.string(from:))
        // The server's inclusive bound supplies candidates; the search engine
        // enforces this exact half-open endpoint before sorting and pagination.
        request.exclusiveTakenBefore = request.takenBefore
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
