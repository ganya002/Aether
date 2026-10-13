import { beforeEach, describe, expect, it } from 'vitest'
import {
  arrange,
  contains,
  count,
  equalize,
  insertPane,
  isLayoutNode,
  layoutRects,
  leafIds,
  movePane,
  neighbor,
  nudge,
  removePane,
  setRatio,
  setSplitIdGen,
  snapRect,
  tidyRects,
  visualIds,
  zoneAt,
  type LayoutNode,
} from './layout'

beforeEach(() => {
  let n = 0
  setSplitIdGen(() => `s${++n}`)
})

function ids(node: LayoutNode | null) {
  return leafIds(node)
}

describe('arrange', () => {
  it('builds a main-and-stack like the reference layout', () => {
    const tree = arrange(['a', 'b', 'c'], 'main')
    expect(tree).not.toBeNull()
    const rects = layoutRects(tree)
    expect(rects.get('a')?.w).toBeCloseTo(0.56)
    expect(rects.get('b')?.x).toBeCloseTo(0.56)
    expect(rects.get('c')?.x).toBeCloseTo(0.56)
    expect(rects.get('b')!.y).toBeLessThan(rects.get('c')!.y)
    expect(rects.get('b')!.h).toBeCloseTo(0.5)
  })

  it('gives columns equal width', () => {
    const tree = arrange(['a', 'b', 'c'], 'columns')!
    const rects = layoutRects(tree)
    for (const id of ['a', 'b', 'c']) expect(rects.get(id)!.w).toBeCloseTo(1 / 3)
    expect(rects.get('a')!.x).toBeCloseTo(0)
    expect(rects.get('b')!.x).toBeCloseTo(1 / 3)
    expect(rects.get('c')!.x).toBeCloseTo(2 / 3)
  })

  it('builds a row-major grid', () => {
    const tree = arrange(['a', 'b', 'c', 'd'], 'grid')!
    const rects = layoutRects(tree)
    expect(rects.get('a')!.y).toBeCloseTo(0)
    expect(rects.get('b')!.y).toBeCloseTo(0)
    expect(rects.get('c')!.y).toBeCloseTo(0.5)
    expect(rects.get('d')!.y).toBeCloseTo(0.5)
    expect(rects.get('a')!.x).toBeLessThan(rects.get('b')!.x)
  })
})

describe('edits', () => {
  it('removes a pane and collapses the split', () => {
    const tree = arrange(['a', 'b', 'c'], 'columns')!
    const next = removePane(tree, 'b')
    expect(next && ids(next).sort()).toEqual(['a', 'c'])
    expect(count(next)).toBe(2)
  })

  it('returns null when the last pane closes', () => {
    expect(removePane({ type: 'pane', id: 'a' }, 'a')).toBeNull()
  })

  it('splits to the right and the bottom', () => {
    const root: LayoutNode = { type: 'pane', id: 'a' }
    const right = insertPane(root, 'a', 'right', 'b')
    expect(ids(right)).toEqual(['a', 'b'])
    const rects = layoutRects(right)
    expect(rects.get('a')!.w).toBeCloseTo(0.5)
    const down = insertPane(right, 'b', 'bottom', 'c')
    const r2 = layoutRects(down)
    expect(r2.get('c')!.y).toBeGreaterThan(r2.get('b')!.y)
    expect(r2.get('a')!.h).toBeCloseTo(1)
  })

  it('moves a pane onto an edge and swaps on center', () => {
    const tree = arrange(['a', 'b'], 'columns')!
    const moved = movePane(tree, 'a', 'b', 'bottom')
    const rects = layoutRects(moved)
    expect(rects.get('b')!.y).toBeLessThan(rects.get('a')!.y)
    const swapped = movePane(arrange(['a', 'b'], 'columns')!, 'a', 'b', 'center')
    expect(visualIds(swapped)[0]).toBe('b')
  })

  it('ignores a drop onto itself', () => {
    const tree = arrange(['a', 'b'], 'columns')!
    expect(movePane(tree, 'a', 'a', 'left')).toBe(tree)
  })

  it('clamps ratios', () => {
    const tree = arrange(['a', 'b'], 'columns')!
    const splitId = tree.type === 'split' ? tree.id : ''
    const next = setRatio(tree, splitId, 0.99)
    expect(next.type === 'split' && next.ratio).toBeCloseTo(0.92)
  })

  it('nudges the parent split in the requested direction', () => {
    const tree = arrange(['a', 'b'], 'columns')!
    const grown = nudge(tree, 'a', 'right', 0.1)
    const rects = layoutRects(grown)
    expect(rects.get('a')!.w).toBeGreaterThan(0.55)
    const shrunk = nudge(grown, 'a', 'left', 0.1)
    expect(layoutRects(shrunk).get('a')!.w).toBeLessThan(layoutRects(grown).get('a')!.w)
  })

  it('equalizes by leaf weight', () => {
    const tree = arrange(['a', 'b', 'c'], 'main')!
    const even = equalize(tree)
    const rects = layoutRects(even)
    expect(rects.get('a')!.w).toBeCloseTo(1 / 3)
  })
})

