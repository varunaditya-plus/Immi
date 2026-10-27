import Foundation
import Observation
// Untuk withAnimation saat membuang aset dari grid.
import SwiftUI

/// Satu tujuan pada navigator Months atau Years.
struct TimelineNavigationItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var cover: AssetLite
    var highlights: [TimelineDayHighlight] = []

    /// Aset paling awal pada periode ini; menjadi jangkar saat kembali ke All.
    var targetAssetID: String { cover.id }
}

/// Satu tanggal pilihan dalam bulan; cover juga menjadi tujuan zoom ke All.
struct TimelineDayHighlight: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let title: String
    let count: Int
    var cover: AssetLite

    var targetAssetID: String { cover.id }
}

@MainActor
@Observable
final class TimelineViewModel {
    /// Section dan navigator disimpan bersama agar highlight tidak dihitung
    /// ulang pada setiap evaluasi body ketika pengguna menggulir.
    private var content = TimelineContent()
    var sections: [TimelineSection] {
        get { content.sections }
        set { content = Self.makeContent(sections: newValue, calendar: calendar) }
    }
    /// Daftar datar seluruh foto, disimpan bukan dihitung.
    ///
    /// Layar detail memerlukannya sebagai isi pager. Sebagai properti terhitung,
    /// ia diratakan ulang setiap kali penutup fullScreenCover dievaluasi —
    /// termasuk pada SETIAP usapan halaman, karena foto yang tampil ikut berubah.
    /// Pada puluhan ribu foto itu penyalinan array penuh per usapan.
    private(set) var allAssets: [AssetLite] = []
    var phase: LoadingPhase<Void> = .idle
    var albums: [AlbumResponseDTO] = []
    var actionError: String?

    /// Ada foto di cache lokal, diketahui SEBELUM apa pun dibaca.
    ///
    /// Ini yang membedakan "belum ada apa-apa, tunggu sync" dari "sudah ada,
    /// sebentar lagi tergambar". Yang pertama pantas diberi spinner; yang kedua
    /// tidak — foto yang sudah ada di perangkat tidak sedang diunduh dari mana
    /// pun, dan memberinya spinner membuat aplikasi terasa selalu memuat ulang
    /// tiap kali dibuka.
    ///
    /// `fetchCount` saja, bukan membaca isinya: satu hitungan di SQLite, bukan
    /// puluhan ribu objek.
    private(set) var hasLocalData = false

    /// Sidik jari isi linimasa terakhir yang berhasil disusun.
    private var signature: Signature?
    private var hasLoaded = false
    /// Pilihan album yang isinya sudah dimuat.
    ///
    /// Bukan bendera "sudah pernah", melainkan APA yang sudah dimuat. Dengan
    /// bendera, memilih album baru di Settings tidak berefek sampai aplikasi
    /// dibuka ulang — `task` layar berjalan lagi, tapi penjaganya sudah menyala
    /// dan tidak ada yang membacanya kembali.
    private var loadedAlbums: Set<String>?

    private let accountGeneration = LocalSnapshot.generation
    private let dataManager: SwiftDataManager?
    private let assetRepo: AssetDetailRepository?
    private let albumRepo: AlbumRepository?
    /// Pencocok foto perangkat dengan aset server; nil kalau layar ini dibangun
    /// tanpa jaringan (pratinjau, tes).
    private let matcher: DeviceAssetMatcher?
    private let calendar: Calendar

    /// Maksimal tiga tanggal teramai per bulan, ditampilkan lama → baru.
    var monthNavigationItems: [TimelineNavigationItem] {
        content.months
    }

    /// Satu kartu per tahun. Cover sekaligus targetnya adalah aset pertama pada
    /// bulan pertama yang tersedia di tahun tersebut.
    var yearNavigationItems: [TimelineNavigationItem] {
        content.years
    }

    init(
        dataManager: SwiftDataManager? = nil,
        assetRepo: AssetDetailRepository? = nil,
        albumRepo: AlbumRepository? = nil,
        matcher: DeviceAssetMatcher? = nil,
        calendar: Calendar = .current
    ) {
        self.dataManager = dataManager
        self.assetRepo = assetRepo
        self.albumRepo = albumRepo
        self.matcher = matcher
        // MonthKey memakai kalender Gregorian. Preferensi kalender sistem
        // tidak boleh membuat label harinya memakai bulan/tahun yang berbeda.
        var timelineCalendar = Calendar(identifier: .gregorian)
        timelineCalendar.timeZone = calendar.timeZone
        timelineCalendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = timelineCalendar
        self.hasLocalData = (dataManager?.timelineAssetCount() ?? 0) > 0

        // Linimasa yang memasang telinganya, bukan pemuat gambar yang memanggil
        // linimasa: pemuat tidak boleh tahu apa pun soal penyimpanan maupun
        // grid. `weak self` karena kotak suratnya hidup selama aplikasi hidup.
        UnreadableAssets.shared.onPurge = { [weak self] ids in
            self?.purgeUnreadable(ids)
        }
    }

