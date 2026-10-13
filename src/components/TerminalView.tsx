import { FitAddon } from '@xterm/addon-fit'
import { SearchAddon } from '@xterm/addon-search'
import { Unicode11Addon } from '@xterm/addon-unicode11'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { WebglAddon } from '@xterm/addon-webgl'
import { Terminal } from '@xterm/xterm'
import { useEffect, useRef } from 'react'
import { fontStack, shQuote } from '../lib/format'
import { matchShortcut } from '../lib/keys'
import { session } from '../lib/session'
import { useStore, visibleIds } from '../lib/store'
import { registerTerm } from '../lib/terms'
import { themeById } from '../lib/themes'
import { toast } from '../lib/ui'

let warnedWebgl = false
let audio: AudioContext | null = null

function beep() {
  try {
    audio ??= new AudioContext()
    const osc = audio.createOscillator()
    const gain = audio.createGain()
    osc.type = 'sine'
    osc.frequency.value = 640
    gain.gain.value = 0.025
    osc.connect(gain)
    gain.connect(audio.destination)
    osc.start()
    gain.gain.exponentialRampToValueAtTime(0.0001, audio.currentTime + 0.08)
    osc.stop(audio.currentTime + 0.09)
  } catch {
    /* the browser blocked audio */
  }
}

function pathsFromDrop(event: DragEvent) {
  const uri = event.dataTransfer?.getData('text/uri-list') || ''
  const fromUri = uri
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'))
    .map((line) => {
      if (!line.startsWith('file://')) return line
      try {
        return decodeURIComponent(new URL(line).pathname)
      } catch {
        return line
      }
    })
  if (fromUri.length) return fromUri
  return [...(event.dataTransfer?.files ?? [])].map((file) => file.name)
}

