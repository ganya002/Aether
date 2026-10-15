import CoreGraphics
import Foundation
import Testing
@testable import AetherKit

private func close(_ value: Double, _ expected: Double) -> Bool {
    abs(value - expected) < 0.000_1
}

@Test func columnsHaveEqualWidth() {
    let tree = Layout.arrange(["a", "b", "c"], pattern: .columns)
    let rects = Layout.layoutRects(tree)
    for id in ["a", "b", "c"] {
        #expect(close(rects[id]!.w, 1.0 / 3.0))
    }
    #expect(close(rects["a"]!.x, 0))
    #expect(close(rects["b"]!.x, 1.0 / 3.0))
    #expect(close(rects["c"]!.x, 2.0 / 3.0))
}

@Test func mainStackKeepsThePrimaryPaneWide() {
    let tree = Layout.arrange(["a", "b", "c"], pattern: .main)!
    let rects = Layout.layoutRects(tree)
    #expect(close(rects["a"]!.w, 0.56))
    #expect(close(rects["b"]!.x, 0.56))
    #expect(close(rects["c"]!.x, 0.56))
    #expect(rects["b"]!.y < rects["c"]!.y)
    #expect(close(rects["b"]!.h, 0.5))
}

@Test func gridIsRowMajor() {
    let tree = Layout.arrange(["a", "b", "c", "d"], pattern: .grid)!
    let rects = Layout.layoutRects(tree)
    #expect(close(rects["a"]!.y, 0))
    #expect(close(rects["b"]!.y, 0))
    #expect(close(rects["c"]!.y, 0.5))
    #expect(close(rects["d"]!.y, 0.5))
    #expect(rects["a"]!.x < rects["b"]!.x)
}

@Test func removingAPaneCollapsesTheSplit() {
    let tree = Layout.arrange(["a", "b", "c"], pattern: .columns)!
    let next = Layout.remove(tree, "b")
    #expect(Layout.leafIDs(next).sorted() == ["a", "c"])
    #expect(Layout.count(next) == 2)
}

@Test func removingTheLastPaneReturnsNil() {
    #expect(Layout.remove(.pane("a"), "a") == nil)
}

@Test func splitsRightAndDown() {
    let right = Layout.insert(.pane("a"), target: "a", zone: .right, newID: "b")
    let rects = Layout.layoutRects(right)
    #expect(Layout.leafIDs(right) == ["a", "b"])
    #expect(close(rects["a"]!.w, 0.5))
    let down = Layout.insert(right, target: "b", zone: .bottom, newID: "c")
    let nested = Layout.layoutRects(down)
    #expect(nested["c"]!.y > nested["b"]!.y)
    #expect(close(nested["a"]!.h, 1))
}

@Test func moveOntoAnEdgeAndSwapInTheCenter() {
    let tree = Layout.arrange(["a", "b"], pattern: .columns)!
    let moved = Layout.move(tree, source: "a", target: "b", zone: .bottom)
    let rects = Layout.layoutRects(moved)
    #expect(rects["b"]!.y < rects["a"]!.y)
    let swapped = Layout.move(tree, source: "a", target: "b", zone: .center)
    #expect(Layout.visualIDs(swapped).first == "b")
}

@Test func dropOntoItselfDoesNothing() {
    let tree = Layout.arrange(["a", "b"], pattern: .columns)!
    #expect(Layout.move(tree, source: "a", target: "a", zone: .left) == tree)
}

@Test func ratiosClamp() {
    let tree = Layout.arrange(["a", "b"], pattern: .columns)!
    guard case .split(let id, _, _, _, _) = tree else {
        Issue.record("expected a split")
        return
    }
    let next = Layout.setRatio(tree, splitID: id, ratio: 0.99)
    guard case .split(_, _, let ratio, _, _) = next else {
        Issue.record("expected a split")
        return
    }
    #expect(close(ratio, 0.92))
}

@Test func nudgeGrowsAndShrinksTheFocusedPane() {
    let tree = Layout.arrange(["a", "b"], pattern: .columns)!
    let grown = Layout.nudge(tree, pane: "a", direction: .right, delta: 0.1)
    #expect(Layout.layoutRects(grown)["a"]!.w > 0.55)
    let shrunk = Layout.nudge(grown, pane: "a", direction: .left, delta: 0.1)
    #expect(Layout.layoutRects(shrunk)["a"]!.w < Layout.layoutRects(grown)["a"]!.w)
}