    /// Aset yang ditolak server dibuang dari cache DAN dari grid.
    ///
    /// Dua-duanya perlu: membuang dari grid saja membuatnya muncul lagi pada
    /// muat ulang berikutnya, sedangkan membuang dari cache saja membiarkan
    /// petak matinya tetap terlihat sampai layar disusun ulang.
    func purgeUnreadable(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        guard accountGeneration == LocalSnapshot.generation else { return }
        try? dataManager?.purgeAssets(Array(ids))

        // Pemuat thumbnail yang sama dipakai grid album, favorit, orang, arsip,
        // dan trash — laporannya belum tentu tentang foto yang ada di linimasa.
        // Tanpa penjaga ini, satu gelombang kegagalan di layar lain menjalankan
        // animasi pembuangan yang tidak membuang apa pun DAN membatalkan sidik
        // jari linimasa, yang berarti seluruh cache dibaca ulang percuma.
        guard allAssets.contains(where: { ids.contains($0.id) }) else { return }
        removeAssets(ids)
    }

    // MARK: - Pemuatan

    /// Linimasa dibangun dari CACHE LOKAL, bukan dari `/timeline/buckets`.
    ///
    /// Jalur lama menarik daftar bucket, lalu satu permintaan lagi per bulan yang
    /// masing-masing berisi seluruh aset bulan itu. Pada perpustakaan puluhan ribu
    /// foto itu berarti puluhan respons besar yang harus di-decode justru sambil
    /// pengguna menggulir.
    ///
    /// Aplikasi resmi tidak menyentuh endpoint itu sama sekali: ia menstream
    /// `/sync/stream` satu kali, menyimpan hasilnya secara lokal, lalu merender
    /// dari sana. Itulah yang membuatnya terasa seketika — dan stream yang sama
    /// sudah kita jalankan, hanya belum dipakai sebagai sumber utama.
    /// Memuat daftar foto perangkat, lalu menyusun ulang linimasa.
    ///
    /// Terpisah dari `loadTimeline` karena harganya berbeda: membaca cache
    /// linimasa murni pekerjaan lokal, sedangkan yang ini meminta izin sistem
    /// pada kunjungan pertama. Menyatukannya berarti dialog izin muncul di
    /// tengah pembacaan cache yang seharusnya tak terlihat.
    func loadDevicePhotos() async {
        // Sekali per sesi layar. `task` berjalan ulang setiap tab Photos dibuka,
        // dan mengenumerasi seluruh pustaka setiap kali adalah pekerjaan besar
        // untuk daftar yang jarang berubah.
        let selection = LocalPhotoLibrary.shared.selectedAlbumIDs
        guard loadedAlbums != selection else { return }
        loadedAlbums = selection

        await reloadDevicePhotos()
        matchDevicePhotos()
    }

    /// Membaca ulang setelah PhotoKit berubah, walaupun pilihan album sama.
    func reloadDevicePhotos() async {
        await LocalPhotoLibrary.shared.load()
        await rebuild()
    }

    /// Pencocokan menyusul, di latar.
    ///
    /// Ia membaca byte setiap foto yang belum pernah dihitung — pekerjaan yang
    /// tidak boleh ditunggu sebelum linimasa tergambar. Yang berpasangan hilang
    /// dari daftar sambil jalan; itu sebabnya `rebuild` dipanggil per kelompok,
    /// bukan sekali di akhir.
    ///
    /// Terpisah supaya bisa dipanggil lagi saat jaringan berpindah dari seluler
    /// ke Wi‑Fi — `match` menunda seluruhnya di jaringan berbayar, dan tanpa
    /// panggilan kedua penundaan itu berlaku sampai aplikasi dibuka ulang.
    func matchDevicePhotos() {
        matcher?.match(LocalPhotoLibrary.shared.photos) { [weak self] in
            Task { await self?.rebuild() }
        }
    }

    func loadTimeline() async {
        // Spinner HANYA kalau memang tidak ada apa-apa di perangkat.
        //
        // Membaca cache dan mengelompokkannya butuh sepersekian detik pada
        // perpustakaan besar. Menandainya sebagai "memuat" membuat aplikasi
        // membuka dengan spinner setiap kali, padahal fotonya sudah ada di
        // perangkat dan tidak ada yang sedang diunduh.
        if sections.isEmpty, !hasLocalData { phase = .loading }
        await rebuild()
    }

    /// Dipakai `task` layar, yang berjalan ulang SETIAP KALI tab dibuka lagi.
    ///
    /// Membaca ulang seluruh cache tiap perpindahan tab itu mahal — pada
    /// perpustakaan puluhan ribu foto, itulah jeda berdetik-detik saat berpindah.
    /// Linimasa hanya berubah lewat sync atau aksi lokal, dan keduanya sudah
    /// memuat ulang sendiri, jadi pembukaan tab tidak perlu melakukan apa pun.
    func loadTimelineIfNeeded() async {
        guard !hasLoaded else { return }
        await loadTimeline()
    }

