import { useState } from 'react'
import { chordLabel, SHORTCUT_GROUPS } from '../lib/keys'
import { defaultSettings, useStore } from '../lib/store'
import { useUi } from '../lib/ui'
import { AppearanceFields } from './Fields'

export function Settings() {
  const open = useUi((state) => state.settings)
  const settings = useStore((state) => state.settings)
  const profiles = useStore((state) => state.profiles)
  const patch = useStore((state) => state.patchSettings)
  const [name, setName] = useState('')
  const [command, setCommand] = useState('')
  const [cwd, setCwd] = useState('')

  if (!open) return null

  return (
    <div className="settings-backdrop" onMouseDown={() => useUi.getState().setSettings(false)}>
      <aside className="settings" onMouseDown={(event) => event.stopPropagation()} aria-label="Settings">
        <header>
          <strong>Settings</strong>
          <button onClick={() => useUi.getState().setSettings(false)} aria-label="Close">×</button>
        </header>
        <div className="settings-body">
          <section>
            <h3>Glass</h3>
            <AppearanceFields />
          </section>
          <section>
            <h3>Terminal</h3>
            <label className="slider">
              <span>Size<em>{settings.fontSize}px</em></span>
              <input type="range" min={10} max={24} step={1} value={settings.fontSize} onChange={(event) => patch({ fontSize: Number(event.target.value) })} />
            </label>
            <label className="slider">
              <span>Line height<em>{settings.lineHeight.toFixed(2)}</em></span>
              <input type="range" min={1} max={1.5} step={0.02} value={settings.lineHeight} onChange={(event) => patch({ lineHeight: Number(event.target.value) })} />
            </label>
            <label className="slider">
              <span>Letter spacing<em>{settings.letterSpacing}</em></span>
              <input type="range" min={-1} max={3} step={0.25} value={settings.letterSpacing} onChange={(event) => patch({ letterSpacing: Number(event.target.value) })} />
            </label>
            <label className="select-row">
              Cursor
              <select value={settings.cursorStyle} onChange={(event) => patch({ cursorStyle: event.target.value as typeof settings.cursorStyle })}>
                <option value="bar">Bar</option>
                <option value="block">Block</option>
                <option value="underline">Underline</option>
              </select>
            </label>
            <label className="select-row">
              Scrollback
              <select value={settings.scrollback} onChange={(event) => patch({ scrollback: Number(event.target.value) })}>
                <option value={2000}>2,000 lines</option>
                <option value={5000}>5,000 lines</option>
                <option value={20000}>20,000 lines</option>
                <option value={100000}>100,000 lines</option>
              </select>
            </label>
            <div className="toggles">
              <button className={settings.cursorBlink ? 'on' : ''} onClick={() => patch({ cursorBlink: !settings.cursorBlink })}>Blink</button>
              <button className={settings.smoothScroll ? 'on' : ''} onClick={() => patch({ smoothScroll: !settings.smoothScroll })}>Smooth scroll</button>
              <button className={settings.copyOnSelect ? 'on' : ''} onClick={() => patch({ copyOnSelect: !settings.copyOnSelect })}>Copy on select</button>
              <button className={settings.webgl ? 'on' : ''} onClick={() => patch({ webgl: !settings.webgl })}>WebGL</button>
              <button className={settings.bellVisual ? 'on' : ''} onClick={() => patch({ bellVisual: !settings.bellVisual })}>Visual bell</button>
              <button className={settings.bellSound ? 'on' : ''} onClick={() => patch({ bellSound: !settings.bellSound })}>Sound bell</button>
              <button className={settings.optionIsMeta ? 'on' : ''} onClick={() => patch({ optionIsMeta: !settings.optionIsMeta })}>Option is Meta</button>
            </div>
            <p className="quiet">WebGL is faster for one big pane and uses more GPU memory. Glass stays clearer with it off.</p>
          </section>
          <section>
            <h3>Profiles</h3>
            <ul className="profiles">
              {profiles.map((profile) => (
                <li key={profile.id}>
                  <div>
                    <strong>{profile.name}</strong>
                    <span>{profile.command}</span>
                  </div>
                  <button onClick={() => useStore.getState().removeProfile(profile.id)} aria-label={`Remove ${profile.name}`}>×</button>
                </li>
              ))}
            </ul>
            <form
              className="profile-form"
              onSubmit={(event) => {
                event.preventDefault()
                if (!name.trim() || !command.trim()) return
                useStore.getState().addProfile({ name: name.trim(), command: command.trim(), cwd: cwd.trim() })
                setName('')
                setCommand('')
                setCwd('')
              }}
            >
              <input data-field="aether" placeholder="Name" value={name} onChange={(event) => setName(event.target.value)} />
              <input data-field="aether" placeholder="Command" value={command} onChange={(event) => setCommand(event.target.value)} />
              <input data-field="aether" placeholder="Directory, optional" value={cwd} onChange={(event) => setCwd(event.target.value)} />
              <button className="primary" type="submit">Add profile</button>
            </form>
          </section>
          <section>
            <h3>Keys</h3>
            {SHORTCUT_GROUPS.map((group) => (
              <div key={group.group} className="keys">
                <h4>{group.group}</h4>
                {group.items.map((item) => (
                  <div key={item.id}>
                    <span>{item.label}</span>
                    <kbd>{item.key === '←' ? chordLabel('ArrowLeft', { shift: item.shift, alt: item.alt }).replace('←', '←→↑↓') : chordLabel(item.key, { shift: item.shift, alt: item.alt })}</kbd>
                  </div>
                ))}
              </div>
            ))}
          </section>
          <section>
            <h3>Desk</h3>
            <div className="toggles">
              <button
                onClick={() => {
                  const blob = new Blob([useStore.getState().exportDesk()], { type: 'application/json' })
                  const url = URL.createObjectURL(blob)
                  const link = document.createElement('a')
                  link.href = url
                  link.download = 'aether-desk.json'
                  link.click()
                  URL.revokeObjectURL(url)
                }}
              >
                Export
              </button>
              <label className="file">
                Import
                <input
                  type="file"
                  accept="application/json"
                  hidden
                  onChange={async (event) => {
                    const file = event.target.files?.[0]
                    if (!file) return
                    useStore.getState().importDesk(await file.text())
                    event.target.value = ''
                  }}
                />
              </label>
              <button onClick={() => useStore.getState().patchSettings(defaultSettings(useStore.getState().platform))}>
                Reset look
              </button>
            </div>
          </section>
        </div>
      </aside>
    </div>
  )
}
