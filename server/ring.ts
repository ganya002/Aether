/** Capped binary ring. Drops the oldest bytes first. */
export class RingBuffer {
  private chunks: Buffer[] = []
  private bytes = 0

  constructor(private max = 1024 * 1024) {}

  push(data: Buffer) {
    if (data.length === 0) return
    if (data.length >= this.max) {
      this.chunks = [data.subarray(data.length - this.max)]
      this.bytes = this.max
      return
    }
    this.chunks.push(data)
    this.bytes += data.length
    while (this.bytes > this.max && this.chunks.length) {
      const overflow = this.bytes - this.max
      const head = this.chunks[0]!
      if (head.length <= overflow) {
        this.chunks.shift()
        this.bytes -= head.length
        continue
      }
      this.chunks[0] = head.subarray(overflow)
      this.bytes -= overflow
      break
    }
  }

  snapshot(): Buffer {
    if (this.chunks.length === 0) return Buffer.alloc(0)
    if (this.chunks.length === 1) return this.chunks[0]!
    return Buffer.concat(this.chunks, this.bytes)
  }

  get size() {
    return this.bytes
  }

  clear() {
    this.chunks = []
    this.bytes = 0
  }
}