    private func rebuild() async {
        let rows = mergedRows()
        hasLocalData = !rows.isEmpty

        guard !rows.isEmpty else {
            // Belum ada apa pun secara lokal. Bukan kegagalan — sync mungkin
            // masih berjalan; layar kosongnya yang menjelaskan.
            //
            // `hasLoaded` sengaja TIDAK disetel: tidak ada yang berhasil disusun,
            // jadi pembukaan tab berikutnya masih boleh mencoba lagi.
            sections = []
            allAssets = []
            signature = nil
            phase = .loaded(())
            return
        }

        // Tidak menyusun ulang kalau isinya sama.
        //
        // Sebagian besar delta sync tidak mengubah apa pun. Tanpa penjaga ini,
        // setiap sync tetap mengganti seluruh array `sections` — SwiftUI lalu
        // membanding-bandingkan ulang seluruh grid, dan posisi gulir pengguna
        // ikut terguncang tanpa ada satu foto pun yang berubah.
        let newSignature = Signature(rows)
        guard newSignature != signature else {
            hasLoaded = true
            phase = .loaded(())
            return
        }

        // Pengelompokan dilakukan DI LUAR main actor.
        //
        // Puluhan ribu iterasi plus pembangunan array section bukan pekerjaan
        // yang boleh menahan antarmuka — dan tidak ada satu pun bagiannya yang
        // butuh main thread.
        let built = await Self.build(rows, calendar: calendar)
        guard accountGeneration == LocalSnapshot.generation else { return }

        signature = newSignature
        content = built.content
        allAssets = built.assets
        hasLoaded = true
        phase = .loaded(())
    }

    /// Foto server dan foto perangkat, digabung dalam satu deret terurut.
    ///
    /// Keduanya sudah menaik menurut tanggal — cache linimasa karena kueri-nya
    /// begitu, pustaka perangkat karena `sortDescriptors`-nya begitu. Jadi yang
    /// dikerjakan di sini cuma merge dua deret terurut, bukan pengurutan ulang
    /// puluhan ribu item.
    ///
    /// Yang PENTING: urutannya harus benar sebelum `build`. Pengelompokan per
    /// bulan di sana satu lintasan tanpa sorting — satu foto yang tersisip di
    /// tempat salah akan memecah bulannya jadi dua bagian terpisah.
    private func mergedRows() -> [TimelineRow] {
        let serverRows = markDeviceCopies(dataManager?.timelineAssets() ?? [])
        let deviceRows = localRows(existingServerIDs: Set(serverRows.map(\.asset.id)))
        guard !deviceRows.isEmpty else { return serverRows }
        guard !serverRows.isEmpty else { return deviceRows }

        var merged: [TimelineRow] = []
        merged.reserveCapacity(serverRows.count + deviceRows.count)
        var i = 0, j = 0
        while i < serverRows.count && j < deviceRows.count {
            if serverRows[i].asset.createdAt <= deviceRows[j].asset.createdAt {
                merged.append(serverRows[i]); i += 1
            } else {
                merged.append(deviceRows[j]); j += 1
            }
        }
        merged.append(contentsOf: serverRows[i...])
        merged.append(contentsOf: deviceRows[j...])
        return merged
    }

    /// Menandai petak server yang salinannya masih ada di perangkat.
    ///
    /// Dikerjakan di sini, bukan disimpan di cache: hubungan ini milik
    /// perangkat, bukan milik server, dan menuliskannya ke `CachedAsset` berarti
    /// sync berikutnya harus menjaganya tetap benar tanpa punya cara tahu.
    private func markDeviceCopies(_ rows: [TimelineRow]) -> [TimelineRow] {
        let links = dataManager?.serverAssetIDsByLocalIdentifier() ?? [:]
        let existingLocalIDs = LocalPhotoLibrary.existingLocalIdentifiers(Array(links.keys))
        let onDevice = Set(existingLocalIDs.compactMap { links[$0] })
        guard !onDevice.isEmpty else { return rows }
        return rows.map { row in
            guard onDevice.contains(row.asset.id) else { return row }
            var asset = row.asset
            asset.origin = .both
            return TimelineRow(asset: asset, monthKey: row.monthKey)
        }
    }

