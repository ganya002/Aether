export type FoldPalette = {
  shadow: [number, number, number]
  mid: [number, number, number]
  light: [number, number, number]
}

export type Preset = {
  id: string
  name: string
  kind: 'folds' | 'css'
  palette?: FoldPalette
}

export const PRESETS: Preset[] = [
  {
    id: 'tidepool',
    name: 'Tidepool',
    kind: 'folds',
    palette: { shadow: [10, 18, 30], mid: [48, 78, 108], light: [214, 228, 238] },
  },
  {
    id: 'dusk',
    name: 'Dusk',
    kind: 'folds',
    palette: { shadow: [24, 10, 8], mid: [112, 52, 32], light: [236, 196, 164] },
  },
  {
    id: 'pine',
    name: 'Pine',
    kind: 'folds',
    palette: { shadow: [6, 16, 14], mid: [24, 64, 52], light: [176, 214, 196] },
  },
  { id: 'aurora', name: 'Aurora', kind: 'css' },
  { id: 'ink', name: 'Ink', kind: 'css' },
  { id: 'midnight', name: 'Midnight', kind: 'css' },
  { id: 'porcelain', name: 'Porcelain', kind: 'css' },
]

const memory = new Map<string, string>()
let grain: string | null = null

export function grainUrl() {
  if (grain) return grain
  const canvas = document.createElement('canvas')
  canvas.width = 128
  canvas.height = 128
  const ctx = canvas.getContext('2d')
  if (!ctx) return ''
  const image = ctx.createImageData(128, 128)
  for (let i = 0; i < image.data.length; i += 4) {
    const value = 210 + Math.random() * 45
    image.data[i] = value
    image.data[i + 1] = value
    image.data[i + 2] = value
    image.data[i + 3] = 255
  }
  ctx.putImageData(image, 0, 0)
  grain = canvas.toDataURL('image/png')
  return grain
}

function mix(a: number, b: number, t: number) {
  return a + (b - a) * t
}

function tone(palette: FoldPalette, t: number) {
  const clamped = Math.min(1, Math.max(0, t))
  const [a, b, c] = clamped < 0.55
    ? [palette.shadow, palette.mid, clamped / 0.55]
    : [palette.mid, palette.light, (clamped - 0.55) / 0.45]
  return [mix(a[0], b[0], c), mix(a[1], b[1], c), mix(a[2], b[2], c)]
}

export function renderFolds(palette: FoldPalette) {
  const width = 540
  const height = 310
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const ctx = canvas.getContext('2d', { alpha: false })
  if (!ctx) return ''
  const image = ctx.createImageData(width, height)
  const data = image.data
  for (let y = 0; y < height; y++) {
    const v = y / height
    const sway = Math.sin(v * 5.1 + 0.4)
    for (let x = 0; x < width; x++) {
      const u = x / width
      const wx = u * 2.35 + sway * 0.16 + Math.sin(v * 12.5) * 0.035
      const wy = v * 1.7 + Math.cos(u * 4.2) * 0.15
      const phase = wx * 10.2 + Math.sin(wy * 3.05) * 1.65
      const fold = Math.sin(phase)
      const slope = Math.cos(phase)
      const cross = Math.sin(wy * 7.4 + wx * 1.35)
      let light = 0.48 + slope * 0.36 + fold * 0.06 + cross * 0.05
      light += Math.pow(Math.max(0, slope), 5) * 0.28
      const vignette = 1 - (u - 0.5) ** 2 * 0.45 - (v - 0.42) ** 2 * 0.55
      light *= Math.max(0.5, vignette)
      const [r, g, b] = tone(palette, light)
      const index = (y * width + x) * 4
      data[index] = r
      data[index + 1] = g
      data[index + 2] = b
      data[index + 3] = 255
    }
  }
  ctx.putImageData(image, 0, 0)
  const big = document.createElement('canvas')
  big.width = 1080
  big.height = 620
  const out = big.getContext('2d')
  if (!out) return canvas.toDataURL('image/jpeg', 0.84)
  out.imageSmoothingEnabled = true
  out.filter = 'blur(0.4px)'
  out.drawImage(canvas, 0, 0, big.width, big.height)
  return big.toDataURL('image/jpeg', 0.84)
}

export function presetImage(id: string) {
  const preset = PRESETS.find((item) => item.id === id)
  if (!preset || preset.kind !== 'folds' || !preset.palette) return null
  const cached = memory.get(id)
  if (cached) return cached
  const key = `aether-fold-v3-${id}`
  try {
    const stored = sessionStorage.getItem(key)
    if (stored) {
      memory.set(id, stored)
      return stored
    }
  } catch {
    /* storage unavailable */
  }
  const url = renderFolds(preset.palette)
  memory.set(id, url)
  try {
    sessionStorage.setItem(key, url)
  } catch {
    /* quota */
  }
  return url
}
