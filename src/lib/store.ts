import { create } from 'zustand'
import type { Direction, LayoutNode, NormRect, Pattern, Zone } from './layout'
import {
  arrange,
  contains,
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
  tidyRects,
  visualIds,
} from './layout'
import { titleFromCommand } from './format'
import { uid } from './id'
import { session } from './session'
import { toast } from './ui'

export const ACCENTS = ['#8eb6ff', '#d7b4ff', '#ffb39a', '#8ee0c2', '#f0d18a', '#ff9ec4', '#9ad8ff', '#e7d7a4']

export type BackgroundSetting =
  | { kind: 'preset'; id: string }
  | { kind: 'image'; id: string }
  | { kind: 'color'; color: string }

export type Settings = {
  fontFamily: string
  fontSize: number
  lineHeight: number
  letterSpacing: number
  cursorStyle: 'bar' | 'block' | 'underline'
  cursorBlink: boolean
  scrollback: number
  themeId: string
  accent: string | null
  scrim: number
  blur: number
  gap: number
  radius: number
  pad: number
  background: BackgroundSetting
  bgBlur: number
  bgDim: number
  bgAnimate: boolean
  grain: boolean
  performance: boolean
  webgl: boolean
  bellVisual: boolean
  bellSound: boolean
  copyOnSelect: boolean
  smoothScroll: boolean
  optionIsMeta: boolean
}

export type Pane = {
  id: string
  title: string
  customTitle: boolean
  cwd: string
  command: string | null
  accent: string
  muted: boolean
  offerRerun: boolean
  bell: number
  status: 'starting' | 'running' | 'exited'
  exitCode: number | null
  exitMessage: string | null
  shell: string
  pid: number | null
}

export type Workspace = {
  id: string
  name: string
  mode: 'tile' | 'free'
  tree: LayoutNode | null
  rects: Record<string, NormRect>
  z: Record<string, number>
  shelf: string[]
  maximizedId: string | null
  focusedId: string | null
  focusMode: boolean
  locked: boolean
  broadcast: boolean
}

export type Profile = { id: string; name: string; command: string; cwd: string }
export type Upload = { id: string; url: string }

export function defaultSettings(platform = 'linux'): Settings {
  return {
    fontFamily: 'JetBrains Mono',
    fontSize: 14,
    lineHeight: 1.18,
    letterSpacing: 0,
    cursorStyle: 'bar',
    cursorBlink: true,
    scrollback: 5000,
    themeId: 'tide',
    accent: null,
    scrim: 0.46,
    blur: 18,
    gap: 10,
    radius: 16,
    pad: 14,
    background: { kind: 'preset', id: 'tidepool' },
    bgBlur: 0,
    bgDim: 0.12,
    bgAnimate: true,
    grain: true,
    performance: false,
    webgl: false,
    bellVisual: true,
    bellSound: false,
    copyOnSelect: false,
    smoothScroll: true,
    optionIsMeta: platform === 'darwin',
  }
}

const THEME_FOR_PRESET: Record<string, string> = {
  tidepool: 'tide',
  dusk: 'dusk',
  pine: 'pine',
  aurora: 'tide',
  ink: 'midnight',
  midnight: 'midnight',
  porcelain: 'porcelain',
}

function blankWorkspace(id: string, name: string): Workspace {
  return {
    id,
    name,
    mode: 'tile',
    tree: null,
    rects: {},
    z: {},
    shelf: [],
    maximizedId: null,
    focusedId: null,
    focusMode: false,
    locked: false,
    broadcast: false,
  }
}

export function visibleIds(workspace: Workspace) {
  if (workspace.mode === 'free') {
    return Object.keys(workspace.rects)
      .filter((id) => !workspace.shelf.includes(id))
      .sort((a, b) => (workspace.z[a] ?? 0) - (workspace.z[b] ?? 0) || a.localeCompare(b))
  }
  return leafIds(workspace.tree).filter((id) => !workspace.shelf.includes(id))
}

function rectsOf(workspace: Workspace): Array<NormRect & { id: string }> {
  if (workspace.mode === 'free') {
    return visibleIds(workspace).map((id) => ({ id, ...workspace.rects[id]! }))
  }
  return [...layoutRects(workspace.tree).entries()].map(([id, rect]) => ({ id, ...rect }))
}

