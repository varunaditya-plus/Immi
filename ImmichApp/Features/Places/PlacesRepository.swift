import Foundation

/// Satu kota beserta foto yang mewakilinya.
struct PlaceItem: Identifiable, Hashable {
    /// Nama kota sekaligus identitasnya — server tidak memberi id tersendiri,
    /// dan namanya memang unik dalam respons `/search/explore`.
    var id: String { name }
    let name: String
    let asset: AssetLite
}

/// Pin di peta. `/map/markers` sengaja mengembalikan bentuk seringan mungkin
/// (hanya id dan koordinat) supaya ribuan titik bisa dimuat sekaligus.
/// `Codable`, bukan `Decodable` saja: penanda peta ikut dipotret ke disk supaya
/// Places tetap berpenghuni saat offline. Sintesisnya harus di sini — Swift
/// menolak mensintesisnya dari extension di berkas lain.
struct MapMarkerDTO: Codable, Identifiable, Hashable {
    let id: String
    let lat: Double
    let lon: Double
    let city: String?
    let state: String?
    let country: String?
}

final class PlacesRepository {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// Daftar kota dari `/search/explore`.
    ///
    /// Endpoint yang sama juga mengembalikan kelompok "people"; hanya bagian
    /// kota yang diambil di sini.
    func places() async throws -> [PlaceItem] {
        let groups: [SearchExploreItemDTO] = try await api.send(
            .init(path: "/search/explore"))

        guard let cities = groups.first(where: { $0.fieldName == "city" }) else {
            return []
        }
        return cities.items.filter { $0.data.isTimelineVisible }
            .map { PlaceItem(name: $0.value, asset: AssetLite($0.data)) }
    }

    func markers() async throws -> [MapMarkerDTO] {
        try await api.send(.init(path: "/map/markers"))
    }
}
