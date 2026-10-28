import SwiftUI

/// Satu pilihan di dalam menu konfirmasi sebuah tombol.
struct SelectionConfirmationOption: Identifiable {
    /// Judulnya sendiri yang jadi identitas, BUKAN `UUID()`.
    ///
    /// Daftar ini dirakit ulang oleh properti terhitung pada setiap evaluasi
    /// body. Dengan UUID baru tiap kali, seluruh tombol di dalam `ForEach`
    /// berganti identitas — dan menu yang sedang terbuka dibongkar-pasang ulang
    /// setiap kali ada apa pun di layar yang berubah.
    var id: String { title }
    /// `String`, bukan `LocalizedStringKey`: judulnya sering dirakit dari
    /// jumlah item ("Delete 3 Items"), dan markup lokalisasi tidak diproses
    /// untuk teks yang sudah terlanjur jadi `String`.
    let title: String
    var isDestructive = false
    let handler: () -> Void
}

/// Konfirmasi yang MENEMPEL pada tombolnya.
///
/// Sebelumnya dialog dipasang di level layar dan tombolnya cuma menyalakan
/// sebuah bendera. Itu bekerja, tapi memutus hubungan antara apa yang ditekan
/// dan apa yang ditanyakan.
struct SelectionConfirmation {
    let title: String
    var message: String? = nil
    let options: [SelectionConfirmationOption]
}

/// Tombol bar seleksi yang membawa konfirmasinya sendiri.
///
/// `confirmationDialog` yang menempel pada tombolnya — bentuk yang sama dengan
/// tombol hapus di layar detail aset, dan alasannya sama: pilihannya tampil
/// sebagai tombol penuh lebar yang jelas bisa ditekan, bukan baris menu yang
/// terbaca seperti daftar.
private struct SelectionConfirmButton: View {
    let confirmation: SelectionConfirmation
    let systemImage: String
    let title: String
    let isDisabled: Bool

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .disabled(isDisabled)
        .confirmationDialog(
            confirmation.title,
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            ForEach(confirmation.options) { option in
                Button(option.title, role: option.isDestructive ? .destructive : nil) {
                    option.handler()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let message = confirmation.message {
                Text(message)
            }
        }
    }
}

/// Satu aksi di menu elipsis mode pilih.
struct SelectionMenuAction: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let systemImage: String
    var isDestructive = false
    let handler: () -> Void
}

/// Aksi yang tersedia untuk seleksi di sebuah layar.
///
/// Semuanya opsional: layar yang tidak punya arti untuk sebuah aksi cukup
/// membiarkannya nil, dan tombolnya tidak ikut digambar. Itu yang membuat satu
/// bar bisa dipakai linimasa, album, favorit, arsip, dan tong sampah sekaligus
/// tanpa masing-masing menyalin susunannya sendiri — dan tanpa Trash memamerkan
/// tombol "Archive" yang tidak berarti apa-apa di sana.
struct SelectionActions {
    var share: (() -> Void)?
    var favorite: (() -> Void)?
    var archive: (() -> Void)?
    var archiveTitle = String(localized: "Archive")
    /// Hanya tong sampah yang punya arti untuk ini.
    var restore: (() -> Void)?
    var trash: (() -> Void)?
    /// Konfirmasi yang muncul DARI tombolnya sendiri.
    ///
    /// Kalau diisi, ia menggantikan aksi langsung pada slot yang sama —
    /// tombolnya membuka menu konfirmasi, bukan menjalankan sesuatu.
    var restoreConfirmation: SelectionConfirmation?
    var trashConfirmation: SelectionConfirmation?
    /// Isi menu elipsis di kanan. Kosong berarti elipsisnya tidak muncul.
    var menu: [SelectionMenuAction] = []
    /// Ada pekerjaan yang sedang berjalan; tombolnya dimatikan sementara.
    var isBusy = false
}

/// Bar bawah mode pilih: satu grup aksi cepat di kiri, elipsis di kanan.
///
/// Dipisah dari layarnya karena dipakai lima layar, dan karena `body` layar-layar
/// itu sudah sepanjang batas yang sanggup diperiksa pengecek tipe Swift —
/// menambahkan susunan ini langsung di sana rutin berujung "unable to type-check
/// this expression".
struct SelectionToolbar: ToolbarContent {
    let actions: SelectionActions

    var body: some ToolbarContent {
        // `ToolbarItemGroup`, BUKAN beberapa `ToolbarItem` berdampingan.
        //
        // Grup memberi satu kapsul kaca bersama — itu yang membuatnya terbaca
        // sebagai satu kelompok aksi, bukan tombol-tombol lepas. Dan yang lebih
        // penting: aksi yang nil benar-benar hilang. `ToolbarItem` berisi
        // `EmptyView` tetap memesan slotnya, jadi di Trash — yang tidak punya
        // favorite maupun archive — akan tersisa dua kotak kaca kosong di antara
        // share dan sampah.
        ToolbarItemGroup(placement: .bottomBar) {
            button(actions.share, "square.and.arrow.up", String(localized: "Share"))
            button(actions.favorite, "heart", String(localized: "Favorite"))
            button(actions.archive, "archivebox", actions.archiveTitle)
            confirmingButton(actions.restoreConfirmation, actions.restore, "arrow.uturn.backward", String(localized: "Restore"))
            confirmingButton(actions.trashConfirmation, actions.trash, "trash", String(localized: "Delete"))
        }

        // Elipsisnya ikut hilang saat menunya kosong, berikut spacer-nya —
        // spacer yang menyisakan ruang untuk sesuatu yang tidak ada hanya
        // membuat grup kirinya terlihat terdampar.
        if !actions.menu.isEmpty {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { menuButton }
        }
    }

    @ViewBuilder
    private func button(_ action: (() -> Void)?, _ systemImage: String, _ title: String) -> some View {
        if let action {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .labelStyle(.iconOnly)
            .disabled(actions.isBusy)
        }
    }

    @ViewBuilder
    private func confirmingButton(
        _ confirmation: SelectionConfirmation?,
        _ fallback: (() -> Void)?,
        _ systemImage: String,
        _ title: String
    ) -> some View {
        if let confirmation {
            SelectionConfirmButton(
                confirmation: confirmation,
                systemImage: systemImage,
                title: title,
                isDisabled: actions.isBusy)
        } else {
            button(fallback, systemImage, title)
        }
    }

    @ViewBuilder
    private var menuButton: some View {
        if !actions.menu.isEmpty {
            Menu {
                ForEach(actions.menu) { item in
                    Button(role: item.isDestructive ? .destructive : nil) {
                        item.handler()
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .disabled(actions.isBusy)
        }
    }
}
