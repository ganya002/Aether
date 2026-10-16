import Foundation

enum CloudCatalog {
    struct Endpoint {
        var enroll: URL
        var sessionHost: String
        var sessionPort: Int
        var ws: String
    }

    static func published() async -> Endpoint? {
        guard let url = await enrollURL() else { return nil }
        let scheme = url.scheme == "http" ? "ws" : "wss"
        var host = url.host ?? ""
        if let port = url.port {
            host += ":\(port)"
        }
        return Endpoint(enroll: url, sessionHost: url.host ?? "", sessionPort: url.port ?? 7391, ws: "\(scheme)://\(host)/ws")
    }

    static func enroll(at endpoint: Endpoint) async throws -> (host: String, token: String, ws: String) {
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
        let ws = (json["ws"] as? String) ?? ""
        guard !host.isEmpty || !ws.isEmpty else { throw SessionError.server("The Cloud service did not name a host.") }
        guard !ws.isEmpty else { throw SessionError.server("Cloud isn't publicly available yet.") }
        return (host, token, ws)
    }

    static func pair(token: String, ws: String) async throws -> (code: String, url: String) {
        guard var parts = URLComponents(string: ws), parts.scheme == "wss" || parts.scheme == "ws" else {
            throw SessionError.server("Cloud has no public address yet.")
        }
        parts.scheme = parts.scheme == "wss" ? "https" : "http"
        parts.path = "/pair"
        parts.query = nil
        guard let url = parts.url else { throw SessionError.server("Cloud has no public address yet.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String, !code.isEmpty else {
            throw SessionError.server("Could not make a code for another device.")
        }
        return (code, (json["url"] as? String) ?? "")
    }

    private static func enrollURL() async -> URL? {
        if let remote = await remoteEnroll() { return remote }
        return bundledEnroll()
    }

    private static func remoteEnroll() async -> URL? {
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
