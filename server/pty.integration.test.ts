import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import WebSocket from 'ws'
import type { Running } from './index'

process.env.AETHER_DATA = mkdtempSync(path.join(tmpdir(), 'aether-test-'))

let running: Running

beforeAll(async () => {
  const { startServer } = await import('./index')
  running = await startServer({ port: 0, host: '127.0.0.1', dev: false })
})

afterAll(async () => {
  await running?.close()
})

function connect(token = running.token) {
  const ws = new WebSocket(`${running.url.replace('http', 'ws')}/ws?token=${encodeURIComponent(token)}`)
  const text: Array<{ t?: string; id?: string }> = []
  const bin: Buffer[] = []
  const ready = new Promise<void>((resolve, reject) => {
    const fail = (error: Error) => reject(error)
    ws.once('open', () => resolve())
    ws.once('error', fail)
    ws.once('unexpected-response', () => fail(new Error('unauthorized')))
  })
  ws.on('message', (data, isBinary) => {
    if (isBinary) bin.push(Buffer.from(data as Buffer))
    else text.push(JSON.parse(data.toString()))
  })
  return { ws, text, bin, ready }
}

function payload(frame: Buffer) {
  const idLen = frame[1] ?? 0
  return frame.subarray(2 + idLen).toString('utf8')
}

async function waitFor(read: () => boolean, ms = 6000) {
  const start = Date.now()
  while (Date.now() - start < ms) {
    if (read()) return
    await new Promise((resolve) => setTimeout(resolve, 30))
  }
  throw new Error('timed out')
}

describe('pty server', () => {
  it('rejects a websocket without the local token', async () => {
    const client = connect('not-the-token')
    await expect(client.ready).rejects.toThrow()
    client.ws.close()
  })

  it('runs a command, keeps the shell, and replays scrollback', async () => {
    const client = connect()
    await client.ready
    client.ws.send(JSON.stringify({
      t: 'open',
      id: 'p_smoke1',
      cols: 80,
      rows: 24,
      cwd: process.cwd(),
      command: "printf 'SMOKE_OK\\n'",
      spawn: 'if-missing',
    }))
    await waitFor(() => client.bin.some((frame) => payload(frame).includes('SMOKE_OK')))
    client.ws.send(JSON.stringify({ t: 'in', id: 'p_smoke1', d: "printf 'AFTER\\n'\n" }))
    await waitFor(() => client.bin.some((frame) => payload(frame).includes('AFTER')))
    client.ws.send(JSON.stringify({ t: 'resize', id: 'p_smoke1', cols: 110, rows: 32 }))

    const second = connect()
    await second.ready
    second.ws.send(JSON.stringify({
      t: 'open',
      id: 'p_smoke1',
      cols: 80,
      rows: 24,
      spawn: 'if-missing',
    }))
    await waitFor(() => second.bin.some((frame) => payload(frame).includes('SMOKE_OK')))
    expect(second.text.some((message) => message.t === 'replay-begin')).toBe(true)

    client.ws.send(JSON.stringify({ t: 'kill', id: 'p_smoke1' }))
    client.ws.close()
    second.ws.close()
  })

  it('serves health', async () => {
    const health = await fetch(`${running.url}/api/health`)
    expect(health.status).toBe(200)
    const body = (await health.json()) as { ok: boolean; version: string }
    expect(body.ok).toBe(true)
    expect(body.version).toBeTruthy()
  })
})
