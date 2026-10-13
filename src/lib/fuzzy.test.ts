import { describe, expect, it } from 'vitest'
import { fuzzyRank, fuzzyScore } from './fuzzy'

describe('fuzzyScore', () => {
  it('rejects misses and rewards consecutive and boundary matches', () => {
    expect(fuzzyScore('xyz', 'new terminal')).toBeNull()
    expect(fuzzyScore('', 'anything')).toBe(1)
    const tight = fuzzyScore('term', 'New terminal')!
    const loose = fuzzyScore('term', 't e r m extra words here')!
    expect(tight).toBeGreaterThan(loose)
    expect(fuzzyScore('nt', 'New terminal')).not.toBeNull()
  })

  it('ranks titles with the query near the start first', () => {
    const ranked = fuzzyRank('split', [
      { title: 'Broadcast input' },
      { title: 'Split right' },
      { title: 'A very long name that eventually says split' },
    ], (item) => item.title)
    expect(ranked[0]?.title).toBe('Split right')
  })
})
