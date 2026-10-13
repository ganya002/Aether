export function Mark({ size = 16 }: { size?: number }) {
  return (
    <svg className="mark" width={size} height={size} viewBox="0 0 32 32" aria-hidden>
      <rect x="1.4" y="1.4" width="29.2" height="29.2" rx="7" fill="none" stroke="currentColor" strokeWidth="1.6" />
      <path d="M15.5 7.5v17M15.5 16.2H24" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  )
}
