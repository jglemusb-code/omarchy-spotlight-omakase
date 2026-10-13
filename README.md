# Spotlight Omakase

A Spotlight-style universal search and quick launcher for the Omarchy shell.
It uses the same `[menu]` theme tokens as the Omarchy menu, so it follows
whatever theme you switch to.

## Install

```bash
omarchy plugin add https://github.com/jglemusb-code/omarchy-spotlight-omakase.git --enable --yes
```

Then add a keybinding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + D", "Spotlight search", "omarchy-shell shell toggle jglemusb.spotlight")
```

Requires `fd` (file search), `wl-clipboard` (copying results), and `gtk-launch`
(from `gtk3`, used to launch apps) — all present on a stock Omarchy install.

## Usage

Open it with **Super + D**, or from a script:

```bash
omarchy-shell shell toggle jglemusb.spotlight
omarchy-shell shell summon jglemusb.spotlight '{"query":"firefox"}'
```

## What it searches

| Section         | Source                                              | Enter does            |
|-----------------|-----------------------------------------------------|-----------------------|
| Top Hit         | Best match across everything below                  | —                     |
| Calculator      | Scientific math in the prompt (see below)           | Copies the result     |
| Applications    | Desktop entries (fuzzy: `vsc` → Visual Studio Code) | Launches the app      |
| Open Windows    | `hyprctl clients`                                   | Focuses the window    |
| Omarchy         | Every action in the Omarchy menu + your extensions  | Runs the action       |
| Files & Folders | `fd` over your home folder (skips Games, Wine)      | Opens it              |
| Web             | Anything you type; prefix `?` for web only          | Google search         |

With an empty prompt it shows your recently used items and open windows.
Items you pick often rank higher (stored in
`~/.local/state/omarchy-spotlight-usage.json`).

## Scientific calculator

Type math anywhere (`2+2`, `sin(30)`, `5!`) or start with `=` for calculator-only
mode, which also allows `sin 30` without parentheses. `=` on its own shows your
history (or a function reference when it's empty).

- Trig `sin cos tan asin acos atan atan2 sec csc cot`, hyperbolic `sinh … atanh`
- Powers & logs: `x^y`, `sqrt`, `cbrt`, `root(x,n)`, `exp`, `ln`, `log`, `log(x,b)`, `log2`
- Counting: `5!` (decimals via gamma), `nCr(n,k)`, `nPr(n,k)`, `gcd`, `lcm`
- Rounding: `round(x,digits)`, `floor`, `ceil`, `trunc`, `abs`, `sign`, `a mod b`
- Lists: `min`, `max`, `sum`, `avg`, `hypot`
- Constants `pi π e tau phi`, `ans` (last result), `50%` = 0.5, `200*15%` = 30
- Implicit multiplication `2pi`, `3(4+1)`; bases `0xFF`, `0b101`, `0o17` (integer results show hex/bin/oct)
- **Ctrl+D** toggles DEG/RAD · **Enter** copies · **Ctrl+Enter** keeps calculating with the result

Expressions are parsed by a small built-in parser — nothing you type is run as code.
Mode, `ans`, and history live in `~/.local/state/omarchy-spotlight-calc.json`.

## Keys

`↑/↓` or `Ctrl+J/K` move · `Tab` / `Shift+Tab` jump between sections ·
`Enter` open · `Ctrl+Enter` reveal a file in the file manager ·
`Ctrl+V` paste · `Ctrl+U` clear · `Esc` clear, then close.

## Notes

The Omarchy shell doesn't always hot-reload this plugin after edits; run
`omarchy restart shell` to pick up changes.
