import Foundation

/// Satu kenangan siap tampil: "N tahun lalu" beserta foto-fotonya.
///
/// Menggantikan pengelompokan per BULAN yang dipakai sebelumnya. Immich sudah
/// mengirim kenangan sebagai satuan tersendiri — satu entri untuk tanggal ini di
/// tahun tertentu — jadi mengumpulkannya lagi per bulan hanya melebur beberapa
/// tahun menjadi satu kartu dan membuang justru keterangan yang paling berarti:
/// berapa tahun yang lalu.
struct MemoryStory: Identifiable {
    let id: String
    /// "1 year ago", "2 years ago" — label utama kartu maupun story.
    let title: String
    /// "August 5, 2024" — tanggal lengkapnya.
    let subtitle: String
    let assets: [AssetLite]

    var cover: AssetLite? { assets.first }

    /// Kenangan yang layak ditampilkan, terbaru dulu.
    ///
    /// Only timeline-visible photos may appear in an ordinary memory card.
    /// The remaining filters also run here rather than in the view:
    ///
    /// - Yang tidak punya foto dibuang. Kenangan kosong tidak bisa jadi story
    ///   dan kartunya pun tidak punya sampul; kalau dibiarkan lewat, ia cuma
    ///   jadi petak abu-abu yang membuka layar kosong.
    /// - Yang bukan TANGGAL HARI INI dibuang. `/memories` mengirim kenangan
    ///   untuk rentang beberapa hari sekaligus — server menyiapkannya lebih awal
    ///   supaya klien bisa memuatnya di muka. Menampilkan semuanya membuat baris
    ///   "On This Day" berisi tanggal yang bukan hari ini.
    static func build(from memories: [MemoryDTO], limit: Int, now: Date = Date()) -> [MemoryStory] {
        let calendar = Calendar.current
        let today = calendar.dateComponents([.month, .day], from: now)

        return Array(memories
            .filter { isToday($0.memoryAt, today) }
            .sorted { $0.memoryAt > $1.memoryAt }
            .compactMap { memory -> MemoryStory? in
                let visibleAssets = memory.assets.filter(\.isTimelineVisible)
                guard !visibleAssets.isEmpty else { return nil }
                return MemoryStory(
                    id: memory.id,
                    title: yearsAgoTitle(for: memory, now: now, calendar: calendar),
                    subtitle: dateFormatter.string(from: memory.memoryAt),
                    assets: visibleAssets.map(AssetLite.init))
            }
            .prefix(limit))
    }

    /// Kalender UTC untuk membaca `memoryAt`.
    ///
    /// `memoryAt` BUKAN sebuah saat, melainkan sebuah TANGGAL yang dikirim
    /// server sebagai tengah malam UTC. Dibaca dengan kalender perangkat, di
    /// zona waktu yang lebih barat dari UTC ia mundur satu hari — di Los Angeles
    /// "5 Agustus" terbaca "4 Agustus", tidak ada satu pun kenangan yang lolos
    /// saringan, dan seluruh baris On This Day hilang. Tanggalnya harus dibaca
    /// di zona waktu yang sama dengan zona waktu penulisannya.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// Tanggal dan bulannya sama dengan hari ini — tahunnya justru harus beda,
    /// jadi yang dibandingkan hanya kedua komponen itu.
    ///
    /// "Hari ini" tetap dibaca di zona waktu perangkat: itu memang hari menurut
    /// penggunanya.
    private static func isToday(_ date: Date, _ today: DateComponents) -> Bool {
        let components = utcCalendar.dateComponents([.month, .day], from: date)
        return components.month == today.month && components.day == today.day
    }

    /// Selisih tahunnya dihitung dari KOMPONEN tahun, bukan dari jarak hari.
    ///
    /// Kenangan "on this day" selalu jatuh di tanggal yang sama, jadi jaraknya
    /// dalam hari selalu sedikit kurang dari kelipatan 365 — dibagi 365 hasilnya
    /// meleset satu tahun ke bawah di tahun kabisat. Komponen tahun tidak punya
    /// masalah itu.
    private static func yearsAgoTitle(
        for memory: MemoryDTO,
        now: Date,
        calendar: Calendar
    ) -> String {
        // `data.year` dipakai lebih dulu kalau ada: itu angka yang dipakai
        // server saat menyusun kenangannya, jadi labelnya tidak akan berbeda
        // dari aplikasi lain yang membaca kebun yang sama.
        //
        // Cadangannya dibaca UTC dengan alasan yang sama seperti `isToday` —
        // kenangan 1 Januari yang dibaca di zona waktu barat akan tercatat
        // sebagai 31 Desember tahun sebelumnya.
        let memoryYear = memory.data?.year
            ?? Self.utcCalendar.component(.year, from: memory.memoryAt)
        let years = calendar.component(.year, from: now) - memoryYear

        guard years > 0 else { return String(localized: "This year") }
        return years == 1
            ? String(localized: "1 year ago")
            : String(localized: "\(years) years ago")
    }
}

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .long
    f.timeStyle = .none
    // UTC, sama seperti `utcCalendar`: yang diformat ini tanggal kenangan yang
    // ditulis server sebagai tengah malam UTC, bukan sebuah saat yang harus
    // diterjemahkan ke waktu setempat. Tanpa ini "August 5" tercetak "August 4"
    // di zona waktu barat.
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()