    /// Foto perangkat, dengan lencana yang sesuai keadaannya.
    ///
    /// **Petak lokal dibuang hanya kalau petak SERVER-nya benar-benar sudah ada
    /// di cache** — bukan sekadar karena unggahannya tercatat berhasil.
    ///
    /// Dulu penyaringnya cuma "ada catatan unggahan?", dan itu meninggalkan
    /// lubang di antara dua kejadian: unggahan selesai lebih dulu, aset servernya
    /// baru turun pada sync berikutnya. Di sela itu fotonya hilang dari linimasa
    /// — bukan berganti lencana, melainkan lenyap. Yang paling membingungkan
    /// justru karena terjadi tepat setelah sesuatu berhasil.
    ///
    /// Sekarang petak lokalnya bertahan dan lencananya berganti jadi "ada di
    /// keduanya" seketika. Begitu sync membawa aset servernya, petak lokal itu
    /// menghilang dan petak server menggantikannya dengan lencana yang sama —
    /// pergantian yang tidak terlihat sama sekali.
    ///
    /// - Parameter existingServerIDs: id aset yang SUDAH ada di cache linimasa.
    private func localRows(existingServerIDs: Set<String>) -> [TimelineRow] {
        let links = dataManager?.serverAssetIDsByLocalIdentifier() ?? [:]
        let deletedServerIDs = DeletedServerAssetRegistry.shared.suppressedIDs

        return LocalPhotoLibrary.shared.photos.compactMap { photo -> TimelineRow? in
            var origin = AssetOrigin.device
            if let serverID = links[photo.id] {
                // Mapping backup sengaja bertahan setelah delete supaya file
                // lokal tidak naik lagi. Ia tidak berarti foto tersebut masih
                // boleh kembali ke timeline sebagai fallback lokal.
                guard !deletedServerIDs.contains(serverID) else { return nil }
                // Petak servernya sudah berdiri sendiri; dua petak untuk satu
                // foto yang sama adalah persis yang ingin dihindari.
                guard !existingServerIDs.contains(serverID) else { return nil }
                origin = .both
            }

            return TimelineRow(
                asset: AssetLite(
                    id: LocalPhotoLibrary.assetID(for: photo.id),
                    isVideo: photo.isVideo,
                    ratio: photo.ratio,
                    thumbhash: nil,
                    createdAt: photo.createdAt,
                    duration: photo.duration,
                    origin: origin),
                monthKey: MonthKey.of(photo.createdAt))
        }
    }

    /// Menggambar ulang lencana asal tanpa menyentuh jaringan.
    ///
    /// Dipanggil sementara pencadangan berjalan: tiap unggahan yang berhasil
    /// mengubah arti satu petak, dan menunggu sync berikutnya untuk
    /// memperlihatkannya berarti angka di layar Backup naik sementara linimasa
    /// bersikeras tidak ada yang berubah.
    func refreshOrigins() async {
        await rebuild()
    }

    /// Sidik jari murah untuk isi linimasa.
    ///
    /// Cukup jumlah plus aset di kedua ujungnya: penambahan, penghapusan, dan
    /// perubahan tanggal semuanya menggeser salah satu dari ketiganya. Menyusuri
    /// seluruh id hanya akan mengulang pekerjaan yang justru ingin dihindari.
    private struct Signature: Equatable {
        let count: Int
        let firstID: String?
        let lastID: String?

        /// Jumlah aset perangkat ikut dihitung TERPISAH.
        ///
        /// Menyisipkan foto lokal di tengah tidak mengubah jumlah total maupun
        /// kedua ujungnya kalau ada foto server yang hilang di saat yang sama —
        /// dan penjaga ini akan melewatkannya diam-diam.
        let deviceCount: Int

        /// Yang ada di KEDUA tempat, dihitung terpisah lagi.
        ///
        /// Tanpa ini "Delete from Device" tidak pernah terlihat hasilnya.
        /// Menghapus salinan perangkat mengubah asalnya dari `.both` jadi
        /// `.server` — jumlah baris tetap, kedua ujungnya tetap, dan `.both`
        /// maupun `.server` sama-sama BUKAN `.device`, jadi ketiga angka lama
        /// tidak bergeming. Sidik jarinya identik, penjaga di `rebuild` pulang
        /// lebih awal, dan lencananya bertahan menunjuk berkas yang sudah tidak
        /// ada.
        ///
        /// Arah sebaliknya kebetulan selamat: unggahan mengubah `.device` jadi
        /// `.both`, dan itu menggeser `deviceCount`. Kebetulan yang menyamarkan
        /// setengah dari lubangnya.
        let linkedCount: Int

        init(_ rows: [TimelineRow]) {
            count = rows.count
            firstID = rows.first?.asset.id
            lastID = rows.last?.asset.id

            var device = 0
            var linked = 0
            for row in rows {
                switch row.asset.origin {
                case .device: device += 1
                case .both:   linked += 1
                case .server: break
                }
            }
            deviceCount = device
            linkedCount = linked
        }
    }

    func retry() async {
        await loadTimeline()
    }

    /// Aset TERBARU untuk sebuah id.
    ///
    /// Grid UIKit memegang salinan yang dibekukan saat snapshot terakhir
    /// disusun, dan snapshot itu sengaja tidak disusun ulang kalau daftarnya
    /// tidak berubah. Pencarian linier di sini tidak masalah: yang memanggilnya
    /// cuma ketukan dan tekan-lama, bukan penggambaran sel.
    func asset(for id: String) -> AssetLite? {
        allAssets.first { $0.id == id }
    }

    /// Mengelompokkan per bulan dalam SATU lintasan, di luar main actor.
    ///
    /// Barisnya sudah terurut menaik dari kueri dan kunci bulannya sudah dihitung
    /// saat sync, jadi cukup memutus setiap kali kuncinya berganti — tanpa kamus
    /// perantara, pengurutan ulang, maupun pemformatan tanggal.
    nonisolated private static func build(
        _ rows: [TimelineRow],
        calendar: Calendar
    ) async -> (content: TimelineContent, assets: [AssetLite]) {
        await Task.detached(priority: .userInitiated) {
            var sections: [TimelineSection] = []
            sections.reserveCapacity(64)
            var assets: [AssetLite] = []
            assets.reserveCapacity(rows.count)
            for (offset, row) in rows.enumerated() {
                assets.append(row.asset)

                if sections.isEmpty || sections[sections.count - 1].id != row.monthKey {
                    sections.append(TimelineSection(
                        id: row.monthKey,
                        title: formatBucketTitle(row.monthKey),
                        assets: [row.asset],
                        count: 1,
                        startIndex: offset))
                } else {
                    sections[sections.count - 1].assets.append(row.asset)
                    sections[sections.count - 1].count += 1
                }
            }
            return (makeContent(sections: sections, calendar: calendar), assets)
        }.value
    }