describe('geometry helpers', () => {
  it('finds the nearest neighbor', () => {
    const rects = [
      { id: 'a', x: 0, y: 0, w: 0.5, h: 1 },
      { id: 'b', x: 0.5, y: 0, w: 0.5, h: 0.5 },
      { id: 'c', x: 0.5, y: 0.5, w: 0.5, h: 0.5 },
    ]
    expect(neighbor(rects, 'a', 'right')).toBe('b')
    expect(neighbor(rects, 'b', 'down')).toBe('c')
    expect(neighbor(rects, 'c', 'left')).toBe('a')
    expect(neighbor(rects, 'a', 'left')).toBeNull()
  })

  it('snaps edges to nearby panes', () => {
    const { rect, guides } = snapRect({ x: 0.49, y: 0.1, w: 0.3, h: 0.3 }, [{ x: 0.5, y: 0, w: 0.2, h: 0.2 }], 0.02)
    expect(rect.x).toBeCloseTo(0.5)
    expect(guides.some((g) => g.axis === 'x')).toBe(true)
  })

  it('packs freeform windows without overlap', () => {
    const rects = tidyRects(['a', 'b', 'c', 'd'])
    const boxes = Object.values(rects)
    expect(boxes).toHaveLength(4)
    for (let i = 0; i < boxes.length; i++) {
      for (let j = i + 1; j < boxes.length; j++) {
        const A = boxes[i]!
        const B = boxes[j]!
        const overlap = A.x < B.x + B.w && A.x + A.w > B.x && A.y < B.y + B.h && A.y + A.h > B.y
        expect(overlap).toBe(false)
      }
    }
  })

  it('classifies drop zones', () => {
    const rect = { left: 0, top: 0, width: 100, height: 100 }
    expect(zoneAt(10, 50, rect)).toBe('left')
    expect(zoneAt(90, 50, rect)).toBe('right')
    expect(zoneAt(50, 10, rect)).toBe('top')
    expect(zoneAt(50, 90, rect)).toBe('bottom')
    expect(zoneAt(50, 50, rect)).toBe('center')
  })
})

describe('invariants', () => {
  it('keeps every id exactly once across random edits', () => {
    let tree = arrange(['p0', 'p1', 'p2', 'p3'], 'grid')!
    const zones = ['left', 'right', 'top', 'bottom', 'center'] as const
    for (let i = 0; i < 40; i++) {
      const leaves = leafIds(tree)
      const source = leaves[i % leaves.length]!
      const target = leaves[(i * 3) % leaves.length]!
      tree = movePane(tree, source, target, zones[i % zones.length]!)
      if (i % 5 === 0) tree = equalize(tree)
      if (i % 7 === 0) tree = nudge(tree, source, 'right')
      const got = leafIds(tree)
      expect(new Set(got).size).toBe(got.length)
      expect(got.slice().sort()).toEqual(['p0', 'p1', 'p2', 'p3'])
      for (const rect of layoutRects(tree).values()) {
        expect(rect.w).toBeGreaterThan(0.01)
        expect(rect.h).toBeGreaterThan(0.01)
      }
      expect(contains(tree, 'p0')).toBe(true)
      expect(isLayoutNode(tree)).toBe(true)
    }
  })
})
