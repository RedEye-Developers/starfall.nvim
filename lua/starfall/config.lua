local M = {}

---@class StarfallConfig
M.defaults = {
  -- How many ambient twinkling stars are kept alive per window at once.
  density = 16,

  -- How many gentle vertical falling stars are kept alive per window at once.
  falling_stars = 2,

  -- Animation ticks per second. 8-14 looks smooth without being distracting.
  fps = 10,

  -- Glyph ramp used for ambient twinkling stars, dim -> bright -> dim.
  -- The star ping-pongs back and forth through this list while it lives.
  twinkle_chars = { "·", "‧", "✦", "✧", "✩", "★", "✩", "✧", "✦", "‧", "·" },

  -- Soft color palette for ambient stars. A random color is chosen per star.
  colors = {
    "#eaeaea", -- soft white
    "#ffe9a8", -- warm gold
    "#a8d4ff", -- pale blue
    "#ffc9de", -- soft pink
    "#c9ffb0", -- pale green
    "#d8c2ff", -- lavender
  },

  -- Vertical falling star appearance (gentle, straight down, fairly frequent).
  falling_char = "★",
  falling_color = "#ffffff",
  -- Trail glyphs from oldest (dimmest) to newest, rendered behind the head.
  trail_chars = { "·", "✦" },
  -- How many ticks a falling star waits before moving down one line.
  -- Lower = faster fall.
  fall_speed = 2,
  -- How many past positions are kept as a fading trail behind the head.
  trail_length = 3,

  -- Golden diagonal "shooting star" -- rare, fast, and crosses the window
  -- corner-to-corner, distinct from the gentle vertical falling stars above.
  shooting_stars = 1, -- max concurrent per window
  shooting_spawn_chance = 0.015, -- checked once per tick; keep this low for rarity
  shooting_char = "★",
  shooting_color = "#ffd700", -- gold
  shooting_trail_chars = { "·", "✧", "✦" },
  shooting_trail_length = 4,
  -- Moves every `shooting_move_every` ticks: 1 row down plus a random
  -- number of columns sideways (picked from shooting_speed_col), so it
  -- streaks across the window fast instead of drifting straight down.
  shooting_move_every = 1,
  shooting_speed_col = { 2, 3 },

  -- Ambient star lifetime, in ticks, before it dies and (eventually) respawns
  -- elsewhere.
  min_life = 30,
  max_life = 70,

  -- Chance per tick [0-1] of attempting to spawn a new ambient / falling star
  -- when below the configured density. Keeps spawns organic instead of
  -- instantaneous.
  twinkle_spawn_chance = 0.5,
  falling_spawn_chance = 0.06,

  -- Windows whose buffer has one of these filetypes are never decorated
  -- (pickers, trees, dashboards, etc).
  ignore_filetypes = {
    "TelescopePrompt", "TelescopeResults", "NvimTree", "neo-tree",
    "lazy", "mason", "help", "dashboard", "alpha", "starter",
    "notify", "noice", "trouble", "qf", "fugitive",
  },

  -- Minimum blank margin (in columns) required around real text before a
  -- star is allowed to spawn there, so glyphs never crowd right up against
  -- your code.
  margin = 2,
}

return M
