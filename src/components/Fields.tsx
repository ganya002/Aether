import { PRESETS } from '../lib/backgrounds'
import { FONT_CHOICES } from '../lib/format'
import { useStore, type BackgroundSetting } from '../lib/store'
import { themes } from '../lib/themes'
import { toast } from '../lib/ui'

function Slider({
  label,
  value,
  min,
  max,
  step,
  display,
  onChange,
}: {
  label: string
  value: number
  min: number
  max: number
  step: number
  display: string
  onChange: (value: number) => void
}) {
  return (
    <label className="slider">
      <span>
        {label}
        <em>{display}</em>
      </span>
      <input type="range" min={min} max={max} step={step} value={value} onChange={(event) => onChange(Number(event.target.value))} />
    </label>
  )
}

export function AppearanceFields({ compact = false }: { compact?: boolean }) {
  const settings = useStore((state) => state.settings)
  const uploads = useStore((state) => state.uploads)
  const patch = useStore((state) => state.patchSettings)
  const choose = useStore((state) => state.chooseBackground)
  const material = settings.blur === 0 && settings.scrim > 0.85 ? 'solid' : settings.scrim < 0.45 ? 'clear' : 'frosted'
  const activePreset = settings.background.kind === 'preset' ? settings.background.id : ''

  const upload = async (file: File) => {
    const response = await fetch('/api/backgrounds', {
      method: 'POST',
      headers: { 'content-type': file.type || 'application/octet-stream', 'x-filename': file.name },
      body: file,
    })
    if (!response.ok) {
      toast('That image could not be used.')
      return
    }
    const json = (await response.json()) as { id: string; url: string }
    const store = useStore.getState()
    store.setUploads([...store.uploads.filter((item) => item.id !== json.id), { id: json.id, url: json.url }])
    store.chooseBackground({ kind: 'image', id: json.id })
  }

  return (
    <div className="fields">
      <div className="swatches" role="listbox" aria-label="Theme">
        {themes.map((theme) => (
          <button
            key={theme.id}
            className={settings.themeId === theme.id ? 'on' : ''}
            style={{ background: `rgb(${theme.scrim})`, color: theme.fg }}
            onClick={() => patch({ themeId: theme.id, accent: null })}
          >
            {theme.name}
          </button>
        ))}
      </div>
      <div className="thumbs" aria-label="Wallpaper">
        {PRESETS.map((preset) => (
          <button
            key={preset.id}
            className={`thumb bg-${preset.id}${activePreset === preset.id ? ' on' : ''}`}
            onClick={() => choose({ kind: 'preset', id: preset.id })}
            title={preset.name}
          >
            <span>{preset.name}</span>
          </button>
        ))}
        {uploads.map((image) => (
          <button
            key={image.id}
            className={`thumb photo${settings.background.kind === 'image' && settings.background.id === image.id ? ' on' : ''}`}
            style={{ backgroundImage: `url(${image.url})` }}
            onClick={() => choose({ kind: 'image', id: image.id } satisfies BackgroundSetting)}
          />
        ))}
        <label className="thumb add">
          Upload
          <input
            type="file"
            accept="image/png,image/jpeg,image/webp,image/gif"
            hidden
            onChange={(event) => {
              const file = event.target.files?.[0]
              if (file) void upload(file)
              event.target.value = ''
            }}
          />
        </label>
      </div>
      <div className="seg" role="radiogroup" aria-label="Glass">
        {(['clear', 'frosted', 'solid'] as const).map((item) => (
          <button key={item} className={material === item ? 'on' : ''} onClick={() => useStore.getState().setMaterial(item)}>
            {item}
          </button>
        ))}
      </div>
      <Slider label="Tint" min={0.15} max={0.96} step={0.01} value={settings.scrim} display={`${Math.round(settings.scrim * 100)}%`} onChange={(scrim) => patch({ scrim })} />
      <Slider label="Blur" min={0} max={40} step={1} value={settings.blur} display={settings.blur ? `${settings.blur}px` : 'Off'} onChange={(blur) => patch({ blur })} />
      <Slider label="Gap" min={0} max={28} step={1} value={settings.gap} display={`${settings.gap}px`} onChange={(gap) => patch({ gap })} />
      <Slider label="Radius" min={0} max={28} step={1} value={settings.radius} display={`${settings.radius}px`} onChange={(radius) => patch({ radius })} />
      {!compact ? (
        <>
          <Slider label="Frame" min={6} max={40} step={1} value={settings.pad} display={`${settings.pad}px`} onChange={(pad) => patch({ pad })} />
          <Slider label="Wallpaper blur" min={0} max={24} step={1} value={settings.bgBlur} display={settings.bgBlur ? `${settings.bgBlur}px` : 'Off'} onChange={(bgBlur) => patch({ bgBlur })} />
          <Slider label="Dim" min={0} max={0.7} step={0.01} value={settings.bgDim} display={`${Math.round(settings.bgDim * 100)}%`} onChange={(bgDim) => patch({ bgDim })} />
          <label className="color-row">
            Solid color
            <input
              type="color"
              value={settings.background.kind === 'color' ? settings.background.color : '#101820'}
              onChange={(event) => choose({ kind: 'color', color: event.target.value })}
            />
          </label>
        </>
      ) : null}
      <div className="toggles">
        <button className={settings.bgAnimate ? 'on' : ''} onClick={() => patch({ bgAnimate: !settings.bgAnimate })}>Drift</button>
        <button className={settings.grain ? 'on' : ''} onClick={() => patch({ grain: !settings.grain })}>Grain</button>
        <button className={settings.performance ? 'on' : ''} onClick={() => patch({ performance: !settings.performance })}>Low power</button>
      </div>
      {!compact ? (
        <label className="select-row">
          Type
          <select value={settings.fontFamily} onChange={(event) => patch({ fontFamily: event.target.value })}>
            {FONT_CHOICES.map((font) => (
              <option key={font}>{font}</option>
            ))}
          </select>
        </label>
      ) : null}
    </div>
  )
}
