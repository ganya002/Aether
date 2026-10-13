export function uid(prefix: string) {
  const bytes = crypto.getRandomValues(new Uint8Array(6))
  let hex = ''
  for (const byte of bytes) hex += byte.toString(16).padStart(2, '0')
  return `${prefix}_${hex}`
}