    private struct TimelineContent: Sendable {
        var sections: [TimelineSection] = []
        var months: [TimelineNavigationItem] = []
        var years: [TimelineNavigationItem] = []
    }

    nonisolated private static func makeContent(
        sections: [TimelineSection],
        calendar: Calendar,
        reusingMonths: [String: TimelineNavigationItem] = [:]
    ) -> TimelineContent {
        var result = TimelineContent(sections: sections)
        result.months.reserveCapacity(sections.count)
        result.years.reserveCapacity(max(sections.count / 12, 1))

        for section in sections {
            guard let first = section.assets.first else { continue }
            if let cached = reusingMonths[section.id] {
                result.months.append(cached)
            } else {
                result.months.append(TimelineNavigationItem(
                    id: section.id,
                    title: formatNavigatorMonthTitle(section.id),
                    cover: first,
                    highlights: dayHighlights(for: section, calendar: calendar)))
            }

            let year = String(section.id.prefix(4))
            guard result.years.last?.id != year else { continue }
            result.years.append(TimelineNavigationItem(id: year, title: year, cover: first))
        }
        return result
    }

    nonisolated private static func dayHighlights(
        for section: TimelineSection,
        calendar: Calendar
    ) -> [TimelineDayHighlight] {
        var days: [Date: (count: Int, cover: AssetLite)] = [:]
        for asset in section.assets {
            let day = calendar.startOfDay(for: asset.createdAt)
            if var existing = days[day] {
                existing.count += 1
                // Foto diam diutamakan; tanggal lalu id memutus seri secara
                // stabil, bahkan ketika urutan hasil sync berubah.
                let preferred = existing.cover.isVideo != asset.isVideo
                    ? !asset.isVideo
                    : asset.createdAt == existing.cover.createdAt
                        ? asset.id < existing.cover.id
                        : asset.createdAt < existing.cover.createdAt
                if preferred { existing.cover = asset }
                days[day] = existing
            } else {
                days[day] = (1, asset)
            }
        }

        return days.sorted {
            $0.value.count == $1.value.count
                ? $0.key < $1.key
                : $0.value.count > $1.value.count
        }
        .prefix(3)
        .sorted { $0.key < $1.key }
        .map { day, value in
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dayNumber = parts.day ?? 1
            let dateID = String(
                format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, dayNumber)
            return TimelineDayHighlight(
                id: dateID,
                date: day,
                title: String(dayNumber),
                count: value.count,
                cover: value.cover)
        }
    }

    // MARK: - Aksi context menu

    /// Daftar album untuk "Add to Album"; cukup dimuat sekali.
    func loadAlbumsIfNeeded() async {
        guard albums.isEmpty, let albumRepo else { return }
        albums = (try? await albumRepo.all()) ?? []
    }

    /// Toggle, bukan selalu menyalakan — context menu memakai teks
    /// "Favorite"/"Unfavorite" sesuai status sekarang.
    ///
    /// - Returns: true kalau server menerimanya, supaya pemanggil bisa memberi
    ///   umpan balik getar hanya saat perubahannya benar-benar terjadi.
    @discardableResult
    func toggleFavorite(_ asset: AssetLite) async -> Bool {
        guard let assetRepo else { return false }
        let newValue = !asset.isFavorite
        do {
            try await assetRepo.toggleFavorite(asset.id, to: newValue)
            guard accountGeneration == LocalSnapshot.generation else { return false }
            setFavorite(asset.id, to: newValue)
            return true
        } catch {
            actionError = Self.describe(error)
            return false
        }
    }

    /// Menambal status favorit di grid tanpa refetch — dipakai juga oleh layar
    /// detail lewat callback.
    ///
    /// DUA-DUANYA ditambal, `sections` dan `allAssets`.
    ///
    /// Dulu hanya `sections`, dan `allAssets` dibiarkan basi. Itu tidak terlihat
    /// di grid — sel menggambar dari `sections` — tapi `asset(for:)` membaca
    /// `allAssets`, dan itulah yang dipakai context menu untuk memutuskan
    /// tulisannya. Hasilnya: foto yang baru saja difavoritkan tetap menawarkan
    /// "Favorite", tidak pernah "Unfavorite".
    func setFavorite(_ id: String, to value: Bool) {
        var updated = content
        for sectionIndex in updated.sections.indices {
            guard let assetIndex = updated.sections[sectionIndex].assets
                .firstIndex(where: { $0.id == id }) else { continue }
            updated.sections[sectionIndex].assets[assetIndex].isFavorite = value
            break
        }
        // Favorit tidak mengubah ranking tanggal: tambal cover yang disimpan
        // tanpa mengelompokkan ulang seluruh perpustakaan.
        for index in updated.months.indices {
            if updated.months[index].cover.id == id {
                updated.months[index].cover.isFavorite = value
            }
            for highlightIndex in updated.months[index].highlights.indices {
                if updated.months[index].highlights[highlightIndex].cover.id == id {
                    updated.months[index].highlights[highlightIndex].cover.isFavorite = value
                }
            }
        }
        for index in updated.years.indices where updated.years[index].cover.id == id {
            updated.years[index].cover.isFavorite = value
        }
        content = updated
        if let index = allAssets.firstIndex(where: { $0.id == id }) {
            allAssets[index].isFavorite = value
        }
    }

