export function prettyPath(cwd: string, home: string) {
  if (!cwd) return ''
  if (home && (cwd === home || cwd.startsWith(`${home}/`))) return `~${cwd.slice(home.length)}`
  return cwd
}

export function titleFromCommand(command: string) {
  const trimmed = command.trim()
  if (!trimmed) return 'Shell'
  const first = trimmed.split(/\s+/)[0] ?? trimmed
  const base = first.split(/[/\\]/).pop() || first
  return base.slice(0, 42)
}

export function fontStack(family: string) {
  if (family === 'System mono') return 'ui-monospace, "SF Mono", Menlo, Consolas, monospace'
  return `"${family}", "SF Mono", ui-monospace, Menlo, Consolas, monospace`
}

export const FONT_CHOICES = ['JetBrains Mono', 'SF Mono', 'Menlo', 'System mono', 'IBM Plex Mono', 'Geist Mono', 'Iosevka']

export function shQuote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`
}
