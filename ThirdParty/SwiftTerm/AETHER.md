# Aether changes to SwiftTerm

Search for `Aether` in the sources to find each one.

- `Sources/AetherSpawn`, `Pty.swift`, `Package.swift`: shells spawn with TCC disclaim, and the package skips Metal.
- `Terminal.swift`, `holdViewport`: keeps the view still while output arrives, as if the user had scrolled up. Copy mode sets it. `ensureCaretIsVisible` in `Mac/MacTerminalView.swift` respects it too.
- `Terminal.swift`, `hostLinkMatcher`: lets the host find links (file paths) before the built-in implicit detection, or rule a spot out.
- `Mac/MacTerminalView.swift`, `linkHighlightRange`: shows a pointing hand while a link is underlined.
