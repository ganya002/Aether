import Foundation
import Testing
@testable import AetherKit

@Test func clearGlassStaysClearWhenTheWindowIsIdle() {
    #expect(GlassFocus.keepsClearWhenInactive(.clear))
    #expect(!GlassFocus.keepsClearWhenInactive(.regular))
    #expect(!GlassFocus.windowFrostsWhenInactive(.clear))
    #expect(GlassFocus.windowFrostsWhenInactive(.regular))
}

@Test func clearGlassDoesNotBlurUnfocusedPanes() {
    #expect(GlassFocus.paneBlurRadius(focused: false, glass: .clear, rest: .blur, amount: 0.8) == 0)
    #expect(!GlassFocus.blursUnfocusedPane(glass: .clear, rest: .blur))
}

@Test func regularGlassBlursUnfocusedPanesWhenAsked() {
    let radius = GlassFocus.paneBlurRadius(focused: false, glass: .regular, rest: .blur, amount: 0.5)
    #expect(radius > 16)
    #expect(GlassFocus.paneBlurRadius(focused: true, glass: .regular, rest: .blur, amount: 0.5) == 0)
    #expect(GlassFocus.paneBlurRadius(focused: false, glass: .regular, rest: .dim, amount: 0.5) == 0)
    #expect(GlassFocus.blursUnfocusedPane(glass: .regular, rest: .blur))
}

@Test func frostFadesInsteadOfSnapping() {
    #expect(GlassFocus.blurDuration >= 0.2)
    #expect(GlassFocus.blurDuration <= 0.3)
}