@Test func equalizeUsesLeafWeight() {
    let tree = Layout.arrange(["a", "b", "c"], pattern: .main)!
    let even = Layout.equalize(tree)
    #expect(close(Layout.layoutRects(even)["a"]!.w, 1.0 / 3.0))
}

@Test func neighborPrefersTheNearestPane() {
    let rects = [
        "a": NormRect(x: 0, y: 0, w: 0.5, h: 1),
        "b": NormRect(x: 0.5, y: 0, w: 0.5, h: 0.5),
        "c": NormRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5),
    ]
    #expect(Layout.neighbor(rects, id: "a", direction: .right) == "b")
    #expect(Layout.neighbor(rects, id: "b", direction: .down) == "c")
    #expect(Layout.neighbor(rects, id: "c", direction: .left) == "a")
    #expect(Layout.neighbor(rects, id: "a", direction: .left) == nil)
}

@Test func snapRectPullsTowardNearbyEdges() {
    let snapped = Layout.snapRect(
        NormRect(x: 0.49, y: 0.1, w: 0.3, h: 0.3),
        others: [NormRect(x: 0.5, y: 0, w: 0.2, h: 0.2)],
        threshold: 0.02
    )
    #expect(close(snapped.rect.x, 0.5))
    #expect(snapped.guides.contains { $0.axis == "x" })
}

@Test func tidyRectsDoNotOverlap() {
    let rects = Layout.tidyRects(["a", "b", "c", "d"])
    let boxes = Array(rects.values)
    #expect(boxes.count == 4)
    for i in boxes.indices {
        for j in boxes.indices where j > i {
            let a = boxes[i]
            let b = boxes[j]
            let overlap = a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
            #expect(!overlap)
        }
    }
}

@Test func zoneAtClassifiesEdges() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(Layout.zoneAt(x: 10, y: 50, rect: rect) == .left)
    #expect(Layout.zoneAt(x: 90, y: 50, rect: rect) == .right)
    #expect(Layout.zoneAt(x: 50, y: 10, rect: rect) == .top)
    #expect(Layout.zoneAt(x: 50, y: 90, rect: rect) == .bottom)
    #expect(Layout.zoneAt(x: 50, y: 50, rect: rect) == .center)
}

@Test func appKitPlacementKeepsTheFirstColumnPaneOnTop() {
    let tree = Layout.arrange(["a", "b"], pattern: .rows)!
    let placed = Layout.place(tree, in: CGRect(x: 0, y: 0, width: 100, height: 100), gap: 0)
    let a = placed.panes.first { $0.id == "a" }!.frame
    let b = placed.panes.first { $0.id == "b" }!.frame
    #expect(a.minY > b.minY)
    #expect(close(Double(a.height), 50))
}

@Test func windowSnapSettlesOntoTheScreenEdge() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let frame = CGRect(x: 4, y: 100, width: 200, height: 200)
    let snapped = Layout.snapFrame(frame, others: [], screen: screen, threshold: 12)
    #expect(snapped.minX == 0)
    #expect(snapped.minY == 100)
}

@Test func randomEditsKeepEveryPane() {
    var tree = Layout.arrange(["p0", "p1", "p2", "p3"], pattern: .grid)!
    let zones: [Zone] = [.left, .right, .top, .bottom, .center]
    for i in 0..<40 {
        let leaves = Layout.leafIDs(tree)
        let source = leaves[i % leaves.count]
        let target = leaves[(i * 3) % leaves.count]
        tree = Layout.move(tree, source: source, target: target, zone: zones[i % zones.count])
        if i % 5 == 0 { tree = Layout.equalize(tree) }
        if i % 7 == 0 { tree = Layout.nudge(tree, pane: source, direction: .right) }
        let got = Layout.leafIDs(tree)
        #expect(Set(got).count == got.count)
        #expect(got.sorted() == ["p0", "p1", "p2", "p3"])
        for rect in Layout.layoutRects(tree).values {
            #expect(rect.w > 0.01)
            #expect(rect.h > 0.01)
        }
    }
}

@Test func fuzzyRanksATighterMatchFirst() {
    #expect(Fuzzy.score("xyz", "terminal") == nil)
    let ranked = Fuzzy.rank("term", ["settings", "new terminal", "tile"]) { $0 }
    #expect(ranked.first == "new terminal")
}

@Test @MainActor func paletteOffersTheTypedCommandFirst() {
    let rows = CommandPalette.rows(for: "btop")
    #expect(rows.first?.title == "Run “btop”")
    #expect(rows.dropFirst().first?.kind == .command("btop", newWindow: true))
}
