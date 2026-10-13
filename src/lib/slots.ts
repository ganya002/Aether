const slots = new Map<string, HTMLElement>()
const listeners = new Set<() => void>()

export function registerSlot(id: string, el: HTMLElement) {
  slots.set(id, el)
  for (const listener of listeners) listener()
  return () => {
    if (slots.get(id) !== el) return
    slots.delete(id)
    for (const listener of listeners) listener()
  }
}

export function getSlot(id: string) {
  return slots.get(id) ?? null
}

export function subscribeSlots(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
