/** Subsequence score. Higher is a tighter match. Null means no match. */
export function fuzzyScore(query: string, text: string): number | null {
  const q = query.trim().toLowerCase()
  const t = text.toLowerCase()
  if (!q) return 1
  let qi = 0
  let score = 0
  let streak = 0
  let prev = -2
  for (let i = 0; i < t.length && qi < q.length; i++) {
    if (t[i] !== q[qi]) continue
    score += 8
    if (i === prev + 1) {
      streak += 1
      score += streak * 6
    } else {
      streak = 0
    }
    if (i === 0 || /[\s/_.-]/.test(t[i - 1] ?? '')) score += 12
    prev = i
    qi += 1
  }
  if (qi < q.length) return null
  return score - t.length * 0.12
}

export function fuzzyRank<T>(query: string, items: T[], text: (item: T) => string): T[] {
  const ranked = items
    .map((item) => ({ item, score: fuzzyScore(query, text(item)) }))
    .filter((row): row is { item: T; score: number } => row.score !== null)
  ranked.sort((a, b) => b.score - a.score)
  return ranked.map((row) => row.item)
}