type Snapshot = {
  version: 1
  settings: Settings
  workspaces: Workspace[]
  activeWorkspaceId: string
  panes: Pane[]
  profiles: Profile[]
  recent: string[]
  bootId: string
}

function pruneTree(node: LayoutNode, ids: Set<string>): LayoutNode | null {
  if (!isLayoutNode(node)) return null
  if (node.type === 'pane') return ids.has(node.id) ? node : null
  const a = pruneTree(node.a, ids)
  const b = pruneTree(node.b, ids)
  if (!a) return b
  if (!b) return a
  if (a === node.a && b === node.b) return node
  return { ...node, a, b }
}

function asPane(value: unknown, shell: string, home: string): Pane | null {
  if (!value || typeof value !== 'object') return null
  const pane = value as Partial<Pane>
  if (typeof pane.id !== 'string' || typeof pane.cwd !== 'string') return null
  return {
    id: pane.id,
    title: typeof pane.title === 'string' ? pane.title : 'Shell',
    customTitle: Boolean(pane.customTitle),
    cwd: pane.cwd || home,
    command: typeof pane.command === 'string' ? pane.command : null,
    accent: typeof pane.accent === 'string' ? pane.accent : ACCENTS[0]!,
    muted: Boolean(pane.muted),
    offerRerun: Boolean(pane.offerRerun),
    bell: 0,
    status: 'starting',
    exitCode: null,
    exitMessage: null,
    shell,
    pid: null,
  }
}

function asWorkspace(value: unknown, ids: Set<string>): Workspace | null {
  if (!value || typeof value !== 'object') return null
  const workspace = value as Partial<Workspace>
  if (typeof workspace.id !== 'string') return null
  const tree = workspace.tree && isLayoutNode(workspace.tree) ? pruneTree(workspace.tree, ids) : null
  const rects: Record<string, NormRect> = {}
  if (workspace.rects && typeof workspace.rects === 'object') {
    for (const [id, rect] of Object.entries(workspace.rects)) {
      if (!ids.has(id) || !rect) continue
      const box = rect as NormRect
      if ([box.x, box.y, box.w, box.h].every((n) => typeof n === 'number' && Number.isFinite(n))) rects[id] = box
    }
  }
  return {
    id: workspace.id,
    name: typeof workspace.name === 'string' ? workspace.name : 'Desk',
    mode: workspace.mode === 'free' ? 'free' : 'tile',
    tree,
    rects,
    z: workspace.z && typeof workspace.z === 'object' ? (workspace.z as Record<string, number>) : {},
    shelf: Array.isArray(workspace.shelf) ? workspace.shelf.filter((id) => ids.has(id)) : [],
    maximizedId: typeof workspace.maximizedId === 'string' && ids.has(workspace.maximizedId) ? workspace.maximizedId : null,
    focusedId: typeof workspace.focusedId === 'string' && ids.has(workspace.focusedId) ? workspace.focusedId : leafIds(tree)[0] ?? null,
    focusMode: Boolean(workspace.focusMode),
    locked: Boolean(workspace.locked),
    broadcast: Boolean(workspace.broadcast),
  }
}

