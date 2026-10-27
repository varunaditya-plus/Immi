import Foundation
import Observation

@MainActor
@Observable
final class AssetDetailViewModel {
    private let snapshotGeneration = LocalSnapshot.generation

    var detail: AssetResponseDTO?
    var phase: LoadingPhase<Void> = .idle
    var showInfoPanel = false
    /// Kegagalan aksi terakhir yang dipicu pengguna.
    ///
    /// `ErrorEvent`, bukan `String?`: dua kegagalan yang berbunyi sama harus
    /// tetap terhitung dua kejadian — lihat alasannya di `ErrorEvent`.
    var actionError: ErrorEvent?
    var albums: [AlbumResponseDTO] = []
    /// Album yang MEMUAT foto ini — untuk panel info, bukan untuk menu tambah.
    ///
    /// Dipisah dari `albums` karena artinya berbeda: yang satu "ke mana foto ini
    /// bisa ditambahkan", yang ini "foto ini sudah ada di mana saja". Menyatukan
    /// keduanya berarti menu tambah cuma menampilkan album yang sudah memuatnya.
    var containingAlbums: [AlbumResponseDTO] = []

    private let repo: AssetDetailRepository
    private let albumRepo: AlbumRepository?

    init(repo: AssetDetailRepository, albumRepo: AlbumRepository? = nil) {
        self.repo = repo
        self.albumRepo = albumRepo
    }

    /// Daftar album untuk menu "Add to Album"; cukup dimuat sekali.
    func loadAlbumsIfNeeded() async {
        guard albums.isEmpty, let albumRepo else { return }
        albums = (try? await albumRepo.all()) ?? []
    }

    /// Album yang memuat foto ini. Dimuat ulang setiap kali fotonya berganti.
    ///
    /// Kegagalan dibiarkan senyap: ini keterangan tambahan di bagian paling bawah
    /// panel, dan memunculkan alert karena satu daftar tidak datang akan lebih
    /// mengganggu daripada barisnya yang tidak ada.
    func loadContainingAlbums(_ id: String) async {
        guard let albumRepo else { return }
        containingAlbums = (try? await albumRepo.albums(containing: id)) ?? []
    }

    func addToAlbum(_ id: String, album: AlbumResponseDTO) async {
        guard let albumRepo else { return }
        do {
            let duplicates = try await albumRepo.addAssets([id], to: album.id)
            // Toast yang sama dipakai untuk kabar biasa, bukan cuma kegagalan:
            // "sudah ada di album" bukan error, tapi tetap harus terdengar —
            // tanpa itu, menekan "Add to Album" untuk foto yang sudah ada di
            // sana tidak menghasilkan apa pun yang terlihat.
            if !duplicates.isEmpty {
                actionError = ErrorEvent(String(localized: "Already in this album"))
            }
        } catch {
            actionError = ErrorEvent(Self.describe(error))
        }
    }

    /// Potret lokal dulu, jaringan menyusul — dan kegagalannya DIAM.
    ///
    /// Memuat detail bukan sesuatu yang diminta pengguna; ia terjadi sendiri
    /// saat foto dibuka dan sekali lagi setiap kali digeser. Mengabarkan
    /// kegagalannya berarti satu kabar per geseran — dan di perjalanan tanpa
    /// sinyal, itu berubah jadi rentetan yang menghalangi hal yang justru sedang
    /// dilakukan pengguna. Yang bersuara hanya kegagalan yang MEREKA picu
    /// sendiri: favorit, bagikan, arsip, hapus.
    func load(_ id: String) async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        // Foto perangkat tidak punya detail di server, dan menanyakannya bukan
        // sekadar sia-sia: jawabannya 404, dan itu membuat petaknya dibuang dari
        // linimasa. Panel info-nya memang kosong — yang diketahui tentang foto
        // ini semuanya sudah ada di `AssetLite`.
        guard !LocalPhotoLibrary.isLocal(id) else {
            detail = nil
            phase = .loaded(())
            return
        }

        let key = LocalSnapshot.Key.assetDetail(id)

        // Foto lain, jadi detail foto SEBELUMNYA harus lepas dulu.
        //
        // Tanpa ini, satu geseran yang gagal meninggalkan panel info yang masih
        // menampilkan metadata foto lama di bawah foto yang baru — kebohongan
        // yang jauh lebih buruk daripada panel kosong.
        if detail?.id != id {
            detail = LocalSnapshot.load(AssetResponseDTO.self, for: key)
        }
        phase = detail == nil ? .loading : .loaded(())

