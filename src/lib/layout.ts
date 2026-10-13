export type Zone = 'left' | 'right' | 'top' | 'bottom' | 'center'
export type Direction = 'left' | 'right' | 'up' | 'down'
export type Pattern = 'columns' | 'rows' | 'grid' | 'main' | 'main-right'

export type PaneNode = { type: 'pane'; id: string }
export type SplitNode = {
  type: 'split'
  id: string
  dir: 'row' | 'col'
  ratio: number
  a: LayoutNode
  b: LayoutNode
}
export type LayoutNode = PaneNode | SplitNode

export type NormRect = { x: number; y: number; w: number; h: number }
export type Guide = { axis: 'x' | 'y'; pos: number }

const MIN_RATIO = 0.08
const MAX_RATIO = 0.92

let gen = () => `s_${Math.random().toString(16).slice(2, 10)}`

export function setSplitIdGen(fn: () => string) {
  gen = fn
}

export function clamp(n: number, min: number, max: number) {
  return Math.min(max, Math.max(min, n))
}

export function count(node: LayoutNode | null): number {
  if (!node) return 0
  if (node.type === 'pane') return 1
  return count(node.a) + count(node.b)
}

export function contains(node: LayoutNode | null, id: string): boolean {
  if (!node) return false
  if (node.type === 'pane') return node.id === id
  return contains(node.a, id) || contains(node.b, id)
}

export function leafIds(node: LayoutNode | null, out: string[] = []): string[] {
  if (!node) return out
  if (node.type === 'pane') {
    out.push(node.id)
    return out
  }
  leafIds(node.a, out)
  leafIds(node.b, out)
  return out
}

export function layoutRects(
  node: LayoutNode | null,
  rect: NormRect = { x: 0, y: 0, w: 1, h: 1 },
  out: Map<string, NormRect> = new Map(),
): Map<string, NormRect> {
  if (!node) return out
  if (node.type === 'pane') {
    out.set(node.id, rect)
    return out
  }
  if (node.dir === 'row') {
    const w = rect.w * node.ratio
    layoutRects(node.a, { x: rect.x, y: rect.y, w, h: rect.h }, out)
    layoutRects(node.b, { x: rect.x + w, y: rect.y, w: rect.w - w, h: rect.h }, out)
  } else {
    const h = rect.h * node.ratio
    layoutRects(node.a, { x: rect.x, y: rect.y, w: rect.w, h }, out)
    layoutRects(node.b, { x: rect.x, y: rect.y + h, w: rect.w, h: rect.h - h }, out)
  }
  return out
}

export function visualIds(node: LayoutNode | null): string[] {
  return [...layoutRects(node).entries()]
    .sort((a, b) => a[1].y - b[1].y || a[1].x - b[1].x)
    .map(([id]) => id)
}

export function removePane(node: LayoutNode, id: string): LayoutNode | null {
  if (node.type === 'pane') return node.id === id ? null : node
  const a = removePane(node.a, id)
  const b = removePane(node.b, id)
  if (a === node.a && b === node.b) return node
  if (!a) return b
  if (!b) return a
  return { ...node, a, b }
}

export function setRatio(node: LayoutNode, splitId: string, ratio: number): LayoutNode {
  if (node.type === 'pane') return node
  if (node.id === splitId) {
    const next = clamp(ratio, MIN_RATIO, MAX_RATIO)
    return next === node.ratio ? node : { ...node, ratio: next }
  }
  const a = setRatio(node.a, splitId, ratio)
  const b = setRatio(node.b, splitId, ratio)
  if (a === node.a && b === node.b) return node
  return { ...node, a, b }
}

export function swapPanes(node: LayoutNode, a: string, b: string): LayoutNode {
  if (node.type === 'pane') {
    if (node.id === a) return { type: 'pane', id: b }
    if (node.id === b) return { type: 'pane', id: a }
    return node
  }
  const left = swapPanes(node.a, a, b)
  const right = swapPanes(node.b, a, b)
  if (left === node.a && right === node.b) return node
  return { ...node, a: left, b: right }
}

function splitWith(targetId: string, newId: string, zone: Exclude<Zone, 'center'>): SplitNode {
  const t: PaneNode = { type: 'pane', id: targetId }
  const n: PaneNode = { type: 'pane', id: newId }
  const id = gen()
  if (zone === 'left') return { type: 'split', id, dir: 'row', ratio: 0.5, a: n, b: t }
  if (zone === 'right') return { type: 'split', id, dir: 'row', ratio: 0.5, a: t, b: n }
  if (zone === 'top') return { type: 'split', id, dir: 'col', ratio: 0.5, a: n, b: t }
  return { type: 'split', id, dir: 'col', ratio: 0.5, a: t, b: n }
}