type State = {
  settings: Settings
  workspaces: Workspace[]
  activeWorkspaceId: string
  panes: Record<string, Pane>
  profiles: Profile[]
  recent: string[]
  bootId: string
  home: string
  shell: string
  platform: string
  hydrated: boolean
  uploads: Upload[]
  hydrate: (saved: unknown, meta: { bootId: string; shell: string; home: string; platform: string }, uploads: Upload[]) => void
  setBootId: (bootId: string) => void
  setUploads: (uploads: Upload[]) => void
  noteRestart: () => void
  patchSettings: (patch: Partial<Settings>) => void
  chooseBackground: (background: BackgroundSetting) => void
  setMaterial: (material: 'clear' | 'frosted' | 'solid') => void
  createPane: (opts?: { command?: string | null; cwd?: string; placement?: 'right' | 'down' | 'auto' }) => string
  closePane: (id: string) => void
  focus: (id: string) => void
  focusDirection: (dir: Direction) => void
  focusIndex: (index: number) => void
  split: (placement: 'right' | 'down') => void
  duplicate: (id: string) => void
  move: (sourceId: string, targetId: string, zone: Zone) => void
  nudgeFocused: (dir: Direction) => void
  setRatio: (splitId: string, ratio: number) => void
  equalize: () => void
  arrangePattern: (pattern: Pattern) => void
  setMode: (mode: 'tile' | 'free') => void
  toggleMode: () => void
  tidy: () => void
  setRect: (id: string, rect: NormRect) => void
  minimize: (id: string) => void
  restore: (id: string) => void
  toggleMaximize: (id?: string) => void
  clearMaximize: () => void
  toggleFocusMode: () => void
  toggleLock: () => void
  toggleBroadcast: () => void
  toggleMute: (id: string) => void
  renamePane: (id: string, title: string) => void
  setAutoTitle: (id: string, title: string) => void
  markReady: (id: string, info: { pid: number; cwd: string; shell: string }) => void
  markExit: (id: string, code: number, message?: string) => void
  setCwd: (id: string, cwd: string) => void
  bumpBell: (id: string) => void
  restartShell: (id: string) => void
  rerun: (id: string) => void
  dismissRerun: (id: string) => void
  rememberCommand: (command: string) => void
  addWorkspace: () => void
  closeWorkspace: (id: string) => void
  switchWorkspace: (id: string) => void
  renameWorkspace: (id: string, name: string) => void
  moveToWorkspace: (paneId: string, workspaceId: string) => void
  cycleWorkspace: (step: number) => void
  addProfile: (profile: Omit<Profile, 'id'>) => void
  removeProfile: (id: string) => void
  active: () => Workspace
  exportDesk: () => string
  importDesk: (raw: string) => void
}

function activeOf(state: Pick<State, 'workspaces' | 'activeWorkspaceId'>) {
  return state.workspaces.find((workspace) => workspace.id === state.activeWorkspaceId) ?? state.workspaces[0]!
}

function mapActive(state: State, fn: (workspace: Workspace) => Workspace) {
  const current = activeOf(state)
  return state.workspaces.map((workspace) => (workspace.id === current.id ? fn(workspace) : workspace))
}

function patchPane(panes: Record<string, Pane>, id: string, patch: Partial<Pane>) {
  const pane = panes[id]
  if (!pane) return panes
  return { ...panes, [id]: { ...pane, ...patch } }
}

let saveTimer: ReturnType<typeof setTimeout> | null = null

function persist(state: State) {
  if (!state.hydrated) return
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    const snapshot: Snapshot = {
      version: 1,
      settings: state.settings,
      workspaces: state.workspaces,
      activeWorkspaceId: state.activeWorkspaceId,
      panes: Object.values(state.panes).map((pane) => ({ ...pane, bell: 0, status: 'starting', exitCode: null, exitMessage: null, pid: null })),
      profiles: state.profiles,
      recent: state.recent,
      bootId: state.bootId,
    }
    void fetch('/api/state', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(snapshot),
    }).catch(() => {
      /* the desk still lives in this tab */
    })
  }, 320)
}

function syncDesired(pane: Pane, shellOnly: boolean) {
  session.syncPane({
    id: pane.id,
    cwd: pane.cwd,
    cols: 80,
    rows: 24,
    command: pane.command,
    shellOnly,
  })
}

