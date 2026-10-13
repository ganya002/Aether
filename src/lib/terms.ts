export type TermApi = {
  focus: () => void
  clear: () => void
  selectAll: () => void
  copy: () => Promise<void>
  paste: () => Promise<void>
  find: (query: string, dir: 'next' | 'prev') => boolean
  hasSelection: () => boolean
}

const apis = new Map<string, TermApi>()

export function registerTerm(id: string, api: TermApi) {
  apis.set(id, api)
  return () => {
    if (apis.get(id) === api) apis.delete(id)
  }
}

export function termApi(id: string | null | undefined) {
  if (!id) return undefined
  return apis.get(id)
}
