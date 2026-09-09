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
- 🌧️ Gentle vertical falling stars with a fading comet trail
- 🌟 Rare **golden shooting stars** that streak diagonally across the whole
  window, fast, with their own fading gold tail
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
  falling_stars  = 2,      -- gentle vertical falling stars alive per window at once
  fps            = 10,     -- animation ticks per second

  twinkle_chars  = { "·", "‧", "✦", "✧", "✩", "★", "✩", "✧", "✦", "‧", "·" },
  colors         = { "#eaeaea", "#ffe9a8", "#a8d4ff", "#ffc9de", "#c9ffb0", "#d8c2ff" },

  falling_char   = "★",
  falling_color  = "#ffffff",
  trail_chars    = { "·", "✦" },
  fall_speed     = 2,       -- lower = falls faster (ticks per row moved)
  trail_length   = 3,       -- how many glyphs long the comet trail is

  -- Golden diagonal shooting star -- rare, fast, cross-screen streak.
  shooting_stars        = 1,        -- max concurrent per window
  shooting_spawn_chance = 0.015,    -- keep this low for rarity
  shooting_char          = "★",
  shooting_color         = "#ffd700",
  shooting_trail_chars   = { "·", "✧", "✦" },
  shooting_trail_length  = 4,
  shooting_move_every    = 1,       -- 1 = moves every tick (fastest)
  shooting_speed_col     = { 2, 3 }, -- random sideways step per move

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

### The golden shooting star

This is a separate, rarer effect from the gentle vertical falling stars:

- Enters from the left or right edge near the top of the visible area and
  streaks diagonally (down + sideways every tick) all the way across the
  window, exiting off the opposite side, off the bottom, or into the blank
  canvas below your file.
- Rendered in gold (`shooting_color`, default `#ffd700`) with its own fading
  gold tail (`StarfallShootingHead` / `StarfallShootingTrail1-3`).
- Capped at `shooting_stars` concurrent (default `1`) and gated by a low
  per-tick `shooting_spawn_chance` (default `0.015`, i.e. rare), so it won't
  show up constantly like the ambient/falling stars.
- Still respects the same text-avoidance rules -- if its path would cross
  over a character, the streak ends cleanly rather than jumping around it.

Want it more/less often? Tune `shooting_spawn_chance` up or down. Want it
faster/slower? Tune `shooting_speed_col` (bigger range = steeper, faster
diagonal) or `shooting_move_every` (higher = slower).

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

## Filling the *whole* window, even for a 3-line file

Neovim can only attach decorations to real buffer lines, so a naive
implementation only twinkles across however many lines your file has — a
20-line file gets 20 lines of sky, a 3-line file gets 3. That's not what
"twinkle everywhere while coding" means.

To fix this, starfall.nvim renders the blank `~` area below your last line
as one shared virtual canvas (via `virt_lines`), sized to exactly fill the
rest of the window. Ambient stars are spawned across real lines *and* that
canvas proportionally, and falling stars fall straight through your code and
keep going into the blank space below it, all the way to the bottom of the
window — so even a one-line file gets a full screen of sky.

## License

MIT
