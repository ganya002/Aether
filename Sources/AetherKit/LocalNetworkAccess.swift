import Foundation
import Network
import SystemConfiguration

/// macOS 15+ (and 27 in particular) withholds the IPv4 ARP cache from processes
/// whose responsible code is an app that has not been granted Local Network
/// access. `arp -a` is a sysctl: it exits 0 with no output and never shows the
/// permission alert. Interface MAC addresses are painted `02:00:00:00:00:00`
/// for the same reason.
///
/// Aether must perform a real local-network operation and keep it alive so
/// the system can prompt, remember the answer, and let shells see the LAN.
@MainActor
enum LocalNetworkAccess {
    /// Privacy placeholder macOS writes when Local Network is denied or still undecided.
    nonisolated static let redactedEthernetAddress = "02:00:00:00:00:00"

    private static var browser: NWBrowser?
    private static var connection: NWConnection?

    static func start() {
        guard browser == nil else { return }

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: "local."), using: params)
        browser.stateUpdateHandler = { _ in }
        browser.start(queue: .main)
        self.browser = browser

        if let router = defaultRouter() {
            let connection = NWConnection(host: NWEndpoint.Host(router), port: 80, using: .tcp)
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: .main)
            self.connection = connection
        }
    }

    nonisolated static func defaultRouter() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Aether" as CFString, nil, nil) else {
            return nil
        }
        let info = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return info?["Router"] as? String
    }

    nonisolated static func isRedactedEthernetAddress(_ value: String) -> Bool {
        value == redactedEthernetAddress
    }
}
