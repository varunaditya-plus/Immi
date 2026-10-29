/// Durasi ala Immich: `"0:01:23.45000"`.
///
/// Respons aset lama dan baris SyncAssetV1 menggunakan format jam yang sama.
enum ClockDuration {
    /// "0:01:23.45000" → 83.45 detik. nil kalau bukan format jam.
    static func seconds(fromClock text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }

        // Bagian yang tidak terbaca membuat SELURUH nilainya batal, bukan
        // dilewati. Melewatinya (`compactMap`) berarti "1:xx:35" diam-diam
        // dibaca sebagai 1 menit 35 detik — sisa bagiannya bergeser tempat dan
        // hasilnya angka yang salah tanpa ada tanda apa pun.
        let components = text.split(separator: ":")
        let parts = components.compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == components.count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
