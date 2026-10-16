import Foundation

enum CloudCatalog {
    struct Endpoint {
        var enroll: URL
        var sessionHost: String
        var sessionPort: Int
    }

    static func published() async -> Endpoint? {
        guard let url = await enrollURL() else { return nil }
        return Endpoint(enroll: url, sessionHost: url.host ?? "", sessionPort: 7391)
    }

    static func enroll(at endpoint: Endpoint) async throws -> (host: String, token: String) {
        var request = URLRequest(url: endpoint.enroll)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SessionError.server("The Cloud service refused the connection.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            throw SessionError.server("The Cloud service did not return a session.")
        }
        let host = (json["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? endpoint.sessionHost
        guard !host.isEmpty else { throw SessionError.server("The Cloud service did not name a host.") }
        return (host, token)
    }

    private static func enrollURL() async -> URL? {
        if let bundled = bundledEnroll() { return bundled }
        guard let remote = URL(string: "https://raw.githubusercontent.com/ganya002/Aether/main/cloud.json") else { return nil }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["enroll"] as? String else { return nil }
        return URL(string: raw)
    }

    private static func bundledEnroll() -> URL? {
        guard let url = Bundle.main.url(forResource: "cloud", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["enroll"] as? String,
              let enroll = URL(string: raw), !raw.isEmpty else { return nil }
        return enroll
    }
}
