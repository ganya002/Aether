export const VERSION = '1.0.0'

export type SpawnMode = 'no' | 'if-missing' | 'yes'

export type ClientMessage =
  | {
      t: 'open'
      id: string
      cols: number
      rows: number
      cwd?: string
      command?: string | null
      spawn: SpawnMode
    }
  | { t: 'in'; id: string; d: string }
  | { t: 'resize'; id: string; cols: number; rows: number }
  | { t: 'kill'; id: string }
  | { t: 'detach'; id: string }
  | { t: 'ping' }

export type ServerMessage =
  | {
      t: 'ready'
      id: string
      pid: number
      cwd: string
      shell: string
      alive: boolean
    }
  | { t: 'replay-begin'; id: string }
  | { t: 'replay-end'; id: string }
  | { t: 'exit'; id: string; code: number; signal?: number }
  | { t: 'cwd'; id: string; cwd: string }
  | { t: 'error'; id?: string; message: string }
  | { t: 'pong' }

export type Meta = {
  bootId: string
  shell: string
  home: string
  platform: NodeJS.Platform
  version: string
}
