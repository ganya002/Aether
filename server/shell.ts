import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

export function shQuote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`
}

export function defaultShell() {
  if (process.platform === 'win32') {
    return process.env.COMSPEC || 'powershell.exe'
  }
  const fromEnv = process.env.SHELL
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv
  if (fs.existsSync('/bin/zsh')) return '/bin/zsh'
  if (fs.existsSync('/bin/bash')) return '/bin/bash'
  return 'bash'
}

export function safeCwd(cwd: string | undefined, home = os.homedir()) {
  if (cwd && fs.existsSync(cwd)) {
    try {
      if (fs.statSync(cwd).isDirectory()) return cwd
    } catch {
      /* fall through */
    }
  }
  return home
}

function baseName(shell: string) {
  return path.basename(shell).toLowerCase().replace(/\.exe$/, '')
}

export function spawnSpec(shell: string, command: string | null, platform = process.platform) {
  const file = shell
  const base = baseName(shell)
  if (platform === 'win32') {
    if (!command) return { file, args: ['-NoLogo'] }
    return { file, args: ['-NoLogo', '-NoExit', '-Command', command] }
  }
  if (!command) {
    if (base === 'nu' || base === 'nushell') return { file, args: [] as string[] }
    return { file, args: ['-l'] }
  }
  const script = `${command}\nexec ${shQuote(shell)} -l\n`
  if (base === 'fish') return { file, args: ['-l', '-c', script] }
  if (base === 'nu' || base === 'nushell') return { file, args: ['-c', command] }
  return { file, args: ['-lic', script] }
}

export function shellEnv(shell: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env }
  env.TERM = 'xterm-256color'
  env.COLORTERM = 'truecolor'
  env.TERM_PROGRAM = 'Aether'
  env.TERM_PROGRAM_VERSION = '1.0.0'
  env.AETHER = '1'
  if (!env.LANG) env.LANG = 'en_US.UTF-8'
  if (!env.SHELL && process.platform !== 'win32') env.SHELL = shell
  delete env.NODE_CHANNEL
  delete env.NODE_OPTIONS
  for (const key of Object.keys(env)) {
    if (key.startsWith('npm_')) delete env[key]
  }
  return env
}
