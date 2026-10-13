import type { ServerMessage } from '../../shared/protocol'

type PaneListener = (event: { kind: 'data'; data: Uint8Array } | { kind: 'mark'; name: 'begin' | 'end' }) => void
type GlobalListener = (message: ServerMessage) => void

export type Desired = {
  id: string
  cwd: string
  cols: number
  rows: number
  command: string | null
  shellOnly: boolean
  launched: boolean
  force: boolean
}

const desired = new Map<string, Desired>()
const mounted = new Set<string>()
const attachedGen = new Map<string, number>()
const paneListeners = new Map<string, Set<PaneListener>>()
const queues = new Map<string, Array<Parameters<PaneListener>[0]>>()
const globals = new Set<GlobalListener>()
const statusListeners = new Set<(status: 'connecting' | 'open' | 'closed') => void>()

let socket: WebSocket | null = null
let token = ''
let status: 'connecting' | 'open' | 'closed' = 'closed'
let stopped = false
let booting = false
let generation = 0
let attempt = 0
let openHook: () => void | Promise<void> = async () => {}
let pingTimer: number | null = null
const outbound: string[] = []

function setStatus(next: typeof status) {
  status = next
  for (const listener of statusListeners) listener(next)
}

function send(message: object) {
  const raw = JSON.stringify(message)
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(raw)
  else if ((message as { t?: string }).t !== 'ping') outbound.push(raw)
}

function sendOpen(pane: Desired) {
  const command = pane.force
    ? pane.shellOnly
      ? null
      : pane.command
    : pane.shellOnly || pane.launched
      ? null
      : pane.command
  const spawn = pane.force ? 'yes' : 'if-missing'
  pane.force = false
  send({
    t: 'open',
    id: pane.id,
    cols: pane.cols,
    rows: pane.rows,
    cwd: pane.cwd,
    command,
    spawn,
  })
}

function deliver(id: string, event: Parameters<PaneListener>[0]) {
  const listeners = paneListeners.get(id)
  if (!listeners || listeners.size === 0) {
    const queue = queues.get(id) ?? []
    queue.push(event)
    if (queue.length > 500) queue.shift()
    queues.set(id, queue)
    return
  }
  for (const listener of listeners) listener(event)
}

function handleText(raw: string) {
  let message: ServerMessage
  try {
    message = JSON.parse(raw) as ServerMessage
  } catch {
    return
  }
  if (message.t === 'replay-begin') {
    deliver(message.id, { kind: 'mark', name: 'begin' })
    return
  }
  if (message.t === 'replay-end') {
    deliver(message.id, { kind: 'mark', name: 'end' })
    return
  }
  for (const listener of globals) listener(message)
}

function handleBinary(buffer: Uint8Array) {
  if (buffer.length < 2 || buffer[0] !== 1) return
  const idLen = buffer[1] ?? 0
  const id = new TextDecoder().decode(buffer.subarray(2, 2 + idLen))
  deliver(id, { kind: 'data', data: buffer.subarray(2 + idLen) })
}

function connect() {
  if (stopped) return
  setStatus('connecting')
  const protocol = location.protocol === 'https:' ? 'wss' : 'ws'
  const ws = new WebSocket(`${protocol}://${location.host}/ws?token=${encodeURIComponent(token)}`)
  socket = ws
  ws.binaryType = 'arraybuffer'
  ws.onopen = () => {
    attempt = 0
    generation += 1
    setStatus('open')
    booting = true
    const queued = outbound.splice(0)
    for (const raw of queued) ws.send(raw)
    void Promise.resolve(openHook()).finally(() => {
      booting = false
    })
  }
  ws.onmessage = (event) => {
    if (typeof event.data === 'string') handleText(event.data)
    else handleBinary(new Uint8Array(event.data as ArrayBuffer))
  }
  ws.onclose = () => {
    if (socket === ws) socket = null
    setStatus('closed')
    if (stopped) return
    const delay = Math.min(4000, 280 * 2 ** attempt)
    attempt += 1
    setTimeout(connect, delay)
  }
  ws.onerror = () => {
    ws.close()
  }
}

