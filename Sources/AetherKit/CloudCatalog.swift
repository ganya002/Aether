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
        return endpoint(for: url)
    }

    static func endpoint(for url: URL) -> Endpoint? {
        guard url.scheme?.lowercased() == "https", let name = url.host, !name.isEmpty else { return nil }
        var host = name
        if let port = url.port {
            host += ":\(port)"
        }
        return Endpoint(enroll: url, sessionHost: name, sessionPort: url.port ?? 7391, ws: "wss://\(host)/ws")
    }

    /// Enrolling hands out a token, so it only happens over https.
    static func enrollURL(from raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The token rides on this socket. Plain ws is only allowed to this Mac, for running the server locally.
    static func socketURL(from raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty else { return nil }
        switch url.scheme?.lowercased() {
        case "wss": return url
        case "ws": return isLoopback(host) ? url : nil
        default: return nil
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return bare == "localhost" || bare == "::1" || bare.hasPrefix("127.")
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
        guard let socket = socketURL(from: ws) else { throw SessionError.server("The Cloud service gave an address that isn't secure.") }
        return (host, token, socket.absoluteString)
    }

    static func pair(token: String, ws: String) async throws -> (code: String, url: String) {
        guard let socket = socketURL(from: ws), var parts = URLComponents(url: socket, resolvingAgainstBaseURL: false) else {
            throw SessionError.server("Cloud has no public address yet.")
        }
        parts.scheme = parts.scheme?.lowercased() == "wss" ? "https" : "http"
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
        return enrollURL(from: raw)
    }

    private static func bundledEnroll() -> URL? {
        guard let url = Bundle.main.url(forResource: "cloud", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["enroll"] as? String else { return nil }
        return enrollURL(from: raw)
    }
}