    func archive(_ asset: AssetLite) async {
        guard let assetRepo else { return }
        do {
            try await assetRepo.toggleArchive(asset.id, to: true)
            guard accountGeneration == LocalSnapshot.generation else { return }
            removeAsset(asset.id)
            // Cache lokal ikut ditambal, bukan cuma gridnya.
            //
            // Linimasa dirender DARI cache itu; membuang selnya saja berarti
            // fotonya muncul lagi pada rebuild berikutnya — dan rebuild terjadi
            // pada ketukan kedua tab Photos maupun setiap sync selesai.
            try? dataManager?.setTimelineVisibility([asset.id], inTimeline: false)
        } catch {
            actionError = Self.describe(error)
        }
    }

    @discardableResult
    func delete(_ asset: AssetLite) async -> Bool {
        // Foto yang belum ada di server bukan kegagalan API: tempatnya memang
        // hanya di PhotoKit, jadi penghapusannya harus lewat Photos.
        if asset.origin == .device {
            guard await LocalPhotoLibrary.shared.delete([asset.id]) else { return false }
            guard accountGeneration == LocalSnapshot.generation else { return false }
            removeAsset(asset.id)
            return true
        }

        guard let assetRepo,
              let target = serverDeleteTargets(for: [asset]).first
        else {
            actionError = String(localized: "Failed to find this photo on the server")
            return false
        }

        do {
            // Petak `.both` yang baru selesai diunggah masih dapat memakai id
            // `device:…`. Endpoint DELETE /assets hanya menerima UUID server.
            try await assetRepo.delete(target.serverID)
            guard accountGeneration == LocalSnapshot.generation else { return false }
            removeAsset(target.displayID)
            // Dihapus berarti BUANG dari cache, bukan disembunyikan.
            try? dataManager?.purgeAssets([target.serverID])
            return true
        } catch {
            actionError = Self.describe(error)
            return false
        }
    }

    /// Favorit MASSAL selalu menyalakan, bukan membalik satu per satu.
    ///
    /// Seleksi bisa berisi campuran; membalik masing-masing akan menghasilkan
    /// separuh menyala separuh padam — hasil yang tidak diminta siapa pun.
    @discardableResult
    func favoriteSelected(_ ids: [String]) async -> Bool {
        guard let assetRepo, !ids.isEmpty else { return false }
        do {
            for id in ids {
                try await assetRepo.toggleFavorite(id, to: true)
                guard accountGeneration == LocalSnapshot.generation else { return false }
                setFavorite(id, to: true)
            }
            return true
        } catch {
            actionError = Self.describe(error)
            return false
        }
    }

    /// Memindahkan seleksi ke arsip; fotonya keluar dari linimasa.
    @discardableResult
    func archiveSelected(_ ids: [String]) async -> Bool {
        guard let assetRepo, !ids.isEmpty else { return false }
        do {
            for id in ids {
                try await assetRepo.toggleArchive(id, to: true)
                guard accountGeneration == LocalSnapshot.generation else { return false }
            }
            removeAssets(Set(ids))
            try? dataManager?.setTimelineVisibility(ids, inTimeline: false)
            return true
        } catch {
            actionError = Self.describe(error)
            return false
        }
    }

    /// Memindahkan ke folder terkunci; fotonya keluar dari linimasa.
    @discardableResult
    func lockSelected(_ ids: [String]) async -> Bool {
        guard let assetRepo, !ids.isEmpty else { return false }
        do {
            for id in ids {
                try await assetRepo.setVisibility(id, to: .locked)
                guard accountGeneration == LocalSnapshot.generation else { return false }
            }
            removeAssets(Set(ids))
            try? dataManager?.setTimelineVisibility(ids, inTimeline: false)
            return true
        } catch {
            actionError = Self.describe(error)
            return false
        }
    }

