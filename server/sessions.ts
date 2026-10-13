import { spawn, type IPty } from 'node-pty'
import type { WebSocket } from 'ws'
import type { ServerMessage } from '../shared/protocol'
import { RingBuffer } from './ring'
import { defaultShell, safeCwd, shellEnv, spawnSpec } from './shell'

type Socket = WebSocket & { caughtUp?: Set<string> }

export type Session = {
  id: string
  pty: IPty
  ring: RingBuffer
  cwd: string
  shell: string
  command: string | null
  alive: boolean
  exitCode: number | null
  suppressExit: boolean
  paused: boolean
}

const sessions = new Map<string, Session>()
const sockets = new Set<Socket>()

let onJson: (socket: Socket, message: ServerMessage) => void = () => {}
let onBinary: (socket: Socket, frame: Buffer) => void = () => {}

export function bindSend(
  json: (socket: Socket, message: ServerMessage) => void,
  binary: (socket: Socket, frame: Buffer) => void,
) {
  onJson = json
  onBinary = binary
}

export function addSocket(socket: Socket) {
  socket.caughtUp = new Set()
  sockets.add(socket)
}

export function removeSocket(socket: Socket) {
  sockets.delete(socket)
}

export function sessionCount() {
  return sessions.size
}

export function encodeData(id: string, payload: Buffer) {
  const idb = Buffer.from(id)
  const out = Buffer.allocUnsafe(2 + idb.length + payload.length)
  out[0] = 1
  out[1] = idb.length
  idb.copy(out, 2)
  payload.copy(out, 2 + idb.length)
  return out
}

function broadcastJson(message: ServerMessage) {
  for (const socket of sockets) onJson(socket, message)
}

function fanout(session: Session, payload: Buffer) {
  const frame = encodeData(session.id, payload)
  let blocked = false
  for (const socket of sockets) {
    if (!socket.caughtUp?.has(session.id)) continue
    if (socket.readyState !== socket.OPEN) continue
    if (socket.bufferedAmount > 1_500_000) {
      blocked = true
      continue
    }
    onBinary(socket, frame)
  }
  if (blocked && !session.paused && session.alive) {
    session.paused = true
    try {
      session.pty.pause()
    } catch {
      /* already gone */
    }
  }
}

export function resumeIfDrained() {
  const blocked = [...sockets].some((socket) => socket.bufferedAmount > 256_000)
  if (blocked) return
  for (const session of sessions.values()) {
    if (!session.paused) continue
    session.paused = false
    try {
      session.pty.resume()
    } catch {
      /* already gone */
    }
  }
}

/**
 * Snapshot first, then mark the socket caught up, then send.
 * Node won't deliver pty data until this stack returns, so the
 * snapshot and the live stream share a boundary with no gap and no duplicate.
 */
function attach(socket: Socket, session: Session) {
  const snap = session.ring.snapshot()
  socket.caughtUp?.add(session.id)
  onJson(socket, { t: 'replay-begin', id: session.id })
  if (snap.length) onBinary(socket, encodeData(session.id, snap))
  onJson(socket, { t: 'replay-end', id: session.id })
}

function sendReady(socket: Socket, session: Session) {
  onJson(socket, {
    t: 'ready',
    id: session.id,
    pid: session.pty.pid,
    cwd: session.cwd,
    shell: session.shell,
    alive: session.alive,
  })
}

function killQuiet(session: Session) {
  session.suppressExit = true
  session.alive = false
  try {
    session.pty.kill()
  } catch {
    /* already dead */
  }
}

function createSession(id: string, cols: number, rows: number, cwd: string | undefined, command: string | null) {
  const shell = defaultShell()
  const dir = safeCwd(cwd)
  const spec = spawnSpec(shell, command)
  const pty = spawn(spec.file, spec.args, {
    name: 'xterm-256color',
    cols: Math.max(2, cols),
    rows: Math.max(2, rows),
    cwd: dir,
    env: shellEnv(shell),
  })
  const session: Session = {
    id,
    pty,
    ring: new RingBuffer(1024 * 1024),
    cwd: dir,
    shell,
    command,
    alive: true,
    exitCode: null,
    suppressExit: false,
    paused: false,
  }
  pty.onData((data) => {
    const buf = Buffer.from(data, 'utf8')
    session.ring.push(buf)
    fanout(session, buf)
  })
  pty.onExit(({ exitCode, signal }) => {
    session.alive = false
    session.exitCode = exitCode ?? (signal ? 128 + signal : 0)
    if (session.suppressExit) return
    broadcastJson({
      t: 'exit',
      id,
      code: session.exitCode ?? 0,
      signal: signal || undefined,
    })
  })
  sessions.set(id, session)
  return session
}

