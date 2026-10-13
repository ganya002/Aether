import { timingSafeEqual, randomBytes, randomUUID } from 'node:crypto'
import { createReadStream } from 'node:fs'
import fs from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocketServer, type WebSocket } from 'ws'
import { VERSION, type ClientMessage, type ServerMessage } from '../shared/protocol'
import {
  addSocket,
  bindSend,
  detachSession,
  killAll,
  killSession,
  openSession,
  pollCwds,
  removeSocket,
  resizeSession,
  resumeIfDrained,
  sessionCount,
  writeSession,
} from './sessions'
import { defaultShell } from './shell'

const BOOT_ID = randomUUID()
const TOKEN = randomBytes(24).toString('hex')
process.env.AETHER_TOKEN = TOKEN

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const DIST = path.join(ROOT, 'dist')

function dataDir() {
  if (process.env.AETHER_DATA) return process.env.AETHER_DATA
  const home = os.homedir()
  if (process.platform === 'darwin') return path.join(home, 'Library', 'Application Support', 'Aether')
  if (process.platform === 'win32') return path.join(process.env.APPDATA || home, 'Aether')
  return path.join(process.env.XDG_CONFIG_HOME || path.join(home, '.config'), 'aether')
}

const DATA = dataDir()
const STATE_PATH = path.join(DATA, 'state.json')
const BG_DIR = path.join(DATA, 'backgrounds')

type Socket = WebSocket & { caughtUp?: Set<string> }

function safeEqual(a: string, b: string) {
  const left = Buffer.from(a)
  const right = Buffer.from(b)
  if (left.length !== right.length) return false
  return timingSafeEqual(left, right)
}

async function readJsonBody(req: http.IncomingMessage, limit: number) {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    size += buf.length
    if (size > limit) throw new Error('too large')
    chunks.push(buf)
  }
  return Buffer.concat(chunks)
}

function sendJson(res: http.ServerResponse, status: number, body: unknown) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
  })
  res.end(payload)
}

function isSafeId(id: string) {
  return /^[a-zA-Z0-9_-]{1,80}$/.test(id)
}

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.woff2': 'font/woff2',
}

async function serveStatic(req: http.IncomingMessage, res: http.ServerResponse) {
  const url = new URL(req.url || '/', 'http://localhost')
  let rel = decodeURIComponent(url.pathname)
  if (rel === '/') rel = '/index.html'
  const file = path.normalize(path.join(DIST, rel))
  if (!file.startsWith(DIST)) {
    res.writeHead(403)
    res.end()
    return
  }
  try {
    const stat = await fs.stat(file)
    if (!stat.isFile()) throw new Error('not a file')
    if (file.endsWith(`${path.sep}index.html`) || file.endsWith('/index.html')) {
      const html = (await fs.readFile(file, 'utf8')).replaceAll('__AETHER_TOKEN__', TOKEN)
      res.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      })
      res.end(html)
      return
    }
    res.writeHead(200, {
      'content-type': MIME[path.extname(file)] || 'application/octet-stream',
      'cache-control': 'public, max-age=3600',
    })
    createReadStream(file).pipe(res)
  } catch {
    const index = path.join(DIST, 'index.html')
    try {
      const html = (await fs.readFile(index, 'utf8')).replaceAll('__AETHER_TOKEN__', TOKEN)
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
      res.end(html)
    } catch {
      res.writeHead(404)
      res.end('Aether is not built. Run npm start.')
    }
  }
}