function insert(
  node: LayoutNode,
  targetId: string,
  zone: Exclude<Zone, 'center'>,
  newId: string,
): LayoutNode {
  if (node.type === 'pane') {
    if (node.id !== targetId) return node
    return splitWith(node.id, newId, zone)
  }
  const a = insert(node.a, targetId, zone, newId)
  const b = insert(node.b, targetId, zone, newId)
  if (a === node.a && b === node.b) return node
  return { ...node, a, b }
}

export function insertPane(
  node: LayoutNode,
  targetId: string,
  zone: Exclude<Zone, 'center'>,
  newId: string,
): LayoutNode {
  if (!contains(node, targetId) || contains(node, newId)) return node
  return insert(node, targetId, zone, newId)
}

export function movePane(tree: LayoutNode, sourceId: string, targetId: string, zone: Zone): LayoutNode {
  if (sourceId === targetId) return tree
  if (!contains(tree, sourceId) || !contains(tree, targetId)) return tree
  if (zone === 'center') return swapPanes(tree, sourceId, targetId)
  const removed = removePane(tree, sourceId)
  if (!removed || !contains(removed, targetId)) return tree
  return insert(removed, targetId, zone, sourceId)
}

function chain(ids: string[], dir: 'row' | 'col'): LayoutNode {
  if (ids.length === 1) return { type: 'pane', id: ids[0]! }
  const rest = chain(ids.slice(1), dir)
  return {
    type: 'split',
    id: gen(),
    dir,
    ratio: 1 / ids.length,
    a: { type: 'pane', id: ids[0]! },
    b: rest,
  }
}

function chainNodes(nodes: LayoutNode[], dir: 'row' | 'col'): LayoutNode {
  if (nodes.length === 1) return nodes[0]!
  const rest = chainNodes(nodes.slice(1), dir)
  const wa = count(nodes[0]!)
  const wb = count(rest)
  return {
    type: 'split',
    id: gen(),
    dir,
    ratio: wa / (wa + wb),
    a: nodes[0]!,
    b: rest,
  }
}

function grid(ids: string[]): LayoutNode {
  const cols = Math.max(1, Math.ceil(Math.sqrt(ids.length)))
  const rows: LayoutNode[] = []
  for (let i = 0; i < ids.length; i += cols) {
    rows.push(chain(ids.slice(i, i + cols), 'row'))
  }
  return chainNodes(rows, 'col')
}

export function arrange(ids: string[], pattern: Pattern): LayoutNode | null {
  const unique = [...new Set(ids)]
  if (unique.length === 0) return null
  if (unique.length === 1) return { type: 'pane', id: unique[0]! }
  if (pattern === 'columns') return chain(unique, 'row')
  if (pattern === 'rows') return chain(unique, 'col')
  if (pattern === 'grid') return grid(unique)
  if (pattern === 'main') {
    return {
      type: 'split',
      id: gen(),
      dir: 'row',
      ratio: unique.length === 2 ? 0.58 : 0.56,
      a: { type: 'pane', id: unique[0]! },
      b: chain(unique.slice(1), 'col'),
    }
  }
  return {
    type: 'split',
    id: gen(),
    dir: 'row',
    ratio: unique.length === 2 ? 0.42 : 0.44,
    a: chain(unique.slice(1), 'col'),
    b: { type: 'pane', id: unique[0]! },
  }
}

export function equalize(node: LayoutNode): LayoutNode {
  if (node.type === 'pane') return node
  const a = equalize(node.a)
  const b = equalize(node.b)
  const ratio = count(a) / (count(a) + count(b))
  if (a === node.a && b === node.b && Math.abs(ratio - node.ratio) < 1e-6) return node
  return { ...node, a, b, ratio }
}

type Step = { id: string; side: 'a' | 'b'; dir: 'row' | 'col' }

function pathOf(node: LayoutNode, id: string, acc: Step[] = []): Step[] | null {
  if (node.type === 'pane') return node.id === id ? acc : null
  const left = pathOf(node.a, id, [...acc, { id: node.id, side: 'a', dir: node.dir }])
  if (left) return left
  return pathOf(node.b, id, [...acc, { id: node.id, side: 'b', dir: node.dir }])
}

export function nudge(node: LayoutNode, paneId: string, dir: Direction, delta = 0.04): LayoutNode {
  const path = pathOf(node, paneId)
  if (!path) return node
  const want = dir === 'left' || dir === 'right' ? 'row' : 'col'
  for (let i = path.length - 1; i >= 0; i--) {
    const step = path[i]!
    if (step.dir !== want) continue
    const grow =
      step.side === 'a' ? dir === 'right' || dir === 'down' : dir === 'left' || dir === 'up'
    const current = findSplit(node, step.id)
    if (!current) return node
    return setRatio(node, step.id, current.ratio + (grow ? delta : -delta))
  }
  return node
}

