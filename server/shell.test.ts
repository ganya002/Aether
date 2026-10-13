import { describe, expect, it } from 'vitest'
import { shellEnv, shQuote, spawnSpec } from './shell'

describe('spawnSpec', () => {
  it('starts a login shell with no command', () => {
    expect(spawnSpec('/bin/zsh', null, 'darwin')).toEqual({ file: '/bin/zsh', args: ['-l'] })
    expect(spawnSpec('/usr/bin/fish', null, 'linux').args).toEqual(['-l'])
  })

  it('runs a command and then returns to the login shell', () => {
    const spec = spawnSpec('/bin/bash', `echo 'hi'`, 'linux')
    expect(spec.args[0]).toBe('-lic')
    expect(spec.args[1]).toContain(`echo 'hi'`)
    expect(spec.args[1]).toContain(`exec '/bin/bash' -l`)
  })

  it('quotes paths with spaces and quotes', () => {
    expect(shQuote(`/Users/me/O'Hara`)).toBe(`'/Users/me/O'\\''Hara'`)
    const spec = spawnSpec('/bin/zsh', 'htop', 'darwin')
    expect(spec.args[1]).toContain(`exec '/bin/zsh' -l`)
  })

  it('does not leak npm lifecycle variables into the shell', () => {
    const previous = process.env.npm_config_prefix
    process.env.npm_config_prefix = '/'
    const env = shellEnv('/bin/bash')
    expect(env.npm_config_prefix).toBeUndefined()
    expect(env.TERM).toBe('xterm-256color')
    expect(env.COLORTERM).toBe('truecolor')
    if (previous === undefined) delete process.env.npm_config_prefix
    else process.env.npm_config_prefix = previous
  })

  it('uses PowerShell flags on Windows', () => {
    expect(spawnSpec('powershell.exe', 'Get-Date', 'win32').args).toEqual([
      '-NoLogo',
      '-NoExit',
      '-Command',
      'Get-Date',
    ])
  })
})
