import { describe, expect, it } from 'vitest'
import { RingBuffer } from './ring'

describe('RingBuffer', () => {
  it('keeps the newest bytes when the cap is exceeded', () => {
    const ring = new RingBuffer(8)
    ring.push(Buffer.from('abcdefgh'))
    ring.push(Buffer.from('XYZ'))
    expect(ring.snapshot().toString()).toBe('defghXYZ')
    expect(ring.size).toBe(8)
  })

  it('slices a single oversized chunk', () => {
    const ring = new RingBuffer(4)
    ring.push(Buffer.from('hello'))
    expect(ring.snapshot().toString()).toBe('ello')
  })

  it('round-trips an empty buffer', () => {
    const ring = new RingBuffer()
    expect(ring.snapshot().length).toBe(0)
    ring.push(Buffer.alloc(0))
    expect(ring.size).toBe(0)
  })
})