function findSplit(node: LayoutNode, id: string): SplitNode | null {
  if (node.type === 'pane') return null
  if (node.id === id) return node
  return findSplit(node.a, id) ?? findSplit(node.b, id)
}

export type RectLike = NormRect & { id: string }

export function neighbor(rects: RectLike[], id: string, dir: Direction): string | null {
  const me = rects.find((r) => r.id === id)
  if (!me) return null
  const cx = me.x + me.w / 2
  const cy = me.y + me.h / 2
  let best: string | null = null
  let bestScore = Infinity
  for (const r of rects) {
    if (r.id === id) continue
    const rx = r.x + r.w / 2
    const ry = r.y + r.h / 2
    const dx = rx - cx
    const dy = ry - cy
    if (dir === 'left' && dx >= -0.001) continue
    if (dir === 'right' && dx <= 0.001) continue
    if (dir === 'up' && dy >= -0.001) continue
    if (dir === 'down' && dy <= 0.001) continue
    const primary = dir === 'left' || dir === 'right' ? Math.abs(dx) : Math.abs(dy)
    const ortho = dir === 'left' || dir === 'right' ? Math.abs(dy) : Math.abs(dx)
    const score = primary + ortho * 2.2
    if (score < bestScore) {
      bestScore = score
      best = r.id
    }
  }
  return best
}

export function snapRect(
  rect: NormRect,
  others: NormRect[],
  threshold = 0.015,
): { rect: NormRect; guides: Guide[] } {
  const guides: Guide[] = []
  const xs = [0, 0.5, 1]
  const ys = [0, 0.5, 1]
  for (const o of others) {
    xs.push(o.x, o.x + o.w, o.x + o.w / 2)
    ys.push(o.y, o.y + o.h, o.y + o.h / 2)
  }
  const x = snapAxis(rect.x, rect.w, xs, threshold, guides, 'x')
  const y = snapAxis(rect.y, rect.h, ys, threshold, guides, 'y')
  const w = rect.w
  const h = rect.h
  return {
    rect: {
      x: clamp(x, 0, Math.max(0, 1 - w)),
      y: clamp(y, 0, Math.max(0, 1 - h)),
      w,
      h,
    },
    guides,
  }
}

function snapAxis(
  pos: number,
  size: number,
  lines: number[],
  threshold: number,
  guides: Guide[],
  axis: 'x' | 'y',
) {
  const points = [
    { at: pos, set: (v: number) => v },
    { at: pos + size, set: (v: number) => v - size },
    { at: pos + size / 2, set: (v: number) => v - size / 2 },
  ]
  let best: { delta: number; next: number; line: number } | null = null
  for (const p of points) {
    for (const line of lines) {
      const delta = Math.abs(p.at - line)
      if (delta <= threshold && (!best || delta < best.delta)) {
        best = { delta, next: p.set(line), line }
      }
    }
  }
  if (!best) return pos
  guides.push({ axis, pos: best.line })
  return best.next
}

export function tidyRects(ids: string[], gap = 0.012): Record<string, NormRect> {
  const unique = [...new Set(ids)]
  const n = unique.length
  if (n === 0) return {}
  const cols = Math.ceil(Math.sqrt(n))
  const rows = Math.ceil(n / cols)
  const cw = (1 - gap * (cols + 1)) / cols
  const rh = (1 - gap * (rows + 1)) / rows
  const out: Record<string, NormRect> = {}
  unique.forEach((id, i) => {
    const c = i % cols
    const r = Math.floor(i / cols)
    out[id] = {
      x: gap + c * (cw + gap),
      y: gap + r * (rh + gap),
      w: cw,
      h: rh,
    }
  })
  return out
}

export function zoneAt(px: number, py: number, rect: { left: number; top: number; width: number; height: number }): Zone {
  const x = rect.width === 0 ? 0.5 : (px - rect.left) / rect.width
  const y = rect.height === 0 ? 0.5 : (py - rect.top) / rect.height
  const edge = 0.28
  const dl = x
  const dr = 1 - x
  const dt = y
  const db = 1 - y
  const min = Math.min(dl, dr, dt, db)
  if (min > edge) return 'center'
  if (min === dl) return 'left'
  if (min === dr) return 'right'
  if (min === dt) return 'top'
  return 'bottom'
}

export function isLayoutNode(value: unknown): value is LayoutNode {
  if (!value || typeof value !== 'object') return false
  const node = value as LayoutNode
  if (node.type === 'pane') return typeof node.id === 'string'
  if (node.type !== 'split') return false
  return (
    typeof node.id === 'string' &&
    (node.dir === 'row' || node.dir === 'col') &&
    typeof node.ratio === 'number' &&
    Number.isFinite(node.ratio) &&
    isLayoutNode(node.a) &&
    isLayoutNode(node.b)
  )
}