async function handleApi(req: http.IncomingMessage, res: http.ServerResponse) {
  const url = new URL(req.url || '/', 'http://localhost')
  if (req.method === 'GET' && url.pathname === '/api/health') {
    sendJson(res, 200, { ok: true, version: VERSION, sessions: sessionCount(), uptime: process.uptime() })
    return
  }
  if (req.method === 'GET' && url.pathname === '/api/meta') {
    sendJson(res, 200, {
      bootId: BOOT_ID,
      shell: defaultShell(),
      home: os.homedir(),
      platform: process.platform,
      version: VERSION,
    })
    return
  }
  if (req.method === 'GET' && url.pathname === '/api/state') {
    try {
      const raw = await fs.readFile(STATE_PATH, 'utf8')
      sendJson(res, 200, { state: JSON.parse(raw) })
    } catch {
      sendJson(res, 200, { state: null })
    }
    return
  }
  if (req.method === 'PUT' && url.pathname === '/api/state') {
    try {
      const raw = await readJsonBody(req, 2_000_000)
      const parsed = JSON.parse(raw.toString('utf8'))
      if (!parsed || typeof parsed !== 'object') throw new Error('invalid')
      await fs.mkdir(DATA, { recursive: true })
      const tmp = `${STATE_PATH}.${process.pid}.tmp`
      await fs.writeFile(tmp, JSON.stringify(parsed))
      await fs.rename(tmp, STATE_PATH)
      sendJson(res, 200, { ok: true })
    } catch (error) {
      sendJson(res, 400, { ok: false, message: error instanceof Error ? error.message : 'save failed' })
    }
    return
  }
  if (req.method === 'GET' && url.pathname === '/api/backgrounds') {
    try {
      const entries = await fs.readdir(BG_DIR)
      const images = entries
        .filter((name) => isSafeId(path.parse(name).name) || isSafeId(name.replace(/\.[a-z0-9]+$/i, '')))
        .map((name) => ({ id: name, name, url: `/api/backgrounds/${encodeURIComponent(name)}` }))
      sendJson(res, 200, { images })
    } catch {
      sendJson(res, 200, { images: [] })
    }
    return
  }
  if (url.pathname.startsWith('/api/backgrounds/')) {
    const id = decodeURIComponent(url.pathname.slice('/api/backgrounds/'.length))
    if (!isSafeId(path.parse(id).name) || id.includes('..') || id.includes('/') || id.includes('\\')) {
      sendJson(res, 400, { message: 'bad id' })
      return
    }
    const file = path.join(BG_DIR, id)
    if (req.method === 'GET') {
      try {
        await fs.stat(file)
        res.writeHead(200, {
          'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
          'cache-control': 'public, max-age=86400',
        })
        createReadStream(file).pipe(res)
      } catch {
        res.writeHead(404)
        res.end()
      }
      return
    }
    if (req.method === 'DELETE') {
      await fs.rm(file, { force: true })
      sendJson(res, 200, { ok: true })
      return
    }
  }
  if (req.method === 'POST' && url.pathname === '/api/backgrounds') {
    try {
      const body = await readJsonBody(req, 15_000_000)
      const type = String(req.headers['content-type'] || '')
      const ext = type.includes('png')
        ? '.png'
        : type.includes('webp')
          ? '.webp'
          : type.includes('gif')
            ? '.gif'
            : type.includes('jpeg') || type.includes('jpg')
              ? '.jpg'
              : sniffExt(body)
      if (!ext) {
        sendJson(res, 415, { message: 'Use a PNG, JPEG, WebP, or GIF.' })
        return
      }
      const id = `bg_${randomBytes(6).toString('hex')}${ext}`
      await fs.mkdir(BG_DIR, { recursive: true })
      await fs.writeFile(path.join(BG_DIR, id), body)
      const original = String(req.headers['x-filename'] || id)
      void original
      sendJson(res, 200, { id, url: `/api/backgrounds/${id}` })
    } catch (error) {
      sendJson(res, 400, { message: error instanceof Error ? error.message : 'upload failed' })
    }
    return
  }
  sendJson(res, 404, { message: 'not found' })
}

function sniffExt(body: Buffer) {
  if (body.length > 8 && body[0] === 0x89 && body[1] === 0x50) return '.png'
  if (body.length > 3 && body[0] === 0xff && body[1] === 0xd8) return '.jpg'
  if (body.length > 6 && body.subarray(0, 6).toString() === 'GIF87a') return '.gif'
  if (body.length > 6 && body.subarray(0, 6).toString() === 'GIF89a') return '.gif'
  if (body.length > 12 && body.subarray(0, 4).toString() === 'RIFF' && body.subarray(8, 12).toString() === 'WEBP') return '.webp'
  return null
}

function handleMessage(socket: Socket, raw: string) {
  let message: ClientMessage
  try {
    message = JSON.parse(raw) as ClientMessage
  } catch {
    return
  }
  if (!message || typeof message !== 'object' || typeof message.t !== 'string') return
  if (message.t === 'ping') {
    const pong: ServerMessage = { t: 'pong' }
    socket.send(JSON.stringify(pong))
    return
  }
  if (message.t === 'open') {
    if (typeof message.id !== 'string' || !isSafeId(message.id)) return
    openSession(socket, message)
    return
  }
  if (message.t === 'in') {
    if (typeof message.id === 'string' && typeof message.d === 'string') writeSession(message.id, message.d)
    return
  }
  if (message.t === 'resize') {
    if (typeof message.id === 'string') resizeSession(message.id, message.cols, message.rows)
    return
  }
  if (message.t === 'kill') {
    if (typeof message.id === 'string') killSession(message.id)
    return
  }
  if (message.t === 'detach') {
    if (typeof message.id === 'string') detachSession(socket, message.id)
  }
}