export const useStore = create<State>((set, get) => ({
  settings: defaultSettings(),
  workspaces: [blankWorkspace('w_main', 'Desk')],
  activeWorkspaceId: 'w_main',
  panes: {},
  profiles: [
    { id: 'profile_python', name: 'Python', command: 'python3', cwd: '' },
    { id: 'profile_node', name: 'Node', command: 'node', cwd: '' },
  ],
  recent: [],
  bootId: '',
  home: '',
  shell: 'bash',
  platform: 'linux',
  hydrated: false,
  uploads: [],
  active: () => activeOf(get()),
  hydrate: (saved, meta, uploads) => {
    const defaults = defaultSettings(meta.platform)
    const record = saved && typeof saved === 'object' ? (saved as Partial<Snapshot>) : null
    const restarted = Boolean(record && record.bootId !== meta.bootId)
    const loaded = (record?.panes ?? []).map((pane) => asPane(pane, meta.shell, meta.home)).filter((pane): pane is Pane => Boolean(pane))
    for (const pane of loaded) {
      if (restarted && pane.command) pane.offerRerun = true
    }
    const ids = new Set(loaded.map((pane) => pane.id))
    let workspaces = (record?.workspaces ?? []).map((workspace) => asWorkspace(workspace, ids)).filter((workspace): workspace is Workspace => Boolean(workspace))
    if (!workspaces.length) workspaces = [blankWorkspace(uid('w'), 'Desk')]
    const activeWorkspaceId = workspaces.some((workspace) => workspace.id === record?.activeWorkspaceId)
      ? record!.activeWorkspaceId!
      : workspaces[0]!.id
    const settings = { ...defaults, ...(record?.settings ?? {}) }
    if (!settings.background || typeof settings.background !== 'object') settings.background = defaults.background
    const panes = Object.fromEntries(loaded.map((pane) => [pane.id, pane]))
    set({
      settings,
      workspaces,
      activeWorkspaceId,
      panes,
      profiles: Array.isArray(record?.profiles) && record.profiles.length ? (record.profiles as Profile[]) : get().profiles,
      recent: Array.isArray(record?.recent) ? record.recent.filter((item) => typeof item === 'string').slice(0, 16) : [],
      bootId: meta.bootId,
      home: meta.home,
      shell: meta.shell,
      platform: meta.platform,
      hydrated: true,
      uploads,
    })
    for (const pane of loaded) syncDesired(pane, restarted && Boolean(pane.command))
    if (!loaded.length) get().createPane()
    persist(get())
  },
  setBootId: (bootId) => {
    set({ bootId })
    persist(get())
  },
  setUploads: (uploads) => set({ uploads }),
  noteRestart: () => {
    const panes = { ...get().panes }
    for (const pane of Object.values(panes)) {
      if (!pane.command) continue
      panes[pane.id] = { ...pane, offerRerun: true }
      session.markShellOnly(pane.id)
    }
    set({ panes })
    persist(get())
  },
  patchSettings: (patch) => {
    set((state) => ({ settings: { ...state.settings, ...patch } }))
    persist(get())
  },
  chooseBackground: (background) => {
    set((state) => {
      const themeId = background.kind === 'preset' ? THEME_FOR_PRESET[background.id] ?? state.settings.themeId : state.settings.themeId
      return { settings: { ...state.settings, background, themeId, accent: null } }
    })
    persist(get())
  },
  setMaterial: (material) => {
    const preset = material === 'clear' ? { scrim: 0.32, blur: 28 } : material === 'solid' ? { scrim: 0.94, blur: 0 } : { scrim: 0.46, blur: 18 }
    get().patchSettings(preset)
  },
  createPane: (opts) => {
    const state = get()
    const workspace = activeOf(state)
    const id = uid('p')
    const focused = workspace.focusedId ? state.panes[workspace.focusedId] : undefined
    const cwd = opts?.cwd || focused?.cwd || state.home || '/'
    const command = opts?.command ?? null
    const pane: Pane = {
      id,
      title: command ? titleFromCommand(command) : 'Shell',
      customTitle: false,
      cwd,
      command,
      accent: ACCENTS[Object.keys(state.panes).length % ACCENTS.length]!,
      muted: false,
      offerRerun: false,
      bell: 0,
      status: 'starting',
      exitCode: null,
      exitMessage: null,
      shell: state.shell,
      pid: null,
    }
    let tree = workspace.tree
    const rects = { ...workspace.rects }
    const z = { ...workspace.z }
    if (workspace.mode === 'free') {
      const index = Object.keys(rects).length
      rects[id] = {
        x: Math.min(0.42, 0.05 + (index % 6) * 0.03),
        y: Math.min(0.36, 0.05 + (index % 6) * 0.03),
        w: 0.5,
        h: 0.56,
      }
      z[id] = Math.max(1, ...Object.values(z), 0) + 1
    } else if (!tree) {
      tree = { type: 'pane', id }
    } else {
      const leaves = leafIds(tree)
      const target = workspace.focusedId && leaves.includes(workspace.focusedId) ? workspace.focusedId : leaves.at(-1)!
      let zone: 'right' | 'bottom' = 'right'
      if (opts?.placement === 'down') zone = 'bottom'
      else if (opts?.placement !== 'right') {
        const rect = layoutRects(tree).get(target)
        if (rect && rect.h > rect.w * 1.2) zone = 'bottom'
      }
      tree = insertPane(tree, target, zone, id)
    }
    const countPanes = Object.keys(state.panes).length + 1
    set({
      panes: { ...state.panes, [id]: pane },
      workspaces: mapActive(state, (item) => ({
        ...item,
        tree,
        rects,
        z,
        focusedId: id,
        maximizedId: null,
        shelf: item.shelf.filter((shelfId) => shelfId !== id),
      })),
    })
    syncDesired(pane, false)
    if (command) get().rememberCommand(command)
    if (countPanes === 16) toast('Sixteen shells. Low power is in the Look panel if the machine starts to warm up.')
    persist(get())
    return id
  },
  closePane: (id) => {
    const state = get()
    const workspace = state.workspaces.find((item) => visibleIds(item).includes(id) || item.shelf.includes(id) || item.rects[id] || (item.tree && contains(item.tree, id)))
    let nextFocus: string | null = null
    if (workspace?.tree && contains(workspace.tree, id) && workspace.focusedId === id) {
      nextFocus = neighbor(rectsOf(workspace), id, 'right') || neighbor(rectsOf(workspace), id, 'left') || neighbor(rectsOf(workspace), id, 'down') || neighbor(rectsOf(workspace), id, 'up')
    }
    const panes = { ...state.panes }
    delete panes[id]
    set({
      panes,
      workspaces: state.workspaces.map((item) => {
        const tree = item.tree && contains(item.tree, id) ? removePane(item.tree, id) : item.tree
        const rects = { ...item.rects }
        delete rects[id]
        const shelf = item.shelf.filter((shelfId) => shelfId !== id)
        const z = { ...item.z }
        delete z[id]
        const focusedId = item.focusedId === id ? nextFocus && panes[nextFocus] ? nextFocus : leafIds(tree)[0] ?? shelf[0] ?? null : item.focusedId
        return {
          ...item,
          tree,
          rects,
          shelf,
          z,
          focusedId,
          maximizedId: item.maximizedId === id ? null : item.maximizedId,
        }
      }),
    })
    session.forgetPane(id)
    persist(get())
  },
  focus: (id) => {
    set((state) => ({
      panes: patchPane(state.panes, id, { bell: 0 }),
      workspaces: mapActive(state, (workspace) => {
        const z = { ...workspace.z }
        if (workspace.mode === 'free') z[id] = Math.max(1, ...Object.values(z), 0) + 1
        return { ...workspace, focusedId: id, z }
      }),
    }))
  },
  focusDirection: (dir) => {
    const workspace = activeOf(get())
    if (!workspace.focusedId) return
    const next = neighbor(rectsOf(workspace), workspace.focusedId, dir)
    if (next) get().focus(next)
  },
  focusIndex: (index) => {
    const id = visibleIds(activeOf(get()))[index]
    if (id) get().focus(id)
  },
  split: (placement) => {
    const workspace = activeOf(get())
    const cwd = workspace.focusedId ? get().panes[workspace.focusedId]?.cwd : undefined
    get().createPane({ cwd, placement })
  },
  duplicate: (id) => {
    const pane = get().panes[id]
    if (!pane) return
    get().createPane({ cwd: pane.cwd, placement: 'right' })
  },
  move: (sourceId, targetId, zone) => {
    set((state) => ({
      workspaces: mapActive(state, (workspace) => {
        if (!workspace.tree || workspace.locked) return workspace
        return { ...workspace, tree: movePane(workspace.tree, sourceId, targetId, zone), focusedId: sourceId }
      }),
    }))
    persist(get())
  },
  nudgeFocused: (dir) => {
    const workspace = activeOf(get())
    if (!workspace.focusedId || workspace.locked) return
    if (workspace.mode === 'free') {
      const rect = workspace.rects[workspace.focusedId]
      if (!rect) return
      const delta = 0.03
      const next = { ...rect }
      if (dir === 'left') next.w = Math.max(0.16, next.w - delta)
      if (dir === 'right') next.w = Math.min(1 - next.x, next.w + delta)
      if (dir === 'up') next.h = Math.max(0.14, next.h - delta)
      if (dir === 'down') next.h = Math.min(1 - next.y, next.h + delta)
      get().setRect(workspace.focusedId, next)
      return
    }
    if (!workspace.tree) return
    set({
      workspaces: mapActive(get(), (item) => ({
        ...item,
        tree: item.tree ? nudge(item.tree, workspace.focusedId!, dir) : item.tree,
      })),
    })
    persist(get())
  },
  setRatio: (splitId, ratio) => {
    set((state) => ({
      workspaces: mapActive(state, (workspace) => ({
        ...workspace,
        tree: workspace.tree ? setRatio(workspace.tree, splitId, ratio) : workspace.tree,
      })),
    }))
    persist(get())
  },
  equalize: () => {
    set((state) => ({
      workspaces: mapActive(state, (workspace) => ({
        ...workspace,
        tree: workspace.tree ? equalize(workspace.tree) : workspace.tree,
      })),
    }))
    persist(get())
  },
  arrangePattern: (pattern) => {
    const workspace = activeOf(get())
    const ids = visualIds(workspace.tree)
    if (ids.length < 2) {
      toast('Open another terminal, then arrange.')
      return
    }
    set({
      workspaces: mapActive(get(), (item) => ({ ...item, tree: arrange(ids, pattern), mode: 'tile' })),
    })
    persist(get())
  },
  setMode: (mode) => {
    set((state) => ({
      workspaces: mapActive(state, (workspace) => {
        if (workspace.mode === mode) return workspace
        if (mode === 'free') {
          const rects: Record<string, NormRect> = {}
          for (const [id, rect] of layoutRects(workspace.tree)) rects[id] = rect
          return { ...workspace, mode, rects }
        }
        const ids = Object.entries(workspace.rects)
          .filter(([id]) => !workspace.shelf.includes(id))
          .sort((a, b) => a[1].y - b[1].y || a[1].x - b[1].x)
          .map(([id]) => id)
        return { ...workspace, mode, tree: arrange(ids.length ? ids : leafIds(workspace.tree), 'grid') }
      }),
    }))
    persist(get())
  },
  toggleMode: () => {
    const workspace = activeOf(get())
    get().setMode(workspace.mode === 'tile' ? 'free' : 'tile')
  },
  tidy: () => {
    set((state) => ({
      workspaces: mapActive(state, (workspace) => ({
        ...workspace,
        rects: { ...workspace.rects, ...tidyRects(visibleIds(workspace)) },
      })),
    }))
    persist(get())
  },
  setRect: (id, rect) => {
    set((state) => ({
      workspaces: mapActive(state, (workspace) => ({
        ...workspace,
        rects: { ...workspace.rects, [id]: rect },
      })),
    }))
    persist(get())
  },
  minimize: (id) => {
    set((state) => ({
      workspaces: mapActive(state, (workspace) => {
        const tree = workspace.tree && contains(workspace.tree, id) ? removePane(workspace.tree, id) : workspace.tree
        const shelf = workspace.shelf.includes(id) ? workspace.shelf : [...workspace.shelf, id]
        const focusedId = workspace.focusedId === id ? leafIds(tree)[0] ?? null : workspace.focusedId
        return { ...workspace, tree, shelf, focusedId, maximizedId: workspace.maximizedId === id ? null : workspace.maximizedId }
      }),
    }))
    persist(get())
  },
  restore: (id) => {
    const state = get()
    const workspace = activeOf(state)
    if (workspace.mode === 'free') {
      const rects = { ...workspace.rects }
      if (!rects[id]) rects[id] = { x: 0.08, y: 0.08, w: 0.46, h: 0.5 }
      set({
        workspaces: mapActive(state, (item) => ({
          ...item,
          rects,
          shelf: item.shelf.filter((shelfId) => shelfId !== id),
          focusedId: id,
        })),
      })
    } else if (!workspace.tree) {
      set({
        workspaces: mapActive(state, (item) => ({
          ...item,
          tree: { type: 'pane', id },
          shelf: item.shelf.filter((shelfId) => shelfId !== id),
          focusedId: id,
        })),
      })
    } else {
      const target = workspace.focusedId && contains(workspace.tree, workspace.focusedId) ? workspace.focusedId : leafIds(workspace.tree)[0]!
      set({
        workspaces: mapActive(state, (item) => ({
          ...item,
          tree: insertPane(item.tree!, target, 'right', id),
          shelf: item.shelf.filter((shelfId) => shelfId !== id),
          focusedId: id,
        })),
      })
    }
    persist(get())
  },
  toggleMaximize: (id) => {
    const workspace = activeOf(get())
    const target = id ?? workspace.focusedId
    if (!target) return
    set({
      workspaces: mapActive(get(), (item) => ({
        ...item,
        maximizedId: item.maximizedId === target ? null : target,
        focusedId: target,
      })),
    })
  },
  clearMaximize: () => {
    set({ workspaces: mapActive(get(), (workspace) => ({ ...workspace, maximizedId: null })) })
  },
  toggleFocusMode: () => {
    set({ workspaces: mapActive(get(), (workspace) => ({ ...workspace, focusMode: !workspace.focusMode })) })
  },
  toggleLock: () => {
    const locked = !activeOf(get()).locked
    set({ workspaces: mapActive(get(), (workspace) => ({ ...workspace, locked })) })
    toast(locked ? 'Layout locked' : 'Layout unlocked')
  },
  toggleBroadcast: () => {
    const broadcast = !activeOf(get()).broadcast
    set({ workspaces: mapActive(get(), (workspace) => ({ ...workspace, broadcast })) })
    toast(broadcast ? 'Broadcast on — keys go to every pane' : 'Broadcast off')
  },
  toggleMute: (id) => {
    set((state) => ({ panes: patchPane(state.panes, id, { muted: !state.panes[id]?.muted }) }))
    persist(get())
  },
  renamePane: (id, title) => {
    const next = title.trim()
    if (!next) return
    set((state) => ({ panes: patchPane(state.panes, id, { title: next, customTitle: true }) }))
    persist(get())
  },
  setAutoTitle: (id, title) => {
    const pane = get().panes[id]
    if (!pane || pane.customTitle || !title.trim() || pane.title === title) return
    set({ panes: patchPane(get().panes, id, { title: title.trim().slice(0, 80) }) })
  },
  markReady: (id, info) => {
    session.markLaunched(id)
    session.noteCwd(id, info.cwd)
    const pane = get().panes[id]
    if (!pane) return
    set({
      panes: patchPane(get().panes, id, {
        status: 'running',
        pid: info.pid,
        shell: info.shell || pane.shell,
        cwd: info.cwd || pane.cwd,
        exitCode: null,
        exitMessage: null,
      }),
    })
    persist(get())
  },
  markExit: (id, code, message) => {
    if (!get().panes[id]) return
    set({
      panes: patchPane(get().panes, id, {
        status: 'exited',
        exitCode: code,
        exitMessage: message ?? null,
        pid: null,
      }),
    })
  },
  setCwd: (id, cwd) => {
    const pane = get().panes[id]
    if (!pane || pane.cwd === cwd) return
    session.noteCwd(id, cwd)
    set({ panes: patchPane(get().panes, id, { cwd }) })
    persist(get())
  },
  bumpBell: (id) => {
    const workspace = activeOf(get())
    if (workspace.focusedId === id) return
    const pane = get().panes[id]
    if (!pane) return
    set({ panes: patchPane(get().panes, id, { bell: Math.min(99, pane.bell + 1) }) })
  },
  restartShell: (id) => {
    const pane = get().panes[id]
    if (!pane) return
    set({ panes: patchPane(get().panes, id, { status: 'starting', exitCode: null, exitMessage: null }) })
    session.restart(id, null, pane.cwd)
  },
  rerun: (id) => {
    const pane = get().panes[id]
    if (!pane?.command) return
    set({ panes: patchPane(get().panes, id, { status: 'starting', offerRerun: false, exitCode: null, exitMessage: null }) })
    session.restart(id, pane.command, pane.cwd)
    persist(get())
  },
  dismissRerun: (id) => {
    set({ panes: patchPane(get().panes, id, { offerRerun: false }) })
    persist(get())
  },
  rememberCommand: (command) => {
    const trimmed = command.trim()
    if (!trimmed) return
    set((state) => ({ recent: [trimmed, ...state.recent.filter((item) => item !== trimmed)].slice(0, 16) }))
    persist(get())
  },
  addWorkspace: () => {
    const id = uid('w')
    const name = `Desk ${get().workspaces.length + 1}`
    set((state) => ({
      workspaces: [...state.workspaces, blankWorkspace(id, name)],
      activeWorkspaceId: id,
    }))
    persist(get())
  },
  closeWorkspace: (id) => {
    const state = get()
    if (state.workspaces.length === 1) {
      toast('Keep at least one desk.')
      return
    }
    const workspace = state.workspaces.find((item) => item.id === id)
    if (!workspace) return
    const doomed = new Set([...leafIds(workspace.tree), ...workspace.shelf, ...Object.keys(workspace.rects)])
    const panes = { ...state.panes }
    for (const paneId of doomed) {
      delete panes[paneId]
      session.forgetPane(paneId)
    }
    const workspaces = state.workspaces.filter((item) => item.id !== id)
    set({
      panes,
      workspaces,
      activeWorkspaceId: state.activeWorkspaceId === id ? workspaces[0]!.id : state.activeWorkspaceId,
    })
    persist(get())
  },
  switchWorkspace: (id) => {
    if (!get().workspaces.some((workspace) => workspace.id === id)) return
    set({ activeWorkspaceId: id })
    persist(get())
  },
  renameWorkspace: (id, name) => {
    const next = name.trim()
    if (!next) return
    set({
      workspaces: get().workspaces.map((workspace) => (workspace.id === id ? { ...workspace, name: next.slice(0, 24) } : workspace)),
    })
    persist(get())
  },
  moveToWorkspace: (paneId, workspaceId) => {
    const state = get()
    const from = state.workspaces.find((workspace) => workspace.tree && contains(workspace.tree, paneId))
    const to = state.workspaces.find((workspace) => workspace.id === workspaceId)
    if (!from || !to || from.id === to.id || !from.tree) return
    const tree = removePane(from.tree, paneId)
    const rects = { ...from.rects }
    delete rects[paneId]
    set({
      workspaces: state.workspaces.map((workspace) => {
        if (workspace.id === from.id) {
          return { ...workspace, tree, rects, shelf: workspace.shelf.filter((id) => id !== paneId), focusedId: leafIds(tree)[0] ?? null }
        }
        if (workspace.id === to.id) {
          if (workspace.mode === 'free') {
            return {
              ...workspace,
              rects: { ...workspace.rects, [paneId]: { x: 0.1, y: 0.1, w: 0.5, h: 0.55 } },
              shelf: workspace.shelf.filter((id) => id !== paneId),
              focusedId: paneId,
            }
          }
          if (!workspace.tree) return { ...workspace, tree: { type: 'pane', id: paneId }, focusedId: paneId }
          const target = workspace.focusedId && contains(workspace.tree, workspace.focusedId) ? workspace.focusedId : leafIds(workspace.tree)[0]!
          return { ...workspace, tree: insertPane(workspace.tree, target, 'right', paneId), focusedId: paneId }
        }
        return workspace
      }),
      activeWorkspaceId: workspaceId,
    })
    persist(get())
  },
  cycleWorkspace: (step) => {
    const { workspaces, activeWorkspaceId } = get()
    const index = workspaces.findIndex((workspace) => workspace.id === activeWorkspaceId)
    const next = workspaces[(index + step + workspaces.length) % workspaces.length]
    if (next) get().switchWorkspace(next.id)
  },
  addProfile: (profile) => {
    set((state) => ({ profiles: [...state.profiles, { ...profile, id: uid('f') }] }))
    persist(get())
  },
  removeProfile: (id) => {
    set((state) => ({ profiles: state.profiles.filter((profile) => profile.id !== id) }))
    persist(get())
  },
  exportDesk: () => {
    const state = get()
    return JSON.stringify(
      {
        version: 1,
        settings: state.settings,
        workspaces: state.workspaces,
        activeWorkspaceId: state.activeWorkspaceId,
        panes: Object.values(state.panes),
        profiles: state.profiles,
        recent: state.recent,
      },
      null,
      2,
    )
  },
  importDesk: (raw) => {
    for (const id of Object.keys(get().panes)) session.forgetPane(id)
    const current = get()
    current.hydrate(JSON.parse(raw), {
      bootId: current.bootId,
      shell: current.shell,
      home: current.home,
      platform: current.platform,
    }, current.uploads)
    toast('Desk imported')
  },
}))
