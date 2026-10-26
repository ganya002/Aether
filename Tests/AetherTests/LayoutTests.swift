import CoreGraphics
import Foundation
import Testing
@testable import AetherKit

private func close(_ value: Double, _ expected: Double) -> Bool {
    abs(value - expected) < 0.000_1
}

@Test func fatKeepsThePrimaryPaneAcrossTheTop() {
    let tree = Layout.arrange(["a", "b", "c"], pattern: .fat)!
    let rects = Layout.layoutRects(tree)
    #expect(close(rects["a"]!.h, 0.58))
    #expect(close(rects["a"]!.w, 1))
    #expect(rects["b"]!.y > rects["a"]!.y)
    #expect(close(rects["b"]!.y, rects["c"]!.y))
    #expect(rects["b"]!.x < rects["c"]!.x)
}

@Test func layoutCycleWraps() {
    #expect(LayoutKind.tall.stepped(1) == .fat)
    #expect(LayoutKind.stack.stepped(1) == .tall)
    #expect(LayoutKind.tall.stepped(-1) == .stack)
    #expect(LayoutKind.splits.stepped(1) == .tall)
    #expect(LayoutKind.splits.stepped(-1) == .stack)
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

@Test func equalizeWeighsPanesAlongTheSplitAxis() {
    // Tall: one main pane beside a stack. Two columns, so each gets half.
    let tree = Layout.arrange(["a", "b", "c"], pattern: .main)!
    let even = Layout.equalize(tree)
    #expect(close(Layout.layoutRects(even)["a"]!.w, 0.5))
    #expect(close(Layout.layoutRects(even)["b"]!.h, 0.5))
    // Three side-by-side columns still split in thirds.
    let columns = Layout.equalize(Layout.arrange(["a", "b", "c"], pattern: .columns)!)
    for id in ["a", "b", "c"] {
        #expect(close(Layout.layoutRects(columns)[id]!.w, 1.0 / 3.0))
    }
    // a | (b over (c | d)): three columns across the bottom right, so a gets a third.
    let nested = LayoutNode.split(id: "r", axis: .row, ratio: 0.7, a: .pane("a"), b: .split(
        id: "c", axis: .col, ratio: 0.2, a: .pane("b"),
        b: .split(id: "r2", axis: .row, ratio: 0.9, a: .pane("c"), b: .pane("d"))
    ))
    let rects = Layout.layoutRects(Layout.equalize(nested))
    #expect(close(rects["a"]!.w, 1.0 / 3.0))
    #expect(close(rects["b"]!.h, 0.5))
    #expect(close(rects["c"]!.w, 1.0 / 3.0))
}

@Test func placeNeverProducesEmptyFrames() {
    var tree = LayoutNode.pane("p0")
    var focused = "p0"
    for i in 1..<24 {
        let id = "p\(i)"
        tree = Layout.insert(tree, target: focused, zone: i % 2 == 0 ? .right : .bottom, newID: id)
        focused = id
    }
    for (area, gap) in [(CGRect(x: 8, y: 8, width: 404, height: 264), CGFloat(40)), (CGRect(x: 0, y: 0, width: 3, height: 2), 12), (CGRect(x: 0, y: 0, width: 0, height: 0), 8)] {
        let placed = Layout.place(tree, in: area, gap: gap)
        #expect(placed.panes.count == 24)
        for pane in placed.panes {
            #expect(!pane.frame.isNull)
            #expect(!pane.frame.isInfinite)
            #expect(pane.frame.width > 0)
            #expect(pane.frame.height > 0)
            #expect(pane.frame.minX.isFinite && pane.frame.minY.isFinite)
        }
    }
}

@Test func splitIsRefusedWhenThePaneIsTooSmall() {
    let area = CGRect(x: 0, y: 0, width: 150, height: 400)
    let right = Layout.insert(.pane("a"), target: "a", zone: .right, newID: "b")
    #expect(!Layout.fits(right, in: area, gap: 8, ids: ["a", "b"]))
    let down = Layout.insert(.pane("a"), target: "a", zone: .bottom, newID: "b")
    #expect(Layout.fits(down, in: area, gap: 8, ids: ["a", "b"]))
}

@Test func splitRefusalOnlyLooksAtTheSplitPane() {
    // A cramped sibling does not block splitting a roomy pane.
    let tree = LayoutNode.split(id: "s", axis: .row, ratio: 0.1, a: .pane("tiny"), b: .pane("big"))
    let area = CGRect(x: 0, y: 0, width: 800, height: 500)
    let next = Layout.insert(tree, target: "big", zone: .right, newID: "new")
    #expect(Layout.fits(next, in: area, gap: 8, ids: ["big", "new"]))
    #expect(!Layout.fits(next, in: area, gap: 8))
}

@Test func manyColumnsDoNotJumpWhenNudged() {
    let ids = (0..<14).map { "p\($0)" }
    let tree = Layout.arrange(ids, pattern: .columns)!
    guard case .split(let id, _, let ratio, _, _) = tree else {
        Issue.record("expected a split")
        return
    }
    #expect(ratio < Layout.minRatio)
    let nudged = Layout.setRatio(tree, splitID: id, ratio: ratio + 0.001)
    #expect(close(Layout.ratio(of: id, in: nudged)!, ratio + 0.001))
    let shrunk = Layout.setRatio(tree, splitID: id, ratio: ratio - 0.04)
    #expect(close(Layout.ratio(of: id, in: shrunk)!, ratio))
}

@Test func dragBoundsFollowPoints() {
    let wide = Layout.dragBounds(span: 2000, current: 0.5)
    #expect(close(wide.lowerBound, 0.02))
    #expect(close(wide.upperBound, 0.98))
    let narrow = Layout.dragBounds(span: 200, current: 0.5)
    #expect(close(narrow.lowerBound, Layout.minRatio))
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

@Test func neighborReturnsToThePaneYouCameFrom() {
    let tree = Layout.arrange(["a", "b", "c", "d"], pattern: .main)!
    let rects = Layout.layoutRects(tree)
    #expect(Layout.neighbor(rects, id: "a", direction: .right) == "b")
    #expect(Layout.neighbor(rects, id: "c", direction: .left) == "a")
    #expect(Layout.neighbor(rects, id: "a", direction: .right, history: ["b", "c"]) == "c")
    #expect(Layout.neighbor(rects, id: "a", direction: .right, history: ["c", "d"]) == "d")
}

@Test func neighborNeedsASharedEdge() {
    // a sits top-left; c is diagonally below-right and closer by center than b.
    let rects = [
        "a": NormRect(x: 0, y: 0, w: 0.5, h: 0.5),
        "b": NormRect(x: 0.5, y: 0, w: 0.5, h: 0.2),
        "c": NormRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5),
        "x": NormRect(x: 0.5, y: 0.2, w: 0.5, h: 0.3),
    ]
    let right = Layout.neighbor(rects, id: "a", direction: .right)
    #expect(right == "x" || right == "b")
    #expect(right != "c")
}

@Test func closingFocusesTheNearestNeighbor() {
    let tree = Layout.arrange(["a", "b", "c", "d"], pattern: .grid)!
    let rects = Layout.layoutRects(tree)
    let next = Layout.successor(rects, of: "d")
    #expect(next == "b" || next == "c")
    #expect(Layout.successor(rects, of: "d", history: ["c"]) == "c")
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

@Test func windowSnapLetsAWindowSpanMonitors() {
    let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let right = CGRect(x: 1000, y: 0, width: 1200, height: 900)
    let frame = CGRect(x: 700, y: 200, width: 600, height: 400)
    #expect(Layout.snapFrame(frame, others: [], screens: [left, right], threshold: 12) == frame)
    // Partly off the bottom of one screen is fine too.
    let low = CGRect(x: 300, y: -200, width: 400, height: 400)
    #expect(Layout.snapFrame(low, others: [], screens: [left], threshold: 12) == low)
}

@Test func windowSnapUsesEveryScreenEdge() {
    let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let right = CGRect(x: 1000, y: 0, width: 1200, height: 900)
    let frame = CGRect(x: 1006, y: 300, width: 400, height: 300)
    #expect(Layout.snapFrame(frame, others: [], screens: [left, right], threshold: 12).minX == 1000)
}

@Test func windowSnapRescuesAnUnreachableTitleBar() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let above = CGRect(x: 200, y: 790, width: 400, height: 300)
    let fixed = Layout.snapFrame(above, others: [], screens: [screen], threshold: 12)
    #expect(Layout.titleBarReachable(fixed, screens: [screen]))
    #expect(fixed.maxY <= screen.maxY)
    let gone = CGRect(x: -900, y: 200, width: 400, height: 300)
    #expect(Layout.titleBarReachable(Layout.snapFrame(gone, others: [], screens: [screen], threshold: 12), screens: [screen]))
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
