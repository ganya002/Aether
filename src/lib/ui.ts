import { create } from 'zustand'
import type { Guide } from './layout'

export type MenuItem = {
  id: string
  label: string
  hint?: string
  danger?: boolean
  disabled?: boolean
  onSelect: () => void
}

export type DropPreview = {
  targetId: string
  left: number
  top: number
  width: number
  height: number
  zone: 'left' | 'right' | 'top' | 'bottom' | 'center'
}

type Drag =
  | {
      kind: 'tile'
      id: string
      title: string
      accent: string
      x: number
      y: number
      drop: DropPreview | null
    }
  | {
      kind: 'free'
      guides: Guide[]
    }

type Toast = { id: string; text: string }

type UiState = {
  palette: boolean
  settings: boolean
  look: boolean
  about: boolean
  findId: string | null
  menu: { x: number; y: number; items: MenuItem[] } | null
  drag: Drag | null
  toasts: Toast[]
  hud: string | null
  connected: 'connecting' | 'open' | 'closed'
  setPalette: (open: boolean) => void
  togglePalette: () => void
  setSettings: (open: boolean) => void
  setLook: (open: boolean) => void
  setAbout: (open: boolean) => void
  setFind: (id: string | null) => void
  openMenu: (x: number, y: number, items: MenuItem[]) => void
  closeMenu: () => void
  setDrag: (drag: Drag | null) => void
  pushToast: (text: string) => void
  dismissToast: (id: string) => void
  setHud: (text: string | null) => void
  setConnected: (connected: UiState['connected']) => void
}

let toastSeq = 0
let hudTimer: ReturnType<typeof setTimeout> | null = null

export const useUi = create<UiState>((set) => ({
  palette: false,
  settings: false,
  look: false,
  about: false,
  findId: null,
  menu: null,
  drag: null,
  toasts: [],
  hud: null,
  connected: 'connecting',
  setPalette: (palette) => set(palette ? { palette, settings: false, look: false, about: false, menu: null } : { palette }),
  togglePalette: () =>
    set((state) => ({
      palette: !state.palette,
      settings: false,
      look: false,
      about: false,
      menu: null,
    })),
  setSettings: (settings) => set(settings ? { settings, palette: false, look: false, about: false } : { settings }),
  setLook: (look) => set({ look, about: false }),
  setAbout: (about) => set({ about, look: false }),
  setFind: (findId) => set({ findId }),
  openMenu: (x, y, items) => set({ menu: { x, y, items } }),
  closeMenu: () => set({ menu: null }),
  setDrag: (drag) => set({ drag }),
  pushToast: (text) => {
    const id = `t${++toastSeq}`
    set((state) => ({ toasts: [...state.toasts.slice(-3), { id, text }] }))
    setTimeout(() => {
      set((state) => ({ toasts: state.toasts.filter((toast) => toast.id !== id) }))
    }, 2200)
  },
  dismissToast: (id) => set((state) => ({ toasts: state.toasts.filter((toast) => toast.id !== id) })),
  setHud: (text) => {
    if (hudTimer) clearTimeout(hudTimer)
    set({ hud: text })
    if (text) {
      hudTimer = setTimeout(() => set({ hud: null }), 700)
    }
  },
  setConnected: (connected) => set({ connected }),
}))

export function toast(text: string) {
  useUi.getState().pushToast(text)
}
