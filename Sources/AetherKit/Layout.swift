import CoreGraphics
import Foundation

public enum Axis: String, Codable, Equatable, Sendable {
    /// Side by side. `a` is on the left.
    case row
    /// Stacked. `a` is on top.
    case col
}

public enum Zone: String, Equatable, Sendable {
    case left, right, top, bottom, center
}

public enum Direction: String, Equatable, Sendable {
    case left, right, up, down
}

public enum Pattern: String, Equatable, Sendable {
    case columns, rows, grid, main, mainRight, fat
}

/// How a desk arranges the panes it already has. `splits` keeps a hand-built tree.
public enum LayoutKind: String, Codable, Equatable, Sendable {
    case tall, fat, grid, columns, rows, stack, splits

    public static let cycle: [LayoutKind] = [.tall, .fat, .grid, .columns, .rows, .stack]

    public var title: String {
        switch self {
        case .tall: "Tall"
        case .fat: "Fat"
        case .grid: "Grid"
        case .columns: "Columns"
        case .rows: "Rows"
        case .stack: "Stack"
        case .splits: "Splits"
        }
    }

    public var pattern: Pattern? {
        switch self {
        case .tall: .main
        case .fat: .fat
        case .grid: .grid
        case .columns: .columns
        case .rows: .rows
        case .stack, .splits: nil
        }
    }

    public init?(pattern: Pattern) {
        switch pattern {
        case .columns: self = .columns
        case .rows: self = .rows
        case .grid: self = .grid
        case .main: self = .tall
        case .fat: self = .fat
        case .mainRight: return nil
        }
    }

    /// Steps around the kitty-style ring. `splits` enters the ring at Tall, or at Stack when moving backward.
    public func stepped(_ delta: Int) -> LayoutKind {
        let ring = Self.cycle
        guard let index = ring.firstIndex(of: self) else {
            return delta >= 0 ? ring[0] : ring[ring.count - 1]
        }
        let count = ring.count
        let next = (index + delta % count + count) % count
        return ring[next]
    }
}

public enum LayoutNode: Equatable, Codable, Sendable {
    case pane(String)
    indirect case split(id: String, axis: Axis, ratio: Double, a: LayoutNode, b: LayoutNode)

    public var panes: [String] {
        switch self {
        case .pane(let id):
            return [id]
        case .split(_, _, _, let a, let b):
            return a.panes + b.panes
        }
    }
}

public struct NormRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct Guide: Equatable, Sendable {
    public var axis: String
    public var pos: Double

    public init(axis: String, pos: Double) {
        self.axis = axis
        self.pos = pos
    }
}

public struct PlacedPane: Equatable, Sendable {
    public var id: String
    public var frame: CGRect