    @discardableResult
    func deleteSelected(_ ids: [String]) async -> Bool {
        guard let assetRepo, !ids.isEmpty else { return false }

        let selected = ids.compactMap(asset(for:))
        guard !selected.isEmpty else { return false }

        // Satu seleksi dapat berisi tiga bentuk sekaligus:
        // - server: id-nya sudah UUID server;
        // - both dengan petak lokal: id tampilannya `device:…`, tetapi request
        //   harus memakai pasangan UUID server;
        // - device: belum ada di server dan harus dihapus lewat PhotoKit.
        let localOnly = selected.filter { $0.origin == .device }
        let serverTargets = serverDeleteTargets(
            for: selected.filter { $0.origin != .device })
        let unresolvedServerCount = selected.count - localOnly.count - serverTargets.count

        var removedDisplayIDs = Set<String>()
        var removedServerIDs = Set<String>()
        var failedCount = unresolvedServerCount
        var lastServerError: Error?

        if !localOnly.isEmpty,
           await LocalPhotoLibrary.shared.delete(localOnly.map(\.id)) {
            removedDisplayIDs.formUnion(localOnly.map(\.id))
        } else if !localOnly.isEmpty {
            // PhotoKit menampilkan dialog sistem. Membatalkannya bukan error
            // server dan tidak perlu memunculkan alert "Action Failed".
            failedCount += localOnly.count
        }

        guard accountGeneration == LocalSnapshot.generation else { return false }
        if !serverTargets.isEmpty {
            let result = await deleteServerTargets(serverTargets, using: assetRepo)
            guard accountGeneration == LocalSnapshot.generation else { return false }
            removedDisplayIDs.formUnion(result.succeeded.map(\.displayID))
            removedServerIDs.formUnion(result.succeeded.map(\.serverID))
            failedCount += result.failedCount
            lastServerError = result.lastError
        }

        removeAssets(removedDisplayIDs)
        try? dataManager?.purgeAssets(Array(removedServerIDs))

        guard failedCount == 0 else {
            // Kalau semuanya gagal, pesan asli server paling berguna. Pada
            // keberhasilan parsial, jumlahnya harus jujur supaya item yang sudah
            // hilang tidak ikut dilaporkan gagal.
            if removedDisplayIDs.isEmpty, let lastServerError {
                actionError = Self.describe(lastServerError)
            } else if lastServerError != nil || unresolvedServerCount > 0 {
                actionError = failedCount == 1
                    ? String(localized: "Failed to delete 1 item")
                    : String(localized: "Failed to delete \(failedCount) items")
            }
            return false
        }
        return true
    }

    /// Pasangan id yang dilihat grid dengan UUID yang diterima Immich.
    ///
    /// Detail Asset sudah melakukan terjemahan ini sejak awal. Menaruh aturan
    /// yang sama di view model timeline membuat context menu dan mode Select
    /// tidak lagi mengirim `PHAsset.localIdentifier` ke endpoint server.
    private struct ServerDeleteTarget {
        let displayID: String
        let serverID: String
    }

    private func serverDeleteTargets(for assets: [AssetLite]) -> [ServerDeleteTarget] {
        let links = dataManager?.serverAssetIDsByLocalIdentifier() ?? [:]
        return assets.compactMap { asset in
            if LocalPhotoLibrary.isLocal(asset.id) {
                let localID = LocalPhotoLibrary.localIdentifier(from: asset.id)
                guard let serverID = links[localID] else { return nil }
                return ServerDeleteTarget(displayID: asset.id, serverID: serverID)
            }
            return ServerDeleteTarget(displayID: asset.id, serverID: asset.id)
        }
    }

    /// Coba batch resmi lebih dahulu. Jika server menolak batch karena satu id
    /// stale/tidak dimiliki, pecah per id agar foto lain yang valid tetap
    /// terhapus. Error jaringan/auth tidak diulang N kali.
    private func deleteServerTargets(
        _ targets: [ServerDeleteTarget],
        using repo: AssetDetailRepository
    ) async -> (succeeded: [ServerDeleteTarget], failedCount: Int, lastError: Error?) {
        let uniqueServerIDs = Array(Set(targets.map(\.serverID)))
        do {
            try await repo.delete(uniqueServerIDs)
            return (targets, 0, nil)
        } catch {
            guard Self.shouldRetryDeleteIndividually(error) else {
                return ([], targets.count, error)
            }

            var succeededServerIDs = Set<String>()
            var lastError: Error?
            for serverID in uniqueServerIDs {
                do {
                    try await repo.delete(serverID)
                    succeededServerIDs.insert(serverID)
                } catch {
                    lastError = error
                }
            }

            let succeeded = targets.filter { succeededServerIDs.contains($0.serverID) }
            return (succeeded, targets.count - succeeded.count, lastError)
        }
    }

    private static func shouldRetryDeleteIndividually(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case .server(let status, _) = apiError
        else { return false }
        return status == 400 || status == 403 || status == 404
    }

    /// Unduh beberapa file asli sekaligus untuk share sheet. Yang gagal dilewati,
    /// bukan membatalkan seluruh operasi.
    func shareURLs(for ids: [String]) async -> [URL] {
        guard let assetRepo else { return [] }
        var urls: [URL] = []
        for id in ids {
            guard let data = try? await assetRepo.downloadOriginal(id) else { continue }
            if let url = try? TemporaryMediaStore.createShareFile(
                data: data,
                suggestedFilename: "\(id).jpg") {
                urls.append(url)
            }
        }
        return urls
    }

