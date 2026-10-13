export type TermColors = {
  foreground: string
  cursor: string
  cursorAccent: string
  selectionBackground: string
  black: string
  red: string
  green: string
  yellow: string
  blue: string
  magenta: string
  cyan: string
  white: string
  brightBlack: string
  brightRed: string
  brightGreen: string
  brightYellow: string
  brightBlue: string
  brightMagenta: string
  brightCyan: string
  brightWhite: string
}

export type Theme = {
  id: string
  name: string
  tone: 'dark' | 'light'
  scrim: string
  fg: string
  muted: string
  faint: string
  line: string
  lineStrong: string
  accent: string
  shadow: string
  vignette: string
  term: TermColors
}

const darkBase = {
  brightWhite: '#f7fbff',
  cursorAccent: '#0c1016',
}

export const themes: Theme[] = [
  {
    id: 'tide',
    name: 'Tide',
    tone: 'dark',
    scrim: '8, 12, 18',
    fg: '#e6eef8',
    muted: 'rgba(230, 238, 248, 0.64)',
    faint: 'rgba(230, 238, 248, 0.40)',
    line: 'rgba(255, 255, 255, 0.14)',
    lineStrong: 'rgba(255, 255, 255, 0.34)',
    accent: '#9dc4ff',
    shadow: '0 22px 50px rgba(0, 0, 0, 0.38)',
    vignette: '0.45',
    term: {
      ...darkBase,
      foreground: '#d7e2ee',
      cursor: '#f3f7fb',
      selectionBackground: 'rgba(157, 196, 255, 0.28)',
      black: '#1a2330',
      red: '#ff8d7d',
      green: '#7ee0b4',
      yellow: '#f2c56d',
      blue: '#8eb6ff',
      magenta: '#d7b0ff',
      cyan: '#86d6ea',
      white: '#d5deea',
      brightBlack: '#617089',
      brightRed: '#ffb4a8',
      brightGreen: '#b6f3d4',
      brightYellow: '#ffe1a6',
      brightBlue: '#c5dcff',
      brightMagenta: '#edd8ff',
      brightCyan: '#c3f1f8',
    },
  },
  {
    id: 'dusk',
    name: 'Dusk',
    tone: 'dark',
    scrim: '22, 12, 10',
    fg: '#f6ebe4',
    muted: 'rgba(246, 235, 228, 0.66)',
    faint: 'rgba(246, 235, 228, 0.42)',
    line: 'rgba(255, 236, 220, 0.14)',
    lineStrong: 'rgba(255, 236, 220, 0.32)',
    accent: '#ffb089',
    shadow: '0 22px 50px rgba(20, 6, 2, 0.42)',
    vignette: '0.5',
    term: {
      ...darkBase,
      foreground: '#f3e6dc',
      cursor: '#fff1e8',
      selectionBackground: 'rgba(255, 176, 137, 0.28)',
      black: '#2a1814',
      red: '#ff7d66',
      green: '#b6d98a',
      yellow: '#f0c27a',
      blue: '#f0a080',
      magenta: '#f0b0c8',
      cyan: '#e7c2a4',
      white: '#f6e7dc',
      brightBlack: '#8a6558',
      brightRed: '#ffb0a0',
      brightGreen: '#d8efb4',
      brightYellow: '#ffe0b0',
      brightBlue: '#ffd0bc',
      brightMagenta: '#ffd0de',
      brightCyan: '#f6ddc8',
    },
  },
  {
    id: 'pine',
    name: 'Pine',
    tone: 'dark',
    scrim: '8, 16, 14',
    fg: '#e5f3ec',
    muted: 'rgba(229, 243, 236, 0.66)',
    faint: 'rgba(229, 243, 236, 0.42)',
    line: 'rgba(220, 255, 236, 0.14)',
    lineStrong: 'rgba(220, 255, 236, 0.32)',
    accent: '#8ee0c0',
    shadow: '0 22px 50px rgba(0, 10, 8, 0.42)',
    vignette: '0.48',
    term: {
      ...darkBase,
      foreground: '#dceee4',
      cursor: '#f2fff8',
      selectionBackground: 'rgba(142, 224, 192, 0.28)',
      black: '#14211c',
      red: '#ff9b8a',
      green: '#7ddeaf',
      yellow: '#e4d18a',
      blue: '#8fd0c0',
      magenta: '#c6b6e4',
      cyan: '#7fd4c8',
      white: '#d7ebe2',
      brightBlack: '#5d756c',
      brightRed: '#ffc2b6',
      brightGreen: '#c6f3dc',
      brightYellow: '#f3e6b4',
      brightBlue: '#c6eee4',
      brightMagenta: '#e4daf8',
      brightCyan: '#c8f6ee',
    },
  },
  {
    id: 'midnight',
    name: 'Midnight',
    tone: 'dark',
    scrim: '10, 10, 12',
    fg: '#eceff4',
    muted: 'rgba(236, 239, 244, 0.64)',
    faint: 'rgba(236, 239, 244, 0.40)',
    line: 'rgba(255, 255, 255, 0.12)',
    lineStrong: 'rgba(255, 255, 255, 0.30)',
    accent: '#d5dbe6',
    shadow: '0 22px 48px rgba(0, 0, 0, 0.45)',
    vignette: '0.55',
    term: {
      ...darkBase,
      foreground: '#e6e9ef',
      cursor: '#ffffff',
      selectionBackground: 'rgba(213, 219, 230, 0.22)',
      black: '#1c1e24',
      red: '#ff8b80',
      green: '#b5d9a4',
      yellow: '#e6d39a',
      blue: '#b9c7de',
      magenta: '#d7c6de',
      cyan: '#c5d6d6',
      white: '#e4e7ee',
      brightBlack: '#6d7380',
      brightRed: '#ffc0ba',
      brightGreen: '#d8efcc',
      brightYellow: '#f6e8c4',
      brightBlue: '#dde6f4',
      brightMagenta: '#efe4f2',
      brightCyan: '#e4f2f2',
    },
  },
  {
    id: 'rose',
    name: 'Rose',
    tone: 'dark',
    scrim: '22, 16, 24',
    fg: '#f4e9f2',
    muted: 'rgba(244, 233, 242, 0.66)',
    faint: 'rgba(244, 233, 242, 0.42)',
    line: 'rgba(255, 230, 246, 0.14)',
    lineStrong: 'rgba(255, 230, 246, 0.32)',
    accent: '#e3b6ff',
    shadow: '0 22px 50px rgba(10, 0, 12, 0.42)',
    vignette: '0.5',
    term: {
      ...darkBase,
      foreground: '#f0e4ee',
      cursor: '#fff6fc',
      selectionBackground: 'rgba(227, 182, 255, 0.28)',
      black: '#261a28',
      red: '#ff8ea8',
      green: '#c6e2a4',
      yellow: '#f0d09a',
      blue: '#d0b0f0',
      magenta: '#f0b0d8',
      cyan: '#e8c6de',
      white: '#f4e6f0',
      brightBlack: '#806078',
      brightRed: '#ffc0d0',
      brightGreen: '#e4f4cc',
      brightYellow: '#ffe6c0',
      brightBlue: '#ead8ff',
      brightMagenta: '#ffd6ec',
      brightCyan: '#f8e4f0',
    },
  },
  {
    id: 'porcelain',
    name: 'Porcelain',
    tone: 'light',
    scrim: '246, 243, 236',
    fg: '#1d2430',
    muted: 'rgba(29, 36, 48, 0.62)',
    faint: 'rgba(29, 36, 48, 0.42)',
    line: 'rgba(28, 32, 40, 0.14)',
    lineStrong: 'rgba(28, 32, 40, 0.28)',
    accent: '#2457c5',
    shadow: '0 18px 40px rgba(40, 32, 20, 0.12)',
    vignette: '0.18',
    term: {
      foreground: '#1c2430',
      cursor: '#1c2430',
      cursorAccent: '#f7f4ee',
      selectionBackground: 'rgba(36, 87, 197, 0.16)',
      black: '#1c2430',
      red: '#b42318',
      green: '#17663f',
      yellow: '#8a5a10',
      blue: '#1d4fd7',
      magenta: '#8a3478',
      cyan: '#0e6670',
      white: '#efeae2',
      brightBlack: '#5c6778',
      brightRed: '#d6453d',
      brightGreen: '#2f8f5b',
      brightYellow: '#b5811a',
      brightBlue: '#3b6fe0',
      brightMagenta: '#b05aa0',
      brightCyan: '#1a8790',
      brightWhite: '#ffffff',
    },
  },
]

export function themeById(id: string) {
  return themes.find((theme) => theme.id === id) ?? themes[0]!
}