    public init(id: String, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

public struct PlacedDivider: Equatable, Sendable {
    public var splitID: String
    public var axis: Axis
    public var frame: CGRect
    /// Width of a row split, or height of a column split, in the same space as `frame`.
    public var span: CGFloat

    public init(splitID: String, axis: Axis, frame: CGRect, span: CGFloat) {
        self.splitID = splitID
        self.axis = axis
        self.frame = frame
        self.span = span
    }
}

public enum Layout {
    public static func makeID() -> String {
        "s_" + String(UUID().uuidString.prefix(8))
    }

    public static let minRatio = 0.08
    public static let maxRatio = 0.92
    /// Smallest pane a split or a new pane may produce, after gaps.
    public static let minPaneSize = CGSize(width: 80, height: 60)
    /// Smallest extent a divider drag may squeeze a side to.
    public static let minDragPoints: CGFloat = 40

    public static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, value))
    }

    public static func count(_ node: LayoutNode?) -> Int {
        guard let node else { return 0 }
        switch node {
        case .pane:
            return 1
        case .split(_, _, _, let a, let b):
            return count(a) + count(b)
        }
    }

    public static func contains(_ node: LayoutNode?, _ id: String) -> Bool {
        guard let node else { return false }
        switch node {
        case .pane(let pane):
            return pane == id
        case .split(_, _, _, let a, let b):
            return contains(a, id) || contains(b, id)
        }
    }

    public static func leafIDs(_ node: LayoutNode?) -> [String] {
        node?.panes ?? []
    }

    /// Normalized rectangles in top-left space: y grows downward.
    public static func layoutRects(
        _ node: LayoutNode?,
        rect: NormRect = NormRect(x: 0, y: 0, w: 1, h: 1)
    ) -> [String: NormRect] {
        guard let node else { return [:] }
        switch node {
        case .pane(let id):
            return [id: rect]
        case .split(_, let axis, let ratio, let a, let b):
            if axis == .row {
                let width = rect.w * ratio
                var out = layoutRects(a, rect: NormRect(x: rect.x, y: rect.y, w: width, h: rect.h))
                out.merge(layoutRects(b, rect: NormRect(x: rect.x + width, y: rect.y, w: rect.w - width, h: rect.h))) { _, new in new }
                return out
            }
            let height = rect.h * ratio
            var out = layoutRects(a, rect: NormRect(x: rect.x, y: rect.y, w: rect.w, h: height))
            out.merge(layoutRects(b, rect: NormRect(x: rect.x, y: rect.y + height, w: rect.w, h: rect.h - height))) { _, new in new }
            return out
        }
    }

    public static func visualIDs(_ node: LayoutNode?) -> [String] {
        layoutRects(node)
            .sorted { lhs, rhs in
                if lhs.value.y != rhs.value.y { return lhs.value.y < rhs.value.y }
                return lhs.value.x < rhs.value.x
            }
            .map(\.key)
    }

    public static func remove(_ node: LayoutNode, _ id: String) -> LayoutNode? {
        switch node {
        case .pane(let pane):
            return pane == id ? nil : node
        case .split(let splitID, let axis, let ratio, let a, let b):
            let nextA = remove(a, id)
            let nextB = remove(b, id)
            if nextA == nil { return nextB }
            if nextB == nil { return nextA }
            guard let nextA, let nextB else { return nil }
            if nextA == a, nextB == b { return node }
            return .split(id: splitID, axis: axis, ratio: ratio, a: nextA, b: nextB)
        }
    }

    /// Without `bounds`, the ratio stays within `minRatio...maxRatio`, widened to
    /// include the current value so a split that already sits outside (13+ columns)
    /// never jumps when nudged or dragged.
    public static func setRatio(_ node: LayoutNode, splitID: String, ratio: Double, bounds: ClosedRange<Double>? = nil) -> LayoutNode {
        switch node {
        case .pane:
            return node
        case .split(let id, let axis, let current, let a, let b):
            if id == splitID {
                let lo = bounds?.lowerBound ?? min(minRatio, current)
                let hi = bounds?.upperBound ?? max(maxRatio, current)
                let next = clamp(ratio, lo, hi)
                if next == current { return node }
                return .split(id: id, axis: axis, ratio: next, a: a, b: b)
            }
            let nextA = setRatio(a, splitID: splitID, ratio: ratio, bounds: bounds)
            let nextB = setRatio(b, splitID: splitID, ratio: ratio, bounds: bounds)
            if nextA == a, nextB == b { return node }
            return .split(id: id, axis: axis, ratio: current, a: nextA, b: nextB)
        }
    }

    /// Puts panes in `wanted` order by swapping ids in place, so split ratios stay put.
    public static func ordered(_ node: LayoutNode, as wanted: [String]) -> LayoutNode {
        let have = visualIDs(node)
        guard Set(wanted) == Set(have), wanted.count == have.count else { return node }
        var node = node
        var current = have
        for (index, id) in wanted.enumerated() where current[index] != id {
            node = swap(node, current[index], id)
            current = visualIDs(node)
        }
        return node
    }

    public static func move(_ node: LayoutNode, id: String, before: String? = nil, after: String? = nil, index: Int? = nil) -> LayoutNode {
        var ids = visualIDs(node)
        guard let from = ids.firstIndex(of: id) else { return node }
        let destination: Int
        if let before, let at = ids.firstIndex(of: before) {
            destination = from < at ? at - 1 : at
        } else if let after, let at = ids.firstIndex(of: after) {
            destination = from <= at ? at : at + 1
        } else if let index {
            destination = min(max(index, 0), ids.count - 1)
        } else {
            return node
        }
        if from == destination { return node }
        ids.remove(at: from)
        ids.insert(id, at: destination)
        return ordered(node, as: ids)
    }

    public static func swap(_ node: LayoutNode, _ first: String, _ second: String) -> LayoutNode {
        switch node {
        case .pane(let id):
            if id == first { return .pane(second) }
            if id == second { return .pane(first) }
            return node
        case .split(let id, let axis, let ratio, let a, let b):
            let nextA = swap(a, first, second)
            let nextB = swap(b, first, second)
            if nextA == a, nextB == b { return node }
            return .split(id: id, axis: axis, ratio: ratio, a: nextA, b: nextB)
        }
    }

    public static func insert(_ node: LayoutNode, target: String, zone: Zone, newID: String) -> LayoutNode {
        guard zone != .center, contains(node, target), !contains(node, newID) else { return node }
        return insertUnchecked(node, target: target, zone: zone, newID: newID)
    }

    public static func move(_ node: LayoutNode, source: String, target: String, zone: Zone) -> LayoutNode {
        if source == target { return node }
        guard contains(node, source), contains(node, target) else { return node }
        if zone == .center { return swap(node, source, target) }
        guard let removed = remove(node, source), contains(removed, target) else { return node }
        return insertUnchecked(removed, target: target, zone: zone, newID: source)
    }

    public static func arrange(_ ids: [String], pattern: Pattern) -> LayoutNode? {
        var unique: [String] = []
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        guard let first = unique.first else { return nil }
        if unique.count == 1 { return .pane(first) }
        switch pattern {
        case .columns:
            return chain(unique, axis: .row)
        case .rows:
            return chain(unique, axis: .col)
        case .grid:
            return grid(unique)
        case .main:
            return .split(
                id: makeID(),
                axis: .row,
                ratio: unique.count == 2 ? 0.58 : 0.56,
                a: .pane(first),
                b: chain(Array(unique.dropFirst()), axis: .col)
            )
        case .mainRight:
            return .split(
                id: makeID(),
                axis: .row,
                ratio: unique.count == 2 ? 0.42 : 0.44,
                a: chain(Array(unique.dropFirst()), axis: .col),
                b: .pane(first)
            )
        case .fat:
            return .split(
                id: makeID(),
                axis: .col,
                ratio: unique.count == 2 ? 0.62 : 0.58,
                a: .pane(first),
                b: chain(Array(unique.dropFirst()), axis: .row)
            )
        }
    }

    /// Each side gets room in proportion to how many panes sit side by side along
    /// the split's axis, so every column (or row) ends up the same size.
    public static func equalize(_ node: LayoutNode) -> LayoutNode {
        switch node {
        case .pane:
            return node
        case .split(let id, let axis, let ratio, let a, let b):
            let nextA = equalize(a)
            let nextB = equalize(b)
            let weightA = Double(extent(nextA, along: axis))
            let weightB = Double(extent(nextB, along: axis))
            let nextRatio = weightA / (weightA + weightB)
            if nextA == a, nextB == b, abs(nextRatio - ratio) < 1e-6 { return node }
            return .split(id: id, axis: axis, ratio: nextRatio, a: nextA, b: nextB)
        }
    }

    /// How many panes line up along `axis` inside `node`.
    public static func extent(_ node: LayoutNode, along axis: Axis) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(_, let splitAxis, _, let a, let b):
            if splitAxis == axis {
                return extent(a, along: axis) + extent(b, along: axis)
            }
            return max(extent(a, along: axis), extent(b, along: axis))
        }
    }

    /// Ratio limits for a divider drag: a side may shrink to `minDragPoints`, but never
    /// past where the split already sits.
    public static func dragBounds(span: CGFloat, current: Double) -> ClosedRange<Double> {
        let base = clamp(Double(minDragPoints / max(span, 1)), 0.005, minRatio)
        return min(base, current)...max(1 - base, current)
    }

    /// True when every pane in `ids` (or every pane) gets at least `minimum` points.
    public static func fits(
        _ node: LayoutNode,
        in area: CGRect,
        gap: CGFloat,
        ids: Set<String>? = nil,
        minimum: CGSize = minPaneSize
    ) -> Bool {
        let placed = place(node, in: area, gap: gap).panes
        return placed.allSatisfy { pane in
            guard ids?.contains(pane.id) ?? true else { return true }
            return pane.frame.width >= minimum.width && pane.frame.height >= minimum.height
        }
    }

    /// The pane focus should land on when `id` goes away: its closest neighbor.
    public static func successor(_ rects: [String: NormRect], of id: String, history: [String] = []) -> String? {
        guard let me = rects[id] else { return nil }
        let candidates = [Direction.left, .up, .right, .down].compactMap { neighbor(rects, id: id, direction: $0, history: history) }
        let pool = candidates.isEmpty ? rects.keys.filter { $0 != id } : candidates
        func distance(_ other: String) -> Double {
            guard let rect = rects[other] else { return .infinity }
            return hypot((rect.x + rect.w / 2) - (me.x + me.w / 2), (rect.y + rect.h / 2) - (me.y + me.h / 2))
        }
        func recency(_ other: String) -> Int { history.lastIndex(of: other) ?? -1 }
        return pool.sorted().min { lhs, rhs in
            let ld = distance(lhs), rd = distance(rhs)
            if abs(ld - rd) > 1e-6 { return ld < rd }
            return recency(lhs) > recency(rhs)
        }
    }

    public static func ratio(of splitID: String, in node: LayoutNode) -> Double? {
        findSplit(node, splitID)
    }

    /// Moves the pane's `edge` outward by `delta` (inward when negative), at the nearest divider on that side.
    /// Returns the layout unchanged when the pane has no divider there.
    public static func resize(_ node: LayoutNode, pane: String, edge: Direction, by delta: Double) -> LayoutNode {
        let axis: Axis = (edge == .left || edge == .right) ? .row : .col
        let side: Side = (edge == .right || edge == .down) ? .a : .b
        guard let path = path(of: pane, in: node),
              let step = path.last(where: { $0.axis == axis && $0.side == side }),
              let current = findSplit(node, step.id) else { return node }
        return setRatio(node, splitID: step.id, ratio: current + (side == .a ? delta : -delta))
    }

    public static func nudge(_ node: LayoutNode, pane: String, direction: Direction, delta: Double = 0.04) -> LayoutNode {
        guard let path = path(of: pane, in: node) else { return node }
        let want: Axis = (direction == .left || direction == .right) ? .row : .col
        for step in path.reversed() where step.axis == want {
            let grow = step.side == .a
                ? (direction == .right || direction == .down)
                : (direction == .left || direction == .up)
            guard let current = findSplit(node, step.id) else { return node }
            return setRatio(node, splitID: step.id, ratio: current + (grow ? delta : -delta))
        }
        return node
    }

    /// Prefers panes that share an edge with `id` in `direction`; among equally close
    /// ones, the most recently focused (last in `history`) wins, then the top/left one.
    public static func neighbor(_ rects: [String: NormRect], id: String, direction: Direction, history: [String] = []) -> String? {
        guard let me = rects[id] else { return nil }
        let eps = 0.001
        let horizontal = direction == .left || direction == .right
        var adjacent: [(id: String, gap: Double, overlap: Double, offset: Double)] = []
        for otherID in rects.keys where otherID != id {
            let rect = rects[otherID]!
            let gap: Double
            switch direction {
            case .left: gap = me.x - (rect.x + rect.w)
            case .right: gap = rect.x - (me.x + me.w)
            case .up: gap = me.y - (rect.y + rect.h)
            case .down: gap = rect.y - (me.y + me.h)
            }
            guard gap >= -eps else { continue }
            let overlap = horizontal
                ? min(me.y + me.h, rect.y + rect.h) - max(me.y, rect.y)
                : min(me.x + me.w, rect.x + rect.w) - max(me.x, rect.x)
            guard overlap > eps else { continue }
            adjacent.append((otherID, max(gap, 0), overlap, horizontal ? rect.y : rect.x))
        }
        if let nearest = adjacent.map(\.gap).min() {
            let tied = adjacent.filter { $0.gap - nearest < eps }
            func recency(_ id: String) -> Int { history.lastIndex(of: id) ?? -1 }
            return tied.min { lhs, rhs in
                let lr = recency(lhs.id), rr = recency(rhs.id)
                if lr != rr { return lr > rr }
                if abs(lhs.overlap - rhs.overlap) > eps { return lhs.overlap > rhs.overlap }
                if abs(lhs.offset - rhs.offset) > eps { return lhs.offset < rhs.offset }
                return lhs.id < rhs.id
            }?.id
        }
        let cx = me.x + me.w / 2
        let cy = me.y + me.h / 2
        var best: String?
        var bestScore = Double.infinity
        for otherID in rects.keys.sorted() where otherID != id {
            let rect = rects[otherID]!
            let dx = (rect.x + rect.w / 2) - cx
            let dy = (rect.y + rect.h / 2) - cy
            switch direction {
            case .left where dx >= -0.001: continue
            case .right where dx <= 0.001: continue
            case .up where dy >= -0.001: continue
            case .down where dy <= 0.001: continue
            default: break
            }
            let primary = (direction == .left || direction == .right) ? abs(dx) : abs(dy)
            let ortho = (direction == .left || direction == .right) ? abs(dy) : abs(dx)
            let score = primary + ortho * 2.2
            if score < bestScore {
                bestScore = score
                best = otherID
            }
        }
        return best
    }

    public static func snapRect(_ rect: NormRect, others: [NormRect], threshold: Double = 0.015) -> (rect: NormRect, guides: [Guide]) {
        var guides: [Guide] = []
        var xs = [0.0, 0.5, 1.0]
        var ys = [0.0, 0.5, 1.0]
        for other in others {
            xs.append(contentsOf: [other.x, other.x + other.w, other.x + other.w / 2])
            ys.append(contentsOf: [other.y, other.y + other.h, other.y + other.h / 2])
        }
        let x = snapAxis(rect.x, size: rect.w, lines: xs, threshold: threshold, guides: &guides, axis: "x")
        let y = snapAxis(rect.y, size: rect.h, lines: ys, threshold: threshold, guides: &guides, axis: "y")
        return (
            NormRect(
                x: clamp(x, 0, max(0, 1 - rect.w)),
                y: clamp(y, 0, max(0, 1 - rect.h)),
                w: rect.w,
                h: rect.h
            ),
            guides
        )
    }

    public static func tidyRects(_ ids: [String], gap: Double = 0.012) -> [String: NormRect] {
        var unique: [String] = []
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        let count = unique.count
        guard count > 0 else { return [:] }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellW = (1 - gap * Double(cols + 1)) / Double(cols)
        let cellH = (1 - gap * Double(rows + 1)) / Double(rows)
        var out: [String: NormRect] = [:]
        for (index, id) in unique.enumerated() {
            let column = index % cols
            let row = index / cols
            out[id] = NormRect(
                x: gap + Double(column) * (cellW + gap),
                y: gap + Double(row) * (cellH + gap),
                w: cellW,
                h: cellH
            )
        }
        return out
    }

    public static func zoneAt(x: Double, y: Double, rect: CGRect) -> Zone {
        let rx = rect.width == 0 ? 0.5 : (x - rect.minX) / rect.width
        let ry = rect.height == 0 ? 0.5 : (y - rect.minY) / rect.height
        let edge = 0.28
        let distances = [rx, 1 - rx, ry, 1 - ry]
        guard let minDistance = distances.min(), minDistance <= edge else { return .center }
        if minDistance == rx { return .left }
        if minDistance == 1 - rx { return .right }
        if minDistance == ry { return .top }
        return .bottom
    }

    /// AppKit frames: origin is the bottom-left. `a` in a column split stays visually on top.
    public static func place(_ node: LayoutNode, in area: CGRect, gap: CGFloat) -> (panes: [PlacedPane], dividers: [PlacedDivider]) {
        var panes: [PlacedPane] = []
        var dividers: [PlacedDivider] = []
        place(node, in: area, gap: gap, panes: &panes, dividers: &dividers)
        return (panes, dividers)
    }

    /// On mouse-up, pull a window toward a screen edge or a sibling when it is already close.
    public static func snapFrame(_ frame: CGRect, others: [CGRect], screen: CGRect, threshold: CGFloat) -> CGRect {
        snapFrame(frame, others: others, screens: [screen], threshold: threshold)
    }

    /// Height of the strip at the top of a window the user grabs to move it.
    public static let titleBarHeight: CGFloat = 28

    /// Snaps to the edges of every screen and sibling. The window may span monitors or
    /// hang partly off-screen; it is only pulled back when its title bar would be out
    /// of reach on every screen.
    public static func snapFrame(_ frame: CGRect, others: [CGRect], screens: [CGRect], threshold: CGFloat) -> CGRect {
        var next = frame
        let xLines = screens.flatMap { [$0.minX, $0.maxX] } + others.flatMap { [$0.minX, $0.maxX] }
        let yLines = screens.flatMap { [$0.minY, $0.maxY] } + others.flatMap { [$0.minY, $0.maxY] }
        if let line = closest(next.minX, to: xLines, threshold: threshold) {
            next.origin.x = line
        } else if let line = closest(next.maxX, to: xLines, threshold: threshold) {
            next.origin.x = line - next.width
        }
        if let line = closest(next.minY, to: yLines, threshold: threshold) {
            next.origin.y = line
        } else if let line = closest(next.maxY, to: yLines, threshold: threshold) {
            next.origin.y = line - next.height
        }
        guard !screens.isEmpty, !titleBarReachable(next, screens: screens) else { return next }
        let home = screens.max { overlapArea($0, next) < overlapArea($1, next) || (overlapArea($0, next) == overlapArea($1, next) && centerDistance($0, next) > centerDistance($1, next)) }!
        if next.maxY > home.maxY { next.origin.y = home.maxY - next.height }
        if next.maxY - titleBarHeight < home.minY { next.origin.y = home.minY + titleBarHeight - next.height }
        let reach: CGFloat = min(80, next.width)
        if next.maxX < home.minX + reach { next.origin.x = home.minX + reach - next.width }
        if next.minX > home.maxX - reach { next.origin.x = home.maxX - reach }
        return next
    }

    /// True when at least a grabbable piece of the title bar lies on some screen.
    public static func titleBarReachable(_ frame: CGRect, screens: [CGRect]) -> Bool {
        let bar = CGRect(x: frame.minX, y: frame.maxY - titleBarHeight, width: frame.width, height: titleBarHeight)
        let need = min(40, frame.width)
        return screens.contains { screen in
            let piece = screen.intersection(bar)
            return !piece.isNull && piece.width >= need && piece.height >= titleBarHeight / 2
        }
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let piece = a.intersection(b)
        return piece.isNull ? 0 : piece.width * piece.height
    }

    private static func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private struct Step {
        var id: String
        var side: Side
        var axis: Axis
    }

    private enum Side {
        case a, b
    }

    private static func insertUnchecked(_ node: LayoutNode, target: String, zone: Zone, newID: String) -> LayoutNode {
        switch node {
        case .pane(let id):
            guard id == target else { return node }
            return splitWith(target: id, newID: newID, zone: zone)
        case .split(let id, let axis, let ratio, let a, let b):
            let nextA = insertUnchecked(a, target: target, zone: zone, newID: newID)
            let nextB = insertUnchecked(b, target: target, zone: zone, newID: newID)
            if nextA == a, nextB == b { return node }
            return .split(id: id, axis: axis, ratio: ratio, a: nextA, b: nextB)
        }
    }

    private static func splitWith(target: String, newID: String, zone: Zone) -> LayoutNode {
        let existing = LayoutNode.pane(target)
        let incoming = LayoutNode.pane(newID)
        switch zone {
        case .left:
            return .split(id: makeID(), axis: .row, ratio: 0.5, a: incoming, b: existing)
        case .right:
            return .split(id: makeID(), axis: .row, ratio: 0.5, a: existing, b: incoming)
        case .top:
            return .split(id: makeID(), axis: .col, ratio: 0.5, a: incoming, b: existing)
        case .bottom, .center:
            return .split(id: makeID(), axis: .col, ratio: 0.5, a: existing, b: incoming)
        }
    }

    private static func chain(_ ids: [String], axis: Axis) -> LayoutNode {
        if ids.count == 1 { return .pane(ids[0]) }
        let rest = chain(Array(ids.dropFirst()), axis: axis)
        return .split(id: makeID(), axis: axis, ratio: 1 / Double(ids.count), a: .pane(ids[0]), b: rest)
    }

    private static func chainNodes(_ nodes: [LayoutNode], axis: Axis) -> LayoutNode {
        if nodes.count == 1 { return nodes[0] }
        let rest = chainNodes(Array(nodes.dropFirst()), axis: axis)
        let weightA = count(nodes[0])
        let weightB = count(rest)
        return .split(
            id: makeID(),
            axis: axis,
            ratio: Double(weightA) / Double(weightA + weightB),
            a: nodes[0],
            b: rest
        )
    }

    private static func grid(_ ids: [String]) -> LayoutNode {
        let cols = max(1, Int(ceil(sqrt(Double(ids.count)))))
        var rows: [LayoutNode] = []
        var index = 0
        while index < ids.count {
            let end = min(index + cols, ids.count)
            rows.append(chain(Array(ids[index..<end]), axis: .row))
            index = end
        }
        return chainNodes(rows, axis: .col)
    }

    private static func path(of id: String, in node: LayoutNode, acc: [Step] = []) -> [Step]? {
        switch node {
        case .pane(let pane):
            return pane == id ? acc : nil
        case .split(let splitID, let axis, _, let a, let b):
            if let left = path(of: id, in: a, acc: acc + [Step(id: splitID, side: .a, axis: axis)]) {
                return left
            }
            return path(of: id, in: b, acc: acc + [Step(id: splitID, side: .b, axis: axis)])
        }
    }

    private static func findSplit(_ node: LayoutNode, _ id: String) -> Double? {
        switch node {
        case .pane:
            return nil
        case .split(let splitID, _, let ratio, let a, let b):
            if splitID == id { return ratio }
            return findSplit(a, id) ?? findSplit(b, id)
        }
    }

    private static func snapAxis(
        _ pos: Double,
        size: Double,
        lines: [Double],
        threshold: Double,
        guides: inout [Guide],
        axis: String
    ) -> Double {
        let points: [(at: Double, set: (Double) -> Double)] = [
            (pos, { $0 }),
            (pos + size, { $0 - size }),
            (pos + size / 2, { $0 - size / 2 }),
        ]
        var best: (delta: Double, next: Double, line: Double)?
        for point in points {
            for line in lines {
                let delta = abs(point.at - line)
                if delta <= threshold, best == nil || delta < best!.delta {
                    best = (delta, point.set(line), line)
                }
            }
        }
        guard let best else { return pos }
        guides.append(Guide(axis: axis, pos: best.line))
        return best.next
    }

    private static func place(
        _ node: LayoutNode,
        in area: CGRect,
        gap: CGFloat,
        panes: inout [PlacedPane],
        dividers: inout [PlacedDivider]
    ) {
        switch node {
        case .pane(let id):
            panes.append(PlacedPane(id: id, frame: inset(area, by: max(0, gap / 2))))
        case .split(let id, let axis, let ratio, let a, let b):
            let portion = CGFloat(ratio)
            let thickness = max(gap, 12)
            if axis == .row {
                let leftWidth = area.width * portion
                let left = CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
                let right = CGRect(x: area.minX + leftWidth, y: area.minY, width: area.width - leftWidth, height: area.height)
                dividers.append(PlacedDivider(
                    splitID: id,
                    axis: .row,
                    frame: CGRect(x: area.minX + leftWidth - thickness / 2, y: area.minY, width: thickness, height: area.height),
                    span: area.width
                ))
                place(a, in: left, gap: gap, panes: &panes, dividers: &dividers)
                place(b, in: right, gap: gap, panes: &panes, dividers: &dividers)
            } else {
                let topHeight = area.height * portion
                let top = CGRect(x: area.minX, y: area.maxY - topHeight, width: area.width, height: topHeight)
                let bottom = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - topHeight)
                let boundary = area.maxY - topHeight
                dividers.append(PlacedDivider(
                    splitID: id,
                    axis: .col,
                    frame: CGRect(x: area.minX, y: boundary - thickness / 2, width: area.width, height: thickness),
                    span: area.height
                ))
                place(a, in: top, gap: gap, panes: &panes, dividers: &dividers)
                place(b, in: bottom, gap: gap, panes: &panes, dividers: &dividers)
            }
        }
    }

    /// Insets without ever producing a null, empty, or negative rect: once the area is
    /// thinner than the gap, the pane keeps at least one point centered in its slot.
    public static func inset(_ area: CGRect, by amount: CGFloat) -> CGRect {
        let area = area.isNull || area.isInfinite ? .zero : area.standardized
        let dx = min(amount, max(0, (area.width - 1) / 2))
        let dy = min(amount, max(0, (area.height - 1) / 2))
        let width = max(1, area.width - 2 * dx)
        let height = max(1, area.height - 2 * dy)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private static func closest(_ value: CGFloat, to lines: [CGFloat], threshold: CGFloat) -> CGFloat? {
        var best: CGFloat?
        var bestDelta = threshold
        for line in lines {
            let delta = abs(value - line)
            if delta <= bestDelta {
                bestDelta = delta
                best = line
            }
        }
        return best
    }
}
