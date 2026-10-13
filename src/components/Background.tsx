import { useEffect, useState } from 'react'
import { grainUrl, presetImage } from '../lib/backgrounds'
import { useStore } from '../lib/store'

export function Background() {
  const background = useStore((state) => state.settings.background)
  const uploads = useStore((state) => state.uploads)
  const animate = useStore((state) => state.settings.bgAnimate && !state.settings.performance)
  const grain = useStore((state) => state.settings.grain && !state.settings.performance)
  const blur = useStore((state) => (state.settings.performance ? 0 : state.settings.bgBlur))
  const [image, setImage] = useState<string | null>(null)
  const [noise, setNoise] = useState('')

  useEffect(() => {
    setNoise(grainUrl())
  }, [])

  useEffect(() => {
    if (background.kind !== 'preset') {
      setImage(null)
      return
    }
    let cancel = false
    const frame = requestAnimationFrame(() => {
      const url = presetImage(background.id)
      if (!cancel) setImage(url)
    })
    return () => {
      cancel = true
      cancelAnimationFrame(frame)
    }
  }, [background])

  const photo = background.kind === 'image' ? uploads.find((item) => item.id === background.id)?.url : null
  const presetClass = background.kind === 'preset' ? `bg-${background.id}` : ''
  const color = background.kind === 'color' ? background.color : undefined

  return (
    <div className="wallpaper" aria-hidden>
      <div className={`bg-base ${presetClass}`} style={color ? { background: color } : photo ? { backgroundImage: `url(${photo})` } : undefined} />
      {image ? <div className={`bg-media${animate ? ' drift' : ''}`} style={{ backgroundImage: `url(${image})`, filter: blur ? `blur(${blur}px)` : undefined }} /> : null}
      {photo && blur ? <div className="bg-media" style={{ backgroundImage: `url(${photo})`, filter: `blur(${blur}px)` }} /> : null}
      <div className="bg-dim" />
      <div className="bg-vignette" />
      {grain && noise ? <div className="bg-grain" style={{ backgroundImage: `url(${noise})` }} /> : null}
    </div>
  )
}
