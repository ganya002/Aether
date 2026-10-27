import Foundation
import Testing
@testable import AetherKit

@Test func redactedMACHelperRecognizesThePrivacyPlaceholder() {
    #expect(LocalNetworkAccess.isRedactedEthernetAddress("02:00:00:00:00:00"))
    #expect(!LocalNetworkAccess.isRedactedEthernetAddress("82:54:32:e6:bb:0d"))
}

@MainActor
@Test func localNetworkProbeCanStart() {
    LocalNetworkAccess.start()
    LocalNetworkAccess.start()
}

@Test func defaultRouterLooksLikeAnAddressWhenTheMacIsOnANetwork() {
    guard let router = LocalNetworkAccess.defaultRouter() else { return }
    #expect(router.contains("."))
}
