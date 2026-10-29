import SwiftUI

/// Aksi foto yang muncul di context menu, dipakai bersama oleh timeline dan
/// baris Favorites di Collections.
///
/// Dikumpulkan dalam satu tipe supaya keduanya tidak bisa berbeda isi —
/// menyalin daftar tombolnya per layar hanya menunggu keduanya menyimpang.
struct AssetActionsMenu: View {
    let asset: AssetLite
    var onShare: () -> Void
    var onToggleFavorite: () -> Void
    var onArchive: () -> Void
    var onAddToAlbum: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button(action: onShare) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        // Teks dan ikonnya mengikuti status sekarang, bukan selalu "Favorite".
        Button(action: onToggleFavorite) {
            Label(
                asset.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: asset.isFavorite ? "heart.fill" : "heart")
        }

        Button(action: onArchive) {
            Label("Archive", systemImage: "archivebox")
        }

        // Sheet, bukan submenu: daftar album bisa panjang dan butuh pencarian.
        Button(action: onAddToAlbum) {
            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// Pratinjau context menu dengan rasio asli foto.
///
/// Sel grid maupun kartu Favorites sengaja dipaksa persegi agar rapi, dan tanpa
/// pratinjau kustom iOS memakai sel itu apa adanya — hasilnya ikut kotak dan
/// terpotong.
struct AssetContextPreview: View {
    let asset: AssetLite
    /// Disuntikkan lewat parameter, BUKAN `@Environment`.
    ///
    /// Pratinjau context menu dirender di hosting controller terpisah yang
    /// tidak mewarisi environment view pemanggil; tanpa ini `AuthImage` crash
    /// saat membaca `SessionManager`.
    let session: SessionManager
    var visibilityPolicy = AssetVisibilityPolicy()

    var body: some View {
        let size = previewSize
        Group {
            if visibilityPolicy.allows(id: asset.id) {
                AuthImage(
                    assetId: asset.id,
                    size: "preview",
                    thumbhash: asset.thumbhash,
                    contentMode: .fit,
                    // Pratinjau tidak pernah lebih besar dari 320×460pt; 2048px hanya
                    // membayar bitmap belasan megabyte untuk sesuatu yang muncul sekejap.
                    pixelSize: 1400)
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(session)
    }

    /// Rasio dari GAMBARNYA, bukan dari metadata.
    ///
    /// `asset.ratio` dihitung dari `exifInfo`, dan tidak semua jalur mengirim
    /// exif — untuk aset yang datang dari pencarian (Favorites, People, Search,
    /// Archived, Trash) ia jatuh ke nilai cadangan 1.0. Akibatnya pratinjaunya
    /// PERSEGI, sementara di linimasa — yang rasionya datang dari kolom `ratio`
    /// server — bentuknya benar.
    ///
    /// Gambarnya sendiri selalu tahu rasionya, dan thumbnail-nya pasti sudah ada
    /// di memori: petak yang sedang ditekan-lama ini baru saja menggambarnya.
    private var imageRatio: Double? {
        let key = ImageCache.memoryKey(
            "\(asset.id)-thumbnail", PhotoThumbnailLoader.maxPixelSize)
        guard let image = ImageMemoryCache.shared.image(for: key),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        return Double(image.size.width / image.size.height)
    }

    /// Muat dalam kotak wajar tanpa mengubah rasio: mulai dari lebar tetap,
    /// lalu kunci tingginya kalau fotonya terlalu panjang.
    private var previewSize: CGSize {
        let ratio = imageRatio ?? (asset.ratio > 0 ? asset.ratio : 1)
        let maxWidth: CGFloat = 320
        let maxHeight: CGFloat = 460

        var size = CGSize(width: maxWidth, height: maxWidth / ratio)
        if size.height > maxHeight {
            size = CGSize(width: maxHeight * ratio, height: maxHeight)
        }
        return size
    }
}