export function openSession(
  socket: Socket,
  opts: { id: string; cols: number; rows: number; cwd?: string; command?: string | null; spawn: 'no' | 'if-missing' | 'yes' },
) {
  const cols = clampDim(opts.cols)
  const rows = clampDim(opts.rows)
  let session = sessions.get(opts.id)
  if (session && opts.spawn === 'yes') {
    killQuiet(session)
    sessions.delete(opts.id)
    for (const peer of sockets) peer.caughtUp?.delete(opts.id)
    session = undefined
  }
  if (session?.alive) {
    try {
      session.pty.resize(cols, rows)
    } catch {
      /* ignore */
    }
    attach(socket, session)
    sendReady(socket, session)
    return
  }
  if (session && !session.alive) {
    attach(socket, session)
    onJson(socket, { t: 'exit', id: opts.id, code: session.exitCode ?? 0 })
    return
  }
  if (opts.spawn === 'no') {
    onJson(socket, { t: 'error', id: opts.id, message: 'That terminal is gone.' })
    return
  }
  if (opts.command && opts.command.length > 8000) {
    onJson(socket, { t: 'error', id: opts.id, message: 'That command is too long.' })
    return
  }
  try {
    session = createSession(opts.id, cols, rows, opts.cwd, opts.command ?? null)
  } catch (error) {
    onJson(socket, {
      t: 'error',
      id: opts.id,
      message: error instanceof Error ? error.message : 'Could not start the shell.',
    })
    return
  }
  for (const peer of sockets) peer.caughtUp?.delete(opts.id)
  attach(socket, session)
  sendReady(socket, session)
}

export function writeSession(id: string, data: string) {
  const session = sessions.get(id)
  if (!session?.alive || !data) return
  try {
    session.pty.write(data)
  } catch {
    /* closed */
  }
}

export function resizeSession(id: string, cols: number, rows: number) {
  const session = sessions.get(id)
  if (!session?.alive) return
  try {
    session.pty.resize(clampDim(cols), clampDim(rows))
  } catch {
    /* closed */
  }
}

export function detachSession(socket: Socket, id: string) {
  socket.caughtUp?.delete(id)
}

export function killSession(id: string) {
  const session = sessions.get(id)
  if (!session) return
  killQuiet(session)
  sessions.delete(id)
  for (const socket of sockets) socket.caughtUp?.delete(id)
}

export function pollCwds() {
  for (const session of sessions.values()) {
    if (!session.alive) continue
    void readCwd(session.pty.pid).then((cwd) => {
      if (!cwd || cwd === session.cwd || !session.alive) return
      session.cwd = cwd
      broadcastJson({ t: 'cwd', id: session.id, cwd })
    })
  }
}

async function readCwd(pid: number): Promise<string | null> {
  if (process.platform === 'linux') {
    try {
      const fs = await import('node:fs/promises')
      return await fs.readlink(`/proc/${pid}/cwd`)
    } catch {
      return null
    }
  }
  if (process.platform === 'darwin') {
    const { execFile } = await import('node:child_process')
    return new Promise((resolve) => {
      execFile('lsof', ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'], { timeout: 1500 }, (error, stdout) => {
        if (error) return resolve(null)
        const line = stdout.split('\n').find((entry) => entry.startsWith('n'))
        resolve(line ? line.slice(1) : null)
      })
    })
  }
  return null
}

export function killAll() {
  for (const session of sessions.values()) killQuiet(session)
  sessions.clear()
}

function clampDim(value: number) {
  if (!Number.isFinite(value)) return 24
  return Math.max(2, Math.min(500, Math.floor(value)))
}