export const session = {
  start(nextToken: string) {
    token = nextToken
    stopped = false
    connect()
    if (!pingTimer) {
      pingTimer = window.setInterval(() => {
        if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ t: 'ping' }))
      }, 25000)
    }
  },
  stop() {
    stopped = true
    socket?.close()
  },
  onConnect(hook: () => void | Promise<void>) {
    openHook = hook
  },
  onGlobal(listener: GlobalListener) {
    globals.add(listener)
    return () => globals.delete(listener)
  },
  onStatus(listener: (status: 'connecting' | 'open' | 'closed') => void) {
    statusListeners.add(listener)
    listener(status)
    return () => statusListeners.delete(listener)
  },
  onPane(id: string, listener: PaneListener) {
    let set = paneListeners.get(id)
    if (!set) {
      set = new Set()
      paneListeners.set(id, set)
    }
    set.add(listener)
    const queued = queues.get(id)
    if (queued?.length) {
      queues.delete(id)
      for (const event of queued) listener(event)
    }
    return () => {
      set?.delete(listener)
    }
  },
  syncPane(input: Omit<Desired, 'launched' | 'force'> & { launched?: boolean; force?: boolean }) {
    const prev = desired.get(input.id)
    desired.set(input.id, {
      id: input.id,
      cwd: input.cwd || prev?.cwd || '',
      cols: input.cols || prev?.cols || 80,
      rows: input.rows || prev?.rows || 24,
      command: input.command ?? prev?.command ?? null,
      shellOnly: input.shellOnly,
      launched: input.launched ?? prev?.launched ?? false,
      force: input.force ?? false,
    })
  },
  markLaunched(id: string) {
    const pane = desired.get(id)
    if (pane) pane.launched = true
  },
  markShellOnly(id: string) {
    const pane = desired.get(id)
    if (!pane) return
    pane.shellOnly = true
    pane.launched = true
  },
  noteCwd(id: string, cwd: string) {
    const pane = desired.get(id)
    if (pane && cwd) pane.cwd = cwd
  },
  updateSize(id: string, cols: number, rows: number) {
    const pane = desired.get(id)
    if (!pane || cols < 2 || rows < 2) return
    if (pane.cols === cols && pane.rows === rows) return
    pane.cols = cols
    pane.rows = rows
    if (pane.launched) send({ t: 'resize', id, cols, rows })
  },
  requestAttach(id: string) {
    mounted.add(id)
    if (status !== 'open' || booting) return
    if (attachedGen.get(id) === generation) return
    const pane = desired.get(id)
    if (!pane) return
    attachedGen.set(id, generation)
    sendOpen(pane)
  },
  reattachMounted() {
    for (const id of mounted) {
      const pane = desired.get(id)
      if (!pane) continue
      attachedGen.set(id, generation)
      sendOpen(pane)
    }
  },
  viewClosed(id: string) {
    mounted.delete(id)
    attachedGen.delete(id)
    queues.delete(id)
    send({ t: 'detach', id })
  },
  forgetPane(id: string) {
    desired.delete(id)
    mounted.delete(id)
    attachedGen.delete(id)
    queues.delete(id)
    send({ t: 'kill', id })
  },
  write(id: string, data: string) {
    if (!data) return
    send({ t: 'in', id, d: data })
  },
  restart(id: string, command: string | null, cwd?: string) {
    const pane = desired.get(id)
    if (!pane) return
    if (cwd) pane.cwd = cwd
    if (command !== null) pane.command = command
    pane.shellOnly = command === null
    pane.launched = false
    pane.force = true
    if (status === 'open' && !booting) {
      attachedGen.set(id, generation)
      sendOpen(pane)
    }
  },
}
