import { fuzzyScore } from './fuzzy'
import type { Pane, Profile, Workspace } from './store'
import { themes } from './themes'

export type PaletteItem = {
  id: string
  title: string
  hint?: string
  group: string
  kind: 'run' | 'action' | 'pane' | 'workspace' | 'theme' | 'profile' | 'recent'
  action?: string
  paneId?: string
  workspaceId?: string
  themeId?: string
  command?: string
  cwd?: string
}

const ACTIONS: Array<{ action: string; title: string; hint: string }> = [
  { action: 'new', title: 'New terminal', hint: 'Shell' },
  { action: 'split-right', title: 'Split right', hint: 'Layout' },
  { action: 'split-down', title: 'Split down', hint: 'Layout' },
  { action: 'arrange-main', title: 'Arrange as main and stack', hint: 'Layout' },
  { action: 'arrange-columns', title: 'Arrange as columns', hint: 'Layout' },
  { action: 'arrange-rows', title: 'Arrange as rows', hint: 'Layout' },
  { action: 'arrange-grid', title: 'Arrange as grid', hint: 'Layout' },
  { action: 'free', title: 'Toggle freeform', hint: 'Layout' },
  { action: 'tidy', title: 'Tidy windows', hint: 'Layout' },
  { action: 'equalize', title: 'Equalize splits', hint: 'Layout' },
  { action: 'broadcast', title: 'Toggle broadcast', hint: 'Input' },
  { action: 'focus-mode', title: 'Toggle focus mode', hint: 'View' },
  { action: 'maximize', title: 'Fill the desk with this pane', hint: 'View' },
  { action: 'settings', title: 'Open settings', hint: 'App' },
  { action: 'look', title: 'Wallpaper and glass', hint: 'App' },
  { action: 'clear', title: 'Clear terminal', hint: 'Pane' },
  { action: 'lock', title: 'Lock or unlock layout', hint: 'Layout' },
]

export function buildPalette(query: string, input: {
  panes: Pane[]
  workspaces: Workspace[]
  profiles: Profile[]
  recent: string[]
}): PaletteItem[] {
  const q = query.trim()
  const items: PaletteItem[] = []
  for (const action of ACTIONS) {
    items.push({ id: `a:${action.action}`, title: action.title, hint: action.hint, group: 'Actions', kind: 'action', action: action.action })
  }
  for (const pane of input.panes) {
    items.push({
      id: `p:${pane.id}`,
      title: pane.title,
      hint: pane.cwd,
      group: 'Panes',
      kind: 'pane',
      paneId: pane.id,
    })
  }
  for (const workspace of input.workspaces) {
    items.push({ id: `w:${workspace.id}`, title: workspace.name, hint: 'Desk', group: 'Desks', kind: 'workspace', workspaceId: workspace.id })
  }
  for (const theme of themes) {
    items.push({ id: `t:${theme.id}`, title: `${theme.name} theme`, hint: 'Appearance', group: 'Themes', kind: 'theme', themeId: theme.id })
  }
  for (const profile of input.profiles) {
    items.push({
      id: `f:${profile.id}`,
      title: profile.name,
      hint: profile.command,
      group: 'Profiles',
      kind: 'profile',
      command: profile.command,
      cwd: profile.cwd,
    })
  }
  for (const command of input.recent) {
    items.push({ id: `r:${command}`, title: command, hint: 'Recent', group: 'Recent', kind: 'recent', command })
  }

  if (!q) {
    const recent = items.filter((item) => item.kind === 'recent').slice(0, 5)
    const actions = items.filter((item) => item.kind === 'action').slice(0, 6)
    const panes = items.filter((item) => item.kind === 'pane')
    return [...recent, ...actions, ...panes].slice(0, 12)
  }

  const ranked = items
    .map((item) => ({ item, score: fuzzyScore(q, `${item.title} ${item.hint ?? ''}`) }))
    .filter((row): row is { item: PaletteItem; score: number } => row.score !== null)
    .sort((a, b) => b.score - a.score)
    .map((row) => row.item)

  const run: PaletteItem = {
    id: `run:${q}`,
    title: `Run “${q}”`,
    hint: 'New terminal',
    group: 'Run',
    kind: 'run',
    command: q,
  }
  const best = ranked[0]
  const bestScore = best ? fuzzyScore(q, `${best.title} ${best.hint ?? ''}`) ?? 0 : 0
  if (!best || bestScore < 28) return [run, ...ranked].slice(0, 14)
  return [...ranked.slice(0, 8), run].slice(0, 14)
}