    func addToAlbum(_ asset: AssetLite, album: AlbumResponseDTO) async {
        await addToAlbum([asset.id], album: album)
    }

    func addToAlbum(_ ids: [String], album: AlbumResponseDTO) async {
        guard let albumRepo, !ids.isEmpty else { return }
        do {
            let duplicates = try await albumRepo.addAssets(ids, to: album.id)
            if !duplicates.isEmpty {
                // "Sudah ada di album" bukan kegagalan, tapi tetap harus
                // terdengar — tanpa itu aksinya tidak menghasilkan apa pun
                // yang terlihat.
                actionError = String(localized: "Already in this album")
            }
        } catch {
            actionError = Self.describe(error)
        }
    }

    /// Unduh file asli ke lokasi sementara untuk dibagikan lewat share sheet
    /// (URL server polos akan kena 401).
    func shareURL(for asset: AssetLite) async -> URL? {
        guard let assetRepo else { return nil }
        do {
            let data = try await assetRepo.downloadOriginal(asset.id)
            let filename = "\(asset.id).\(asset.isVideo ? "mov" : "jpg")"
            return try TemporaryMediaStore.createShareFile(
                data: data,
                suggestedFilename: filename)
        } catch {
            actionError = Self.describe(error)
            return nil
        }
    }

    /// Buang aset dari grid setelah dipindah/dihapus di layar detail.
    func assetWasRemoved(_ id: String) {
        removeAsset(id)
    }

    /// Metadata aset berubah di layar detail (tanggal, lokasi, deskripsi).
    ///
    /// Tanggal ikut menentukan bulan tempat foto itu berada, jadi perubahannya
    /// tidak cukup ditambal per sel — linimasanya disusun ulang. Sumbernya cache
    /// lokal, jadi ini murni pekerjaan di perangkat, bukan permintaan baru.
    func assetWasUpdated(_ id: String) async {
        await loadTimeline()
    }

    /// Menghapus banyak aset dalam SATU transaksi animasi.
    ///
    /// Memanggil `removeAsset` per id akan memicu animasi terpisah untuk tiap
    /// foto, sehingga grid terlihat berkedut menyusun ulang berkali-kali.
    private func removeAssets(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            var updatedSections = sections
            var changedMonths = Set<String>()
            for idx in updatedSections.indices {
                let previousCount = updatedSections[idx].assets.count
                updatedSections[idx].assets.removeAll { ids.contains($0.id) }
                updatedSections[idx].count = updatedSections[idx].assets.count
                if updatedSections[idx].assets.count != previousCount {
                    changedMonths.insert(updatedSections[idx].id)
                }
            }
            guard !changedMonths.isEmpty else { return }
            updatedSections.removeAll { $0.assets.isEmpty }
            allAssets.removeAll { ids.contains($0.id) }
            // Kalau yang terakhir ikut terbuang, tidak ada lagi yang "sudah ada
            // di perangkat" — dan pemuatan berikutnya memang pantas diberi
            // spinner.
            hasLocalData = !allAssets.isEmpty
            reindex(&updatedSections)
            // Hanya bulan yang kehilangan aset perlu memilih ulang tanggal
            // teramai. Bulan lain memakai highlight yang sudah tersimpan.
            let unchangedMonths = Dictionary(uniqueKeysWithValues: content.months
                .filter { !changedMonths.contains($0.id) }
                .map { ($0.id, $0) })
            content = Self.makeContent(
                sections: updatedSections,
                calendar: calendar,
                reusingMonths: unchangedMonths)
            // Isinya baru saja berubah di klien; sidik jari lama tidak lagi
            // mewakili apa pun, dan menahannya akan membuat muat ulang
            // berikutnya dilewati.
            signature = nil
        }
    }

    private func removeAsset(_ id: String) {
        removeAssets([id])
    }

    /// `startIndex` adalah posisi foto pertama sebuah bulan dalam urutan datar.
    ///
    /// Grid memakainya untuk tahu bulan apa yang sedang tampil tanpa memecah
    /// dirinya per bulan, jadi setelah ada foto yang dibuang offsetnya harus
    /// dirapatkan lagi — kalau tidak, judul bulan di toolbar meleset.
    private func reindex(_ sections: inout [TimelineSection]) {
        var offset = 0
        for index in sections.indices {
            sections[index].startIndex = offset
            offset += sections[index].assets.count
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }

    /// Dipanggil sekali per SECTION, bukan per aset — jumlahnya belasan sampai
    /// ratusan, jadi `DateFormatter` di sini tidak masalah.
    nonisolated static func formatBucketTitle(_ bucket: String) -> String {
        guard let date = MonthKey.date(from: bucket) else { return bucket }
        return monthTitleFormatter.string(from: date)
    }

    nonisolated static func formatNavigatorMonthTitle(_ bucket: String) -> String {
        guard let date = MonthKey.date(from: bucket) else { return bucket }
        return navigatorMonthTitleFormatter.string(from: date)
    }
}

private let monthTitleFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = .current
    f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
    return f
}()

private let navigatorMonthTitleFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = .current
    f.setLocalizedDateFormatFromTemplate("MMM yyyy")
    return f
}()
