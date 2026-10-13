export function isApple() {
  return typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform)
}

function primary(event: KeyboardEvent, apple: boolean) {
  if (apple) return event.metaKey && !event.ctrlKey
  return event.ctrlKey && !event.metaKey
}

function prettyKey(key: string) {
  const names: Record<string, string> = {
    Enter: '↩',
    ArrowLeft: '←',
    ArrowRight: '→',
    ArrowUp: '↑',
    ArrowDown: '↓',
    ',': ',',
  }
  return names[key] ?? (key.length === 1 ? key.toUpperCase() : key)
}

export function chordLabel(key: string, opts?: { shift?: boolean; alt?: boolean }, apple = isApple()) {
  if (apple) {
    return `${opts?.alt ? '⌥' : ''}${opts?.shift ? '⇧' : ''}⌘${prettyKey(key)}`
  }
  const bits = ['Ctrl']
  if (opts?.alt) bits.push('Alt')
  if (opts?.shift) bits.push('Shift')
  bits.push(prettyKey(key))
  return bits.join('+')
}

/** Returns a shortcut id, or null if this key should reach the shell. */
export function matchShortcut(event: KeyboardEvent, apple = isApple()): string | null {
  if (!primary(event, apple)) return null
  const key = event.key
  if (key.startsWith('Arrow')) {
    const dir = key.slice(5).toLowerCase()
    if (event.altKey && !event.shiftKey) return `focus-${dir}`
    if (event.shiftKey && !event.altKey) return `resize-${dir}`
    return null
  }
  if (key >= '1' && key <= '9' && !event.shiftKey && !event.altKey) return `pane-${key}`
  if ((key === '=' || key === '+') && !event.altKey) return 'font-up'
  if (key === '-' && !event.shiftKey && !event.altKey) return 'font-down'
  if (key === '0' && !event.shiftKey && !event.altKey) return 'font-reset'

  const shift = event.shiftKey
  const alt = event.altKey
  const table: Array<[string, string, boolean?, boolean?]> = [
    ['palette', 'k'],
    ['settings', ','],
    ['find', 'f'],
    ['new', 't'],
    ['new-here', 't', true],
    ['close', 'w'],
    ['split-right', 'd'],
    ['split-down', 'd', true],
    ['maximize', 'Enter'],
    ['focus-mode', 'Enter', true],
    ['minimize', 'm'],
    ['broadcast', 'b'],
    ['free', 'e'],
    ['equalize', 'e', true],
    ['lock', 'l', true],
    ['desk-next', ']', true],
    ['desk-prev', '[', true],
    ['desk-new', 'n'],
    ['clear', 'k', true],
  ]
  for (const [id, match, wantShift, wantAlt] of table) {
    if (match.toLowerCase() !== key.toLowerCase()) continue
    if (Boolean(wantShift) !== shift) continue
    if (Boolean(wantAlt) !== alt) continue
    if (event.repeat && id !== 'font-up' && id !== 'font-down') return null
    return id
  }
  return null
}

export const SHORTCUT_GROUPS: Array<{ group: string; items: Array<{ id: string; label: string; key: string; shift?: boolean; alt?: boolean }> }> = [
  {
    group: 'General',
    items: [
      { id: 'palette', label: 'Command palette', key: 'k' },
      { id: 'find', label: 'Find in pane', key: 'f' },
      { id: 'settings', label: 'Settings', key: ',' },
      { id: 'clear', label: 'Clear pane', key: 'k', shift: true },
    ],
  },
  {
    group: 'Panes',
    items: [
      { id: 'new', label: 'New terminal', key: 't' },
      { id: 'new-here', label: 'New terminal here', key: 't', shift: true },
      { id: 'close', label: 'Close pane', key: 'w' },
      { id: 'split-right', label: 'Split right', key: 'd' },
      { id: 'split-down', label: 'Split down', key: 'd', shift: true },
      { id: 'maximize', label: 'Fill the desk', key: 'Enter' },
      { id: 'minimize', label: 'Shelf', key: 'm' },
      { id: 'focus-mode', label: 'Focus mode', key: 'Enter', shift: true },
      { id: 'broadcast', label: 'Broadcast keys', key: 'b' },
      { id: 'pane', label: 'Focus pane 1–9', key: '1' },
    ],
  },
  {
    group: 'Layout',
    items: [
      { id: 'focus', label: 'Focus neighbor', key: '←', alt: true },
      { id: 'resize', label: 'Resize split', key: '←', shift: true },
      { id: 'free', label: 'Freeform / tile', key: 'e' },
      { id: 'equalize', label: 'Equalize', key: 'e', shift: true },
      { id: 'lock', label: 'Lock layout', key: 'l', shift: true },
    ],
  },
  {
    group: 'Desks',
    items: [
      { id: 'desk-new', label: 'New desk', key: 'n' },
      { id: 'desk-prev', label: 'Previous desk', key: '[', shift: true },
      { id: 'desk-next', label: 'Next desk', key: ']', shift: true },
    ],
  },
  {
    group: 'View',
    items: [
      { id: 'font-up', label: 'Bigger text', key: '=' },
      { id: 'font-down', label: 'Smaller text', key: '-' },
      { id: 'font-reset', label: 'Reset text size', key: '0' },
    ],
  },
]
