import Foundation

enum HTTPMethod: String { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

struct Endpoint {
    var path: String
    var method: HTTPMethod = .get
    var query: [URLQueryItem] = []
    var body: Data? = nil
    var extraHeaders: [String: String] = [:]
    var requiresAuthentication: Bool = true

    static func json<T: Encodable>(
        _ path: String, method: HTTPMethod, body: T, requiresAuthentication: Bool = true
    ) -> Endpoint {
        let data = try? JSONEncoder.immich.encode(body)
        return Endpoint(path: path, method: method, body: data,
                        requiresAuthentication: requiresAuthentication)
    }
}