        do {
            let fetched = try await repo.fetchAsset(id)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            detail = fetched
            LocalSnapshot.save(fetched, for: key, expectedGeneration: snapshotGeneration)
            phase = .loaded(())
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            let message = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to load asset")
            phase = .failed(message)
            // Kalau alasannya aset itu memang tidak bisa dibaca lagi, ia juga
            // dibuang dari linimasa — kalau tidak, petaknya tetap di sana dan
            // pesan ini muncul lagi setiap kali ditekan.
            UnreadableAssets.shared.report(id, error: error)
            if (error as? APIError)?.meansAssetIsUnreadable == true {
                LocalSnapshot.remove(key, expectedGeneration: snapshotGeneration)
            }
        }
    }

    /// Mengembalikan true kalau server menerima perubahannya, supaya view bisa
    /// memicu animasi dan haptic hanya saat benar-benar berhasil.
    @discardableResult
    func toggleFavorite(_ id: String) async -> Bool {
        let newValue = !(detail?.isFavorite ?? false)
        do {
            try await repo.toggleFavorite(id, to: newValue)
            detail?.isFavorite = newValue
            persistDetail()
            return true
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return false
        }
    }

    @discardableResult
    func updateDescription(_ id: String, to text: String) async -> Bool {
        do {
            try await repo.updateDescription(id, to: text)
            detail?.exifInfo?.description = text
            persistDetail()
            return true
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return false
        }
    }

    /// Tanggal & lokasi tersimpan di beberapa field turunan (`fileCreatedAt`,
    /// `localDateTime`, `exifInfo`), jadi lebih aman memuat ulang detailnya
    /// daripada menambal satu per satu di sisi klien.
    func updateDate(_ id: String, to date: Date) async {
        do {
            try await repo.updateDate(id, to: date)
            await load(id)
        } catch {
            actionError = ErrorEvent(Self.describe(error))
        }
    }

    func updateLocation(_ id: String, latitude: Double, longitude: Double) async {
        do {
            try await repo.updateLocation(id, latitude: latitude, longitude: longitude)
            await load(id)
        } catch {
            actionError = ErrorEvent(Self.describe(error))
        }
    }

    /// Memindahkan aset keluar dari timeline (arsip / locked folder).
    /// Mengembalikan true kalau berhasil, supaya view bisa menutup layarnya —
    /// asetnya memang tidak lagi ada di daftar yang sedang dibuka.
    @discardableResult
    func move(_ id: String, to visibility: AssetDetailRepository.Visibility) async -> Bool {
        do {
            try await repo.setVisibility(id, to: visibility)
            return true
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return false
        }
    }

    func toggleArchive(_ id: String) async {
        let newValue = !(detail?.isArchived ?? false)
        do {
            try await repo.toggleArchive(id, to: newValue)
            detail?.isArchived = newValue
            persistDetail()
        } catch {
            actionError = ErrorEvent(Self.describe(error))
        }
    }

    /// Mengembalikan true kalau server mengonfirmasi penghapusan,
    /// supaya view bisa menutup layarnya.
    func delete(_ id: String) async -> Bool {
        do {
            try await repo.delete(id)
            // Fotonya sudah tidak ada; potret detailnya tidak boleh menunggu
            // seseorang membukanya lagi untuk dibersihkan.
            LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id), expectedGeneration: snapshotGeneration)
            return true
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return false
        }
    }

    /// Unduh file asli lewat request terautentikasi (URL polos akan kena 401).
    func downloadOriginal(_ id: String) async -> Data? {
        do {
            return try await repo.downloadOriginal(id)
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return nil
        }
    }

    func downloadOriginalFile(_ id: String, filename: String) async -> URL? {
        do {
            return try await repo.downloadOriginalFile(id, filename: filename)
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return nil
        }
    }

    @discardableResult
    func applyEdits(_ edits: [AssetEditCommand], to id: String) async -> Bool {
        do {
            if edits.isEmpty {
                try await repo.removeEdits(from: id)
            } else {
                try await repo.applyEdits(edits, to: id)
            }
            return true
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return false
        }
    }

    func edits(for id: String) async -> [AssetEditRecord]? {
        do {
            return try await repo.edits(for: id)
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return nil
        }
    }

    @discardableResult
    func setProfileImage(_ data: Data, filename: String) async -> Bool {
        do {
            try await repo.setProfileImage(data, filename: filename)
            return true
        } catch {
            actionError = ErrorEvent(Self.describe(error))
            return false
        }
    }

    func retry(_ id: String) async {
        await load(id)
    }

    /// Menulis ulang potret detail setelah ditambal di tempat.
    ///
    /// Tanpa ini, membalik favorit lalu membuka foto yang sama saat offline akan
    /// menampilkan status lamanya — dan hati yang tidak sesuai dengan yang baru
    /// saja ditekan lebih membingungkan daripada tidak ada informasi sama
    /// sekali.
    private func persistDetail() {
        guard let detail else { return }
        LocalSnapshot.save(detail, for: LocalSnapshot.Key.assetDetail(detail.id), expectedGeneration: snapshotGeneration)
    }

    private static func describe(_ error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}
