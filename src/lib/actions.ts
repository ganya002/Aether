import type { Direction } from './layout'
import { useStore } from './store'
import { termApi } from './terms'
import { useUi } from './ui'

export function runShortcut(id: string) {
  const store = useStore.getState()
  const ui = useUi.getState()
  const workspace = store.active()
  const focused = workspace.focusedId

  if (id === 'palette') {
    ui.togglePalette()
    return
  }
  if (id === 'settings') {
    ui.setSettings(!ui.settings)
    return
  }
  if (id === 'find') {
    if (focused) ui.setFind(ui.findId === focused ? null : focused)
    return
  }
  if (id === 'new' || id === 'new-here') {
    const cwd = id === 'new-here' && focused ? store.panes[focused]?.cwd : undefined
    store.createPane({ cwd })
    return
  }
  if (id === 'close') {
    if (focused) store.closePane(focused)
    return
  }
  if (id === 'split-right') {
    store.split('right')
    return
  }
  if (id === 'split-down') {
    store.split('down')
    return
  }
  if (id === 'maximize') {
    store.toggleMaximize()
    return
  }
  if (id === 'focus-mode') {
    store.toggleFocusMode()
    return
  }
  if (id === 'minimize') {
    if (focused) store.minimize(focused)
    return
  }
  if (id === 'broadcast') {
    store.toggleBroadcast()
    return
  }
  if (id === 'free') {
    store.toggleMode()
    return
  }
  if (id === 'equalize') {
    store.equalize()
    return
  }
  if (id === 'lock') {
    store.toggleLock()
    return
  }
  if (id === 'desk-next') {
    store.cycleWorkspace(1)
    return
  }
  if (id === 'desk-prev') {
    store.cycleWorkspace(-1)
    return
  }
  if (id === 'desk-new') {
    store.addWorkspace()
    return
  }
  if (id === 'clear') {
    termApi(focused)?.clear()
    return
  }
  if (id === 'font-up' || id === 'font-down' || id === 'font-reset') {
    const current = store.settings.fontSize
    const fontSize = id === 'font-reset' ? 14 : id === 'font-up' ? Math.min(24, current + 1) : Math.max(10, current - 1)
    store.patchSettings({ fontSize })
    ui.setHud(`${fontSize}px`)
    return
  }
  if (id.startsWith('pane-')) {
    store.focusIndex(Number(id.slice(5)) - 1)
    return
  }
  if (id.startsWith('focus-')) {
    store.focusDirection(id.slice(6) as Direction)
    return
  }
  if (id.startsWith('resize-')) {
    store.nudgeFocused(id.slice(7) as Direction)
  }
}

export function runPaletteAction(action: string) {
  const ui = useUi.getState()
  ui.setPalette(false)
  if (action === 'arrange-main') useStore.getState().arrangePattern('main')
  else if (action === 'arrange-columns') useStore.getState().arrangePattern('columns')
  else if (action === 'arrange-rows') useStore.getState().arrangePattern('rows')
  else if (action === 'arrange-grid') useStore.getState().arrangePattern('grid')
  else if (action === 'tidy') useStore.getState().tidy()
  else if (action === 'look') ui.setLook(true)
  else if (action === 'settings') ui.setSettings(true)
  else runShortcut(action)
}

export function launchCommand(command: string, cwd?: string) {
  const store = useStore.getState()
  const workspace = store.active()
  const dir = cwd || (workspace.focusedId ? store.panes[workspace.focusedId]?.cwd : undefined) || store.home
  store.createPane({ command, cwd: dir })
  useUi.getState().setPalette(false)
}
