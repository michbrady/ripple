# Ripple design system

Ripple keeps Apple's look. Only the accent is a token. Add each token file when a story first needs it, and list it here.

## Accent (`UI/Theme.swift`)
- `ThemeStore.defaultID` is `"system"` and `ThemeStore.brand` is nil: Ripple follows the accent color the person set for their Mac.
- Use `.tint` or `Palette.accent` for fills and selection. Use `Palette.accentText` for accent-colored text and `Palette.onAccent` for text on an accent fill.
- Never hard-code a hex color. The Cover is the only hero color in the window.
- One primary button per page: Rip, or Burn in Burn mode.

## Spacing (`UI/Grid.swift`)
- Use `Space` on the 4 pt grid. Mark custom pages with `.gridArea` and `.gridProbe`.

## Status colors (add to `UI/Surfaces.swift` with the first status story)
- Track status uses an icon and a word, never color alone: waiting, ripping, done, Needs Attention.
- One warning color, for Needs Attention and over-capacity burns.

## Radius (`UI/Radius.swift`, add with the album header)
- `sm 8` controls, `md 12` cards. The Cover uses `sm`. Inner radius = outer radius minus inset.

## Motion (`UI/Motion.swift`, add with progress rows)
- Every animation goes through `Motion`, so Reduce Motion applies. Progress bars update without easing. Numbers use `.contentTransition(.numericText())`.
- The track list does not animate when a lookup fills in titles. Speed wins.

## Controls
- Use system buttons, toggles, tables, and the folder chooser. Rebuild none of them from shapes.
- Icon-only buttons (Eject, Retry) carry `.help` text that starts with a verb and names the shortcut.

## Words
- Names come from `docs/GLOSSARY.md`. Title Case for buttons and menus, sentence case for messages.
