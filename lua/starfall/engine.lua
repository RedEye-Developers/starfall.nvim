local highlights = require("starfall.highlights")

local M = {}

local uv = vim.uv or vim.loop

local ns = vim.api.nvim_create_namespace("starfall")

---@class StarfallWinCtx
---@field buf integer
---@field stars table[]

local state = {
  active = false,
  timer = nil,
  cfg = nil,
  augroup = nil,
  -- winid -> StarfallWinCtx
  contexts = {},
}

math.randomseed(os.time())

-- ============================================================================
-- Geometry helpers: figure out which screen cells are "empty" (safe to draw
-- a star on) vs. covered by real text, so stars never overlap your code.
-- ============================================================================

---Returns {width, topline, botline} in the coordinate space used by
---'virt_text_win_col' (i.e. text-area columns, excluding number/sign/fold
---columns), or nil if the window is not currently valid/visible.
local function win_text_info(win)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local ok, info = pcall(vim.fn.getwininfo, win)
  if not ok or not info or not info[1] then
    return nil
  end
  local wi = info[1]
  local width = wi.width - wi.textoff
  if width <= 0 then
    return nil
  end
  return { width = width, topline = wi.topline, botline = wi.botline }
end

local function get_line(buf, row0)
  if row0 < 0 or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if row0 >= count then
    return nil
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, row0, row0 + 1, false)
  if not ok or not lines[1] then
    return nil
  end
  return lines[1]
end

---Computes the list of [from, to) column ranges on `line` that are free of
---real text (leading indentation and/or the blank area past end-of-line),
---respecting the configured margin so stars keep a comfortable distance from
---any characters.
local function safe_ranges(line, width, margin)
  if width <= 0 then
    return {}
  end
  if line == nil or line:match("^%s*$") then
    return { { 0, width } }
  end

  local ranges = {}
  local leading = line:match("^%s*") or ""
  local indent_w = vim.fn.strdisplaywidth(leading)
  local content_w = vim.fn.strdisplaywidth(line)

  if indent_w - margin > 0 then
    table.insert(ranges, { 0, indent_w - margin })
  end
  if content_w + margin < width then
    table.insert(ranges, { content_w + margin, width })
  end
  return ranges
end

local function range_contains(ranges, col)
  for _, r in ipairs(ranges) do
    if col >= r[1] and col < r[2] then
      return true
    end
  end
  return false
end

local function pick_col(ranges)
  local total = 0
  for _, r in ipairs(ranges) do
    total = total + (r[2] - r[1])
  end
  if total <= 0 then
    return nil
  end
  local pick = math.random(0, total - 1)
  for _, r in ipairs(ranges) do
    local w = r[2] - r[1]
    if pick < w then
      return r[1] + pick
    end
    pick = pick - w
  end
  return nil
end

-- ============================================================================
-- Window discovery
-- ============================================================================

local function is_ignored_buf(buf, cfg)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
  if buftype ~= "" then
    return true
  end
  local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  for _, ignored in ipairs(cfg.ignore_filetypes) do
    if ft == ignored then
      return true
    end
  end
  return false
end

local function is_normal_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local wc = vim.api.nvim_win_get_config(win)
  return wc.relative == "" -- exclude floating windows
end

