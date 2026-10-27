import Observation
import SwiftUI

/// Penyelesai sampul album.
///
/// `albumThumbnailAssetId` di Immich BOLEH kosong. Kolomnya nullable, dan server
/// hanya mengisinya di jalur-jalur tertentu — saat album dibuat lewat API dengan
/// aset, saat aset pertama ditambahkan lewat API, atau saat pengguna memilih
/// sampul sendiri. Album yang isinya masuk lewat jalur lain (impor CLI, external
/// library, job latar) sah-sah saja punya sampul null selamanya.
///
/// Selama ini setiap tempat yang menggambar sampul menulis
/// `if let album.albumThumbnailAssetId { … } else { kotak abu-abu }` sendiri —
/// lima salinan, semuanya menganggap field itu pasti terisi. Ketika server
/// mengirim null, yang muncul kotak abu-abu, dan tidak ada satu pun yang mencoba
/// mencari gantinya.
///
/// Jadi sampul TIDAK lagi diperlakukan sebagai field, melainkan sesuatu yang
/// DISELESAIKAN: pakai yang dari server kalau ada, kalau tidak ambil aset
/// terbaru album itu.
@MainActor
@Observable
final class AlbumCoverStore {
    static let shared = AlbumCoverStore()

    private struct Resolution {
        let assetCount: Int
        let assetID: String?
    }

    private struct Request {
        let assetCount: Int
        let task: Task<Result<String?, Error>, Never>
    }

    /// A nil asset ID caches an empty result only for this album count.
    /// Count changes must resolve again, including an empty album gaining photos.
    private var resolved: [String: Resolution] = [:]

    /// Permintaan yang sedang berjalan, supaya beberapa kartu album yang sama
    /// tidak menembak endpoint yang sama berbarengan.
    ///
    /// Diabaikan observasi: ini pembukuan internal, dan mengamatinya berarti
    /// setiap kartu tergambar ulang dua kali percuma (saat permintaan dicatat
    /// dan saat dihapus).
    @ObservationIgnored
    private var inFlight: [String: Request] = [:]

    /// Penanda "angkatan" data.
    ///
    /// Dinaikkan tiap `clear()`. Permintaan yang sedang menggantung saat logout
    /// tetap akan selesai dan kembali ke sini — tanpa penanda ini, id aset milik
    /// akun LAMA akan ditulis balik ke `resolved` setelah dibersihkan, dan
    /// pembersihannya jadi percuma.
    @ObservationIgnored
    private var generation = 0

    init() {}

    /// Sampul yang berlaku sekarang — dari server kalau ada, kalau tidak hasil
    /// yang sudah diselesaikan. Sinkron, karena inilah yang dibaca `body`.
    func coverID(for album: AlbumResponseDTO) -> String? {
        if let id = album.albumThumbnailAssetId { return id }
        guard let cached = resolved[album.id], cached.assetCount == album.assetCount else { return nil }
        return cached.assetID
    }

    func resolveCover(for album: AlbumResponseDTO, session: SessionManager) async {
        await resolveCover(for: album, repository: AlbumRepository(api: APIClient(session: session)))
    }

    func resolveCover(for album: AlbumResponseDTO, repository: AlbumRepository) async {
        // Server sudah menyebutkan sampulnya; tidak ada yang perlu dicari.
        guard album.albumThumbnailAssetId == nil else { return }
        guard resolved[album.id]?.assetCount != album.assetCount else { return }

        // Kartu lain sudah menanyakannya. Cukup tunggu; hasilnya ditulis oleh
        // pemanggil pertama dan view ini tergambar ulang karena `resolved`
        // diamati.
        if let running = inFlight[album.id] {
            if running.assetCount == album.assetCount {
                _ = await running.task.value
                return
            }
            inFlight.removeValue(forKey: album.id)?.task.cancel()
        }

        // Album kosong tidak punya apa pun untuk dijadikan sampul; tidak ada
        // gunanya menanyakannya ke server.
        guard album.assetCount > 0 else {
            remember(nil, for: album)
            return
        }

        let albumID = album.id
        let expectedGeneration = generation
        let task = Task<Result<String?, Error>, Never> {
            do {
                return .success(try await repository.recentAssetIDs(in: albumID, limit: 1).first)
            } catch {
                return .failure(error)
            }
        }
        inFlight[albumID] = Request(assetCount: album.assetCount, task: task)
        let outcome = await task.value

        // Sudah ganti akun selagi permintaan ini berjalan — hasilnya milik data
        // yang sudah dibuang, termasuk `inFlight` yang mungkin sudah diisi
        // permintaan baru untuk album lain.
        guard expectedGeneration == generation,
              inFlight[albumID]?.task == task
        else { return }
        inFlight[albumID] = nil

        // Kegagalan jaringan TIDAK dicatat. Kalau dicatat, satu permintaan yang
        // meleset membuat album itu memakai kotak abu-abu sampai aplikasi
        // ditutup — padahal sampulnya ada, cuma gagal diambil sekali.
        guard case .success(let id) = outcome else { return }
        remember(id, for: album)
    }

    /// Dipanggil saat logout: id album milik akun lama tidak boleh menempel di
    /// akun berikutnya.
    func clear() {
        generation &+= 1
        resolved.removeAll()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    /// Isi satu album berubah. Hasil fallback lama tidak boleh terus dipakai,
    /// khususnya ketika aset yang menjadi cover baru saja dihapus.
    func invalidate(_ albumID: String) {
        resolved.removeValue(forKey: albumID)
        inFlight.removeValue(forKey: albumID)?.task.cancel()
    }

    private func remember(_ assetID: String?, for album: AlbumResponseDTO) {
        resolved[album.id] = Resolution(assetCount: album.assetCount, assetID: assetID)
    }
}

/// Sampul album — satu-satunya tempat sampul digambar.
///
/// Mengisi frame yang diberikan pemanggil; ukuran dan pemotongan sudutnya
/// ditentukan di tempat pemakaian.
struct AlbumCoverImage: View {
    let album: AlbumResponseDTO
    /// Ukuran yang diminta ke server. "thumbnail" untuk kartu, "preview" untuk
    /// pratinjau besar.
    var size: String = "thumbnail"
    var pixelSize: Int? = nil
    /// Besar ikon pengganti saat albumnya benar-benar tidak punya sampul.
    var placeholderFont: Font = .body

    @Environment(SessionManager.self) private var session

    var body: some View {
        ZStack {
            if let coverID = AlbumCoverStore.shared.coverID(for: album) {
                AuthImage(assetId: coverID, size: size, pixelSize: pixelSize)
            } else {
                Rectangle()
                    .fill(.fill.tertiary)
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .font(placeholderFont)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        // Count/cover menjadi bagian id task agar perubahan isi album memicu
        // penyelesaian ulang fallback walau id albumnya tetap sama.
        .task(id: "\(album.id)|\(album.assetCount)|\(album.albumThumbnailAssetId ?? "")") {
            await AlbumCoverStore.shared.resolveCover(for: album, session: session)
        }
    }
}