export type Running = {
  url: string
  token: string
  port: number
  close: () => Promise<void>
}

export async function startServer(options?: { port?: number; host?: string; dev?: boolean }): Promise<Running> {
  const host = options?.host ?? process.env.AETHER_HOST ?? '127.0.0.1'
  const preferred = options?.port ?? Number(process.env.PORT || process.env.AETHER_PORT || 41773)
  const dev = options?.dev ?? process.env.NODE_ENV !== 'production'
  await fs.mkdir(DATA, { recursive: true })

  let viteMiddlewares: ((req: http.IncomingMessage, res: http.ServerResponse, next: () => void) => void) | null = null
  let viteClose: (() => Promise<void>) | null = null

  const server = http.createServer((req, res) => {
    const url = req.url || '/'
    if (url.startsWith('/api/')) {
      void handleApi(req, res).catch((error) => {
        if (!res.headersSent) sendJson(res, 500, { message: error instanceof Error ? error.message : 'error' })
      })
      return
    }
    if (dev && viteMiddlewares) {
      viteMiddlewares(req, res, () => {
        res.statusCode = 404
        res.end()
      })
      return
    }
    void serveStatic(req, res)
  })

  if (dev) {
    const { createServer: createVite } = await import('vite')
    const vite = await createVite({
      root: ROOT,
      configFile: path.join(ROOT, 'vite.config.ts'),
      server: { middlewareMode: true, hmr: { server } },
      appType: 'spa',
    })
    viteMiddlewares = vite.middlewares
    viteClose = () => vite.close()
  }

  bindSend(
    (socket, message) => {
      if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message))
    },
    (socket, frame) => {
      if (socket.readyState === socket.OPEN) socket.send(frame)
    },
  )

  const wss = new WebSocketServer({ noServer: true, maxPayload: 8 * 1024 * 1024 })
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url || '/', 'http://localhost')
    if (url.pathname !== '/ws') return
    const token = url.searchParams.get('token') || ''
    const origin = req.headers.origin
    let originOk = true
    if (origin) {
      try {
        originOk = new URL(origin).host === req.headers.host
      } catch {
        originOk = false
      }
    }
    if (!safeEqual(token, TOKEN) || !originOk) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n')
      socket.destroy()
      return
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req)
    })
  })

  wss.on('connection', (ws) => {
    const socket = ws as Socket
    addSocket(socket)
    socket.on('message', (data, isBinary) => {
      if (isBinary) return
      handleMessage(socket, data.toString())
    })
    socket.on('close', () => removeSocket(socket))
  })

  const poll = setInterval(() => {
    pollCwds()
    resumeIfDrained()
  }, 1500)
  poll.unref()

  const port = await listen(server, host, preferred)
  const url = `http://${host}:${port}`

  async function close() {
    clearInterval(poll)
    killAll()
    await new Promise<void>((resolve) => wss.close(() => resolve()))
    if (viteClose) await viteClose()
    await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())))
  }

  return { url, token: TOKEN, port, close }
}

function listen(server: http.Server, host: string, start: number) {
  return new Promise<number>((resolve, reject) => {
    const attempt = (port: number) => {
      const onError = (error: NodeJS.ErrnoException) => {
        server.off('listening', onListen)
        if (error.code === 'EADDRINUSE' && port < start + 20) {
          attempt(port + 1)
          return
        }
        reject(error)
      }
      const onListen = () => {
        server.off('error', onError)
        const address = server.address()
        resolve(typeof address === 'object' && address ? address.port : port)
      }
      server.once('error', onError)
      server.once('listening', onListen)
      server.listen(port, host)
    }
    attempt(start)
  })
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isMain) {
  startServer()
    .then(({ url }) => {
      console.log(`\n  Aether  ${url}\n  A glass desk for every CLI. Shells stay on this machine.\n`)
    })
    .catch((error) => {
      console.error(error)
      process.exit(1)
    })
  const shutdown = () => {
    killAll()
    process.exit(0)
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
}