---Ensures every currently-visible eligible window has a tracked context, and
---prunes contexts whose window has since closed.
local function sync_contexts()
  local cfg = state.cfg
  local seen = {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_normal_window(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if not is_ignored_buf(buf, cfg) then
        seen[win] = true
        local ctx = state.contexts[win]
        if not ctx then
          state.contexts[win] = { buf = buf, stars = {} }
        elseif ctx.buf ~= buf then
          -- Buffer changed underneath the window (e.g. :bnext); drop old
          -- decorations and re-check eligibility next tick via a fresh ctx.
          if vim.api.nvim_buf_is_valid(ctx.buf) then
            vim.api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
          end
          state.contexts[win] = { buf = buf, stars = {} }
        end
      end
    end
  end

  for win, ctx in pairs(state.contexts) do
    if not seen[win] then
      if vim.api.nvim_buf_is_valid(ctx.buf) then
        vim.api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
      end
      state.contexts[win] = nil
    end
  end
end

-- ============================================================================
-- Ambient twinkling stars
-- ============================================================================

local function render_twinkle(ctx, star)
  if not vim.api.nvim_buf_is_valid(ctx.buf) then
    return
  end
  local ch = state.cfg.twinkle_chars[star.stage]
  local opts = {
    id = star.id,
    virt_text = { { ch, star.hl } },
    virt_text_win_col = star.col,
    hl_mode = "combine",
    priority = 90,
  }
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, ctx.buf, ns, star.row, 0, opts)
  if ok then
    star.id = id
  end
end

local function spawn_twinkle(win, ctx)
  local info = win_text_info(win)
  if not info then
    return
  end
  local cfg = state.cfg
  local row = math.random(info.topline, info.botline) - 1
  local line = get_line(ctx.buf, row)
  local ranges = safe_ranges(line, info.width, cfg.margin)
  local col = pick_col(ranges)
  if not col then
    return
  end

  local color_idx = math.random(1, #cfg.colors)
  local star = {
    kind = "twinkle",
    row = row,
    col = col,
    stage = 1,
    dir = 1,
    age = 0,
    life = math.random(cfg.min_life, cfg.max_life),
    hl = highlights.color_group(color_idx),
    id = nil,
  }
  render_twinkle(ctx, star)
  table.insert(ctx.stars, star)
end

---@return boolean alive
local function update_twinkle(ctx, star)
  local cfg = state.cfg
  star.age = star.age + 1
  if star.age >= star.life then
    if star.id then
      pcall(vim.api.nvim_buf_del_extmark, ctx.buf, ns, star.id)
    end
    return false
  end

  star.stage = star.stage + star.dir
  if star.stage >= #cfg.twinkle_chars then
    star.stage = #cfg.twinkle_chars
    star.dir = -1
  elseif star.stage <= 1 then
    star.stage = 1
    star.dir = 1
  end

  render_twinkle(ctx, star)
  return true
end

-- ============================================================================
-- Falling shooting stars (with fading trail)
-- ============================================================================

local function draw_falling(ctx, star)
  for _, id in ipairs(star.marks) do
    pcall(vim.api.nvim_buf_del_extmark, ctx.buf, ns, id)
  end
  star.marks = {}

  local cfg = state.cfg
  local trail_hls = { "StarfallTrail3", "StarfallTrail2", "StarfallTrail1" }
  local n = #star.history
  for i, pos in ipairs(star.history) do
    -- Oldest entries (low i) get the dimmest highlight.
    local age_rank = n - i -- 0 = newest trail piece
    local hl = trail_hls[math.max(1, #trail_hls - age_rank)]
    local ch = cfg.trail_chars[math.min(#cfg.trail_chars, age_rank + 1)]
    local opts = {
      virt_text = { { ch, hl } },
      virt_text_win_col = pos.col,
      hl_mode = "combine",
      priority = 80,
    }
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, ctx.buf, ns, pos.row, 0, opts)
    if ok then
      table.insert(star.marks, id)
    end
  end

  local opts = {
    virt_text = { { cfg.falling_char, "StarfallFallingHead" } },
    virt_text_win_col = star.col,
    hl_mode = "combine",
    priority = 95,
  }
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, ctx.buf, ns, star.row, 0, opts)
  if ok then
    table.insert(star.marks, id)
  end
end

local function spawn_falling(win, ctx)
  local info = win_text_info(win)
  if not info then
    return
  end
  local cfg = state.cfg
  local row = info.topline - 1
  local line = get_line(ctx.buf, row)
  local ranges = safe_ranges(line, info.width, cfg.margin)
  local col = pick_col(ranges)
  if not col then
    return
  end

  local star = {
    kind = "falling",
    row = row,
    col = col,
    fall_tick = 0,
    history = {},
    marks = {},
  }
  draw_falling(ctx, star)
  table.insert(ctx.stars, star)
end

---@return boolean alive
local function update_falling(win, ctx, star)
  local info = win_text_info(win)
  if not info then
    return false
  end
  local cfg = state.cfg

  star.fall_tick = star.fall_tick + 1
  if star.fall_tick < cfg.fall_speed then
    return true -- not time to move yet, keep current frame
  end
  star.fall_tick = 0

  table.insert(star.history, { row = star.row, col = star.col })
  while #star.history > cfg.trail_length do
    table.remove(star.history, 1)
  end

  local new_row = star.row + 1
  if new_row + 1 > info.botline then
    return false -- reached the bottom of the visible area
  end

  local line = get_line(ctx.buf, new_row)
  local ranges = safe_ranges(line, info.width, cfg.margin)

  local drift = math.random(-1, 1)
  local new_col = star.col + drift
  if not range_contains(ranges, new_col) then
    new_col = star.col
    if not range_contains(ranges, new_col) then
      return false -- text has moved into our path; despawn gracefully
    end
  end

  star.row = new_row
  star.col = new_col
  return true
end

-- ============================================================================
-- Tick loop
-- ============================================================================

local function tick_window(win, ctx)
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(ctx.buf) then
    return
  end
  local cfg = state.cfg

  local alive = {}
  local twinkle_count, falling_count = 0, 0

  for _, star in ipairs(ctx.stars) do
    if star.kind == "twinkle" then
      if update_twinkle(ctx, star) then
        twinkle_count = twinkle_count + 1
        table.insert(alive, star)
      end
    else
      if update_falling(win, ctx, star) then
        draw_falling(ctx, star)
        falling_count = falling_count + 1
        table.insert(alive, star)
      else
        for _, id in ipairs(star.marks) do
          pcall(vim.api.nvim_buf_del_extmark, ctx.buf, ns, id)
        end
      end
    end
  end
  ctx.stars = alive

  if twinkle_count < cfg.density and math.random() < cfg.twinkle_spawn_chance then
    spawn_twinkle(win, ctx)
  end
  if falling_count < cfg.falling_stars and math.random() < cfg.falling_spawn_chance then
    spawn_falling(win, ctx)
  end
end

function M.tick()
  if not state.active then
    return
  end
  local ok, err = pcall(function()
    sync_contexts()
    for win, ctx in pairs(state.contexts) do
      tick_window(win, ctx)
    end
  end)
  if not ok then
    vim.notify("starfall.nvim: stopping after error: " .. tostring(err), vim.log.levels.WARN)
    M.stop()
  end
end

-- ============================================================================
-- Public lifecycle
-- ============================================================================

function M.start(cfg)
  if state.active then
    vim.notify("✨ Starfall is already running", vim.log.levels.INFO)
    return
  end
  state.cfg = cfg
  state.active = true
  state.contexts = {}
  sync_contexts()

  local interval = math.max(16, math.floor(1000 / cfg.fps))
  state.timer = uv.new_timer()
  state.timer:start(interval, interval, vim.schedule_wrap(M.tick))
end

function M.stop()
  state.active = false
  if state.timer then
    pcall(function()
      state.timer:stop()
      state.timer:close()
    end)
    state.timer = nil
  end
  for _, ctx in pairs(state.contexts) do
    if vim.api.nvim_buf_is_valid(ctx.buf) then
      vim.api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
    end
  end
  state.contexts = {}
end

function M.is_active()
  return state.active
end

return M