export function TerminalView({ id, onBell }: { id: string; onBell: () => void }) {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  const onBellRef = useRef(onBell)
  onBellRef.current = onBell
  const scrollback = useStore((state) => state.settings.scrollback)
  const webgl = useStore((state) => state.settings.webgl)
  const optionIsMeta = useStore((state) => state.settings.optionIsMeta)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    const settings = useStore.getState().settings
    const theme = themeById(settings.themeId)
    const term = new Terminal({
      allowProposedApi: true,
      allowTransparency: true,
      cursorBlink: settings.cursorBlink,
      cursorStyle: settings.cursorStyle,
      cursorInactiveStyle: 'outline',
      cursorWidth: 2,
      fontFamily: fontStack(settings.fontFamily),
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      letterSpacing: settings.letterSpacing,
      fontWeight: 400,
      fontWeightBold: 650,
      theme: { ...theme.term, background: '#00000000' },
      scrollback: settings.scrollback,
      macOptionIsMeta: settings.optionIsMeta,
      macOptionClickForcesSelection: true,
      rightClickSelectsWord: false,
      altClickMovesCursor: true,
      scrollOnUserInput: true,
      smoothScrollDuration: settings.smoothScroll && !settings.performance ? 70 : 0,
      rescaleOverlappingGlyphs: true,
      minimumContrastRatio: 1,
      drawBoldTextInBrightColors: false,
      customGlyphs: true,
      logLevel: 'off',
      linkHandler: {
        activate: (_event, text) => {
          if (/^https?:\/\//i.test(text)) window.open(text, '_blank', 'noopener,noreferrer')
        },
      },
    })
    const fit = new FitAddon()
    const search = new SearchAddon()
    term.loadAddon(fit)
    term.loadAddon(search)
    term.loadAddon(new Unicode11Addon())
    term.unicode.activeVersion = '11'
    term.loadAddon(new WebLinksAddon((_event, uri) => {
      if (/^https?:\/\//i.test(uri)) window.open(uri, '_blank', 'noopener,noreferrer')
    }))
    if (settings.webgl && !settings.performance) {
      try {
        const renderer = new WebglAddon()
        renderer.onContextLoss(() => renderer.dispose())
        term.loadAddon(renderer)
      } catch {
        if (!warnedWebgl) {
          warnedWebgl = true
          toast('WebGL is unavailable, so panes stay on the lighter renderer.')
        }
      }
    }
    term.open(host)
    termRef.current = term
    fitRef.current = fit

    const fitNow = () => {
      if (!host.isConnected || host.clientWidth < 8 || host.clientHeight < 8) return
      try {
        fit.fit()
      } catch {
        return
      }
      session.updateSize(id, term.cols, term.rows)
    }
    let frame = 0
    const scheduleFit = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(fitNow)
    }
    const observer = new ResizeObserver(scheduleFit)
    observer.observe(host)
    fitNow()

    const detachData = session.onPane(id, (event) => {
      if (event.kind === 'mark' && event.name === 'begin') {
        term.reset()
        return
      }
      if (event.kind === 'data') term.write(event.data)
    })
    session.requestAttach(id)

    const selection = term.onSelectionChange(() => {
      if (!useStore.getState().settings.copyOnSelect) return
      const text = term.getSelection()
      if (text) void navigator.clipboard.writeText(text).catch(() => undefined)
    })
    const title = term.onTitleChange((next) => useStore.getState().setAutoTitle(id, next))
    const bell = term.onBell(() => {
      const current = useStore.getState().settings
      if (current.bellVisual) onBellRef.current()
      useStore.getState().bumpBell(id)
      if (current.bellSound) beep()
    })
    term.parser.registerOscHandler(7, (data) => {
      try {
        let cwd = data
        if (cwd.startsWith('file://')) cwd = decodeURIComponent(new URL(cwd).pathname)
        if (cwd.startsWith('/')) useStore.getState().setCwd(id, cwd)
      } catch {
        /* malformed OSC 7 */
      }
      return true
    })
    term.attachCustomKeyEventHandler((event) => {
      if (event.type !== 'keydown') return true
      return !matchShortcut(event)
    })
    term.onData((data) => {
      session.write(id, data)
      const state = useStore.getState()
      const workspace = state.active()
      if (!workspace.broadcast) return
      const self = state.panes[id]
      if (!self || self.muted) return
      for (const otherId of visibleIds(workspace)) {
        if (otherId === id) continue
        const other = state.panes[otherId]
        if (!other || other.muted || other.status !== 'running') continue
        session.write(otherId, data)
      }
    })

    const unregister = registerTerm(id, {
      focus: () => term.focus(),
      clear: () => term.clear(),
      selectAll: () => term.selectAll(),
      hasSelection: () => term.hasSelection(),
      copy: async () => {
        const text = term.getSelection()
        if (!text) throw new Error('empty')
        await navigator.clipboard.writeText(text)
      },
      paste: async () => {
        const text = await navigator.clipboard.readText()
        if (text) session.write(id, text)
      },
      find: (query, dir) => {
        if (!query) {
          search.clearDecorations()
          return false
        }
        const options = {
          decorations: {
            matchBackground: '#8eb6ff',
            matchOverviewRuler: '#8eb6ff',
            activeMatchBackground: '#f4f7fb',
            activeMatchColorOverviewRuler: '#f4f7fb',
          },
        }
        return dir === 'next' ? search.findNext(query, options) : search.findPrevious(query, options)
      },
    })

    const onDrop = (event: DragEvent) => {
      const paths = pathsFromDrop(event)
      if (!paths.length) return
      event.preventDefault()
      event.stopPropagation()
      session.write(id, `${paths.map((item) => shQuote(item)).join(' ')} `)
    }
    const onDragOver = (event: DragEvent) => {
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
      event.preventDefault()
    }
    host.addEventListener('drop', onDrop)
    host.addEventListener('dragover', onDragOver)

    return () => {
      cancelAnimationFrame(frame)
      observer.disconnect()
      host.removeEventListener('drop', onDrop)
      host.removeEventListener('dragover', onDragOver)
      selection.dispose()
      title.dispose()
      bell.dispose()
      detachData()
      unregister()
      session.viewClosed(id)
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
  }, [id, optionIsMeta, scrollback, webgl])

  const fontFamily = useStore((state) => state.settings.fontFamily)
  const fontSize = useStore((state) => state.settings.fontSize)
  const lineHeight = useStore((state) => state.settings.lineHeight)
  const letterSpacing = useStore((state) => state.settings.letterSpacing)
  const cursorBlink = useStore((state) => state.settings.cursorBlink)
  const cursorStyle = useStore((state) => state.settings.cursorStyle)
  const themeId = useStore((state) => state.settings.themeId)
  const smoothScroll = useStore((state) => state.settings.smoothScroll)
  const performance = useStore((state) => state.settings.performance)

  useEffect(() => {
    const term = termRef.current
    if (!term) return
    const theme = themeById(themeId)
    term.options.theme = { ...theme.term, background: '#00000000' }
    term.options.fontFamily = fontStack(fontFamily)
    term.options.fontSize = fontSize
    term.options.lineHeight = lineHeight
    term.options.letterSpacing = letterSpacing
    term.options.cursorBlink = cursorBlink
    term.options.cursorStyle = cursorStyle
    term.options.smoothScrollDuration = smoothScroll && !performance ? 70 : 0
    const frame = requestAnimationFrame(() => {
      try {
        fitRef.current?.fit()
      } catch {
        /* host not ready */
      }
      session.updateSize(id, term.cols, term.rows)
    })
    return () => cancelAnimationFrame(frame)
  }, [cursorBlink, cursorStyle, fontFamily, fontSize, id, letterSpacing, lineHeight, performance, smoothScroll, themeId])

  return <div ref={hostRef} className="term-fit" />
}
