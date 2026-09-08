# ✨ starfall.nvim

A tiny, beautiful ambient animation plugin for Neovim: soft twinkling stars
drift and shimmer in the empty space around your code, and shooting stars
occasionally streak down the window leaving a fading trail.

**Stars never sit on top of your text.** Every spawn/movement is checked
against the actual buffer content for each visible line — stars only appear
in indentation whitespace, blank lines, or the empty margin past the end of
a line, with a configurable safety margin. As you type, resize, or scroll,
placement is re-checked live.

- 🌌 Ambient twinkling stars that fade in/out through a glyph + color ramp
- 🌠 Falling "shooting stars" with a fading 3-glyph comet trail
- 🪟 Works across every normal split/window in the current tab at once
- 🚫 Automatically skips pickers, trees, dashboards, help, etc.
- ⚡ Pure `vim.uv`/`vim.loop` timer + extmarks — no external dependencies
- 🧩 Two simple commands: `:StarfallStart` / `:StarfallStop` (plus `:StarfallToggle`)

## Requirements

- Neovim >= 0.9 (uses `nvim_buf_set_extmark` with `virt_text_win_col`)

## Installation (lazy.nvim)

```lua
{
  "yourname/starfall.nvim",
  cmd = { "StarfallStart", "StarfallStop", "StarfallToggle" },
  opts = {
    -- see "Configuration" below; {} for all defaults
  },
}
```

Because the plugin is registered with `cmd = {...}`, lazy.nvim will lazy-load
it automatically the first time you run one of the commands — nothing is
loaded at startup.

If you'd rather call `setup()` yourself:

```lua
{
  "yourname/starfall.nvim",
  cmd = { "StarfallStart", "StarfallStop", "StarfallToggle" },
  config = function()
    require("starfall").setup({
      density = 20,
      falling_stars = 3,
    })
  end,
}
```

### Local / manual install (no git repo yet)

If you're trying this out from a local folder before pushing it anywhere:

```lua
{
  dir = "~/path/to/starfall.nvim",
  cmd = { "StarfallStart", "StarfallStop", "StarfallToggle" },
  opts = {},
}
```

## Usage

| Command            | Effect                                          |
|---------------------|--------------------------------------------------|
| `:StarfallStart`    | Start the animation in all eligible windows      |
| `:StarfallStop`     | Stop the animation and clear every star instantly|
| `:StarfallToggle`   | Convenience: start if stopped, stop if running   |

Map them if you like:

```lua
vim.keymap.set("n", "<leader>ss", "<cmd>StarfallToggle<CR>", { desc = "Toggle starfall" })
```

## Configuration

All fields are optional; pass only what you want to override to `setup()` /
`opts`.

```lua
require("starfall").setup({
  density        = 16,     -- ambient stars alive per window at once
  falling_stars  = 2,      -- shooting stars alive per window at once
  fps            = 10,     -- animation ticks per second

  twinkle_chars  = { "·", "‧", "✦", "✧", "✩", "★", "✩", "✧", "✦", "‧", "·" },
  colors         = { "#eaeaea", "#ffe9a8", "#a8d4ff", "#ffc9de", "#c9ffb0", "#d8c2ff" },

  falling_char   = "★",
  falling_color  = "#ffffff",
  trail_chars    = { "·", "✦" },
  fall_speed     = 2,       -- lower = falls faster (ticks per row moved)
  trail_length   = 3,       -- how many glyphs long the comet trail is

  min_life       = 30,      -- ambient star minimum lifetime, in ticks
  max_life       = 70,

  twinkle_spawn_chance = 0.5,
  falling_spawn_chance = 0.06,

  margin = 2,               -- min blank columns kept clear around real text

  ignore_filetypes = {
    "TelescopePrompt", "TelescopeResults", "NvimTree", "neo-tree",
    "lazy", "mason", "help", "dashboard", "alpha", "starter",
    "notify", "noice", "trouble", "qf", "fugitive",
  },
})
```

### Tuning the vibe

- Want a calmer sky? Lower `density`/`falling_stars` and raise `min_life`/`max_life`.
- Want a busier, more magical field? Raise `density`, lower `fall_speed` isn't
  what you want for speed — instead raise `falling_spawn_chance` and lower
  `fall_speed` for faster comets.
- Colors are just hex strings fed straight into highlight groups
  (`StarfallColor1`, `StarfallColor2`, ...), so they'll respect `termguicolors`.

## How it avoids your text

For every visible buffer line, the plugin computes:

1. The leading-whitespace width (columns 0 → indent) — safe if wider than `margin`.
2. The blank area past the last visible character on that line — safe if it
   leaves at least `margin` columns before the window edge.
3. Fully blank lines are entirely safe.

Stars are only ever placed inside these ranges, recalculated every animation
tick, so live edits, scrolling, and resizing are all handled automatically —
a star will quietly step aside (or gracefully despawn) rather than ever
covering a character of your code.

## License

MIT
