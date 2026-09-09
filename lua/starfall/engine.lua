local highlights = require("starfall.highlights")

local M = {}

-- Localize hot-path stdlib functions once; avoids a global-table lookup on
-- every call inside the per-star, per-tick loops below.
local uv = vim.uv or vim.loop
local floor, max, min, random = math.floor, math.max, math.min, math.random
local tsort, tremove = table.sort, table.remove
local time = os.time

local api = vim.api
local set_extmark = api.nvim_buf_set_extmark
local del_extmark = api.nvim_buf_del_extmark

local ns = api.nvim_create_namespace("starfall")

-- Trail highlight-group ramps never change at runtime, so build them once
-- instead of allocating a fresh table on every single draw call.
local FALLING_TRAIL_HLS = { "StarfallTrail3", "StarfallTrail2", "StarfallTrail1" }
local SHOOTING_TRAIL_HLS = { "StarfallShootingTrail3", "StarfallShootingTrail2", "StarfallShootingTrail1" }
-- Shared, read-only "nothing here" virt_lines entry -- reused by reference
-- for every empty filler row instead of allocating one per row per tick.
local BLANK_FILLER_LINE = { { "", "Normal" } }

---@class StarfallWinCtx
---@field buf integer
---@field stars table[]
---@field filler_id integer|nil     -- extmark id of the shared below-EOF canvas
---@field shooting_log integer[]    -- recent shooting-star spawn timestamps (epoch secs)

local state = {
  active = false,
  timer = nil,
  cfg = nil,
  -- winid -> StarfallWinCtx
  contexts = {},
}

math.randomseed(time())

-- ============================================================================
-- Geometry: figure out (a) which columns on real buffer lines are free of
-- text, and (b) how many blank screen rows exist below the last buffer line
-- (the "~" area), so stars can roam the *entire* visible window -- not just
-- the lines your file happens to have.
-- ============================================================================

---Computes a full layout snapshot for a window/buffer pair:
---  width       - usable text-area columns (matches virt_text_win_col space)
---  height      - visible text rows in the window
---  topline/botline - first/last visible buffer line (1-indexed, real lines)
---  real_rows   - how many of those visible rows are real buffer lines
---  filler_rows - how many visible rows are blank "~" rows below EOF
---  total_rows  - real_rows + filler_rows
---  line_count/last_row - buffer size info, for detecting EOF transitions
---Returns nil if the window/buffer isn't currently valid.
local function compute_layout(win, buf)
  if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(buf) then
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

  local line_count = api.nvim_buf_line_count(buf)
  local topline = wi.topline
  local botline = min(wi.botline, line_count)
  local real_rows = max(0, botline - topline + 1)

  -- Only claim filler rows when the window's bottom edge actually shows EOF
  -- (i.e. there's nothing left to scroll to) -- otherwise the "blank" area
  -- is really just unscrolled buffer content we haven't reached yet.
  local filler_rows = 0
  if wi.botline >= line_count then
    filler_rows = max(0, wi.height - real_rows)
  end

  return {
    width = width,
    height = wi.height,
    topline = topline,
    botline = botline,
    real_rows = real_rows,
    filler_rows = filler_rows,
    total_rows = real_rows + filler_rows,
    line_count = line_count,
    last_row = line_count - 1,
  }
end

---Fetches buffer line `row0` (0-indexed). `line_count` is passed in from an
---already-computed layout to avoid a redundant nvim_buf_line_count call.
local function get_line(buf, row0, line_count)
  if row0 < 0 or row0 >= line_count then
    return nil
  end
  local ok, lines = pcall(api.nvim_buf_get_lines, buf, row0, row0 + 1, false)
  if not ok or not lines[1] then
    return nil
  end
  return lines[1]
end

---Computes [from, to) column ranges on `line` that are free of real text
---(leading indentation and/or the blank area past end-of-line), respecting
---the configured margin.
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
    ranges[#ranges + 1] = { 0, indent_w - margin }
  end
  if content_w + margin < width then
    ranges[#ranges + 1] = { content_w + margin, width }
  end
  return ranges
end

local function range_contains(ranges, col)
  for i = 1, #ranges do
    local r = ranges[i]
    if col >= r[1] and col < r[2] then
      return true
    end
  end
  return false
end

local function pick_col(ranges)
  local total = 0
  for i = 1, #ranges do
    total = total + (ranges[i][2] - ranges[i][1])
  end
  if total <= 0 then
    return nil
  end
  local pick = random(0, total - 1)
  for i = 1, #ranges do
    local r = ranges[i]
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
  if api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then
    return true
  end
  local ft = api.nvim_get_option_value("filetype", { buf = buf })
  local ignored = cfg.ignore_filetypes
  for i = 1, #ignored do
    if ft == ignored[i] then
      return true
    end
  end
  return false
end

local function is_normal_window(win)
  if not api.nvim_win_is_valid(win) then
    return false
  end
  return api.nvim_win_get_config(win).relative == "" -- exclude floating windows
end

local function new_ctx(buf)
  return { buf = buf, stars = {}, filler_id = nil, shooting_log = {} }
end

---Ensures every currently-visible eligible window has a tracked context, and
---prunes contexts whose window has since closed.
local function sync_contexts()
  local cfg = state.cfg
  local seen = {}

  local wins = api.nvim_list_wins()
  for i = 1, #wins do
    local win = wins[i]
    if is_normal_window(win) then
      local buf = api.nvim_win_get_buf(win)
      if not is_ignored_buf(buf, cfg) then
        seen[win] = true
        local ctx = state.contexts[win]
        if not ctx then
          state.contexts[win] = new_ctx(buf)
        elseif ctx.buf ~= buf then
          -- Buffer changed underneath the window (e.g. :bnext); drop old
          -- decorations and start fresh.
          if api.nvim_buf_is_valid(ctx.buf) then
            api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
          end
          state.contexts[win] = new_ctx(buf)
        end
      end
    end
  end

  for win, ctx in pairs(state.contexts) do
    if not seen[win] then
      if api.nvim_buf_is_valid(ctx.buf) then
        api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
      end
      state.contexts[win] = nil
    end
  end
end

-- ============================================================================
-- Ambient twinkling stars
-- ============================================================================

---Renders one twinkle star for this tick. Buffer-region stars get their own
---reusable extmark; filler-region stars (below EOF) are queued so they can
---be batched into the shared below-EOF canvas.
local function render_twinkle(ctx, star, queue)
  local ch = state.cfg.twinkle_chars[star.stage]
  if star.region == "buffer" then
    local ok, id = pcall(set_extmark, ctx.buf, ns, star.row, 0, {
      id = star.id,
      virt_text = { { ch, star.hl } },
      virt_text_win_col = star.col,
      hl_mode = "combine",
      priority = 90,
    })
    if ok then
      star.id = id
    end
  else
    queue[#queue + 1] = { filler_row = star.filler_row, col = star.col, char = ch, hl = star.hl }
  end
end

---Picks a random spawn slot across the *entire* visible window -- real
---buffer lines and the blank below-EOF canvas alike -- weighted by how many
---rows each region actually has.
local function spawn_twinkle(ctx, layout, queue)
  local cfg = state.cfg
  if layout.total_rows <= 0 then
    return
  end
  local pick = random(0, layout.total_rows - 1)

  local star
  if pick < layout.real_rows then
    local row = layout.topline - 1 + pick
    local line = get_line(ctx.buf, row, layout.line_count)
    local col = pick_col(safe_ranges(line, layout.width, cfg.margin))
    if not col then
      return
    end
    star = { region = "buffer", row = row, col = col }
  else
    star = { region = "filler", filler_row = pick - layout.real_rows, col = random(0, layout.width - 1) }
  end

  star.kind = "twinkle"
  star.stage = 1
  star.dir = 1
  star.age = 0
  star.life = random(cfg.min_life, cfg.max_life)
  star.hl = highlights.color_group(random(1, #cfg.colors))
  star.id = nil

  render_twinkle(ctx, star, queue)
  ctx.stars[#ctx.stars + 1] = star
end

---@return boolean alive
local function update_twinkle(ctx, star)
  local cfg = state.cfg
  star.age = star.age + 1
  if star.age >= star.life then
    if star.region == "buffer" and star.id then
      pcall(del_extmark, ctx.buf, ns, star.id)
    end
    return false
  end

  local stage, dir = star.stage + star.dir, star.dir
  local n = #cfg.twinkle_chars
  if stage >= n then
    stage, dir = n, -1
  elseif stage <= 1 then
    stage, dir = 1, 1
  end
  star.stage, star.dir = stage, dir
  return true
end

-- ============================================================================
-- Shared trail renderer: both the vertical falling stars and the diagonal
-- shooting stars are a moving head + a short fading trail behind it. This
-- draws either kind, routing buffer-region pieces to their own extmark and
-- filler-region pieces (below EOF) into the shared canvas queue.
-- ============================================================================

local function draw_streak(ctx, star, queue, head_char, head_hl, trail_chars, trail_hls)
  local marks = star.marks
  for i = 1, #marks do
    pcall(del_extmark, ctx.buf, ns, marks[i])
  end
  local mi = 0
  local n_trail_hls, n_trail_chars = #trail_hls, #trail_chars

  local history = star.history
  local n = #history
  for i = 1, n do
    local pos = history[i]
    local age_rank = n - i -- 0 = newest trail piece, closest to head
    local hl = trail_hls[max(1, n_trail_hls - age_rank)]
    local ch = trail_chars[min(n_trail_chars, age_rank + 1)]
    if pos.region == "buffer" then
      local ok, id = pcall(set_extmark, ctx.buf, ns, pos.row, 0, {
        virt_text = { { ch, hl } },
        virt_text_win_col = pos.col,
        hl_mode = "combine",
        priority = 80,
      })
      if ok then
        mi = mi + 1
        marks[mi] = id
      end
    else
      queue[#queue + 1] = { filler_row = pos.filler_row, col = pos.col, char = ch, hl = hl }
    end
  end

  if star.region == "buffer" then
    local ok, id = pcall(set_extmark, ctx.buf, ns, star.row, 0, {
      virt_text = { { head_char, head_hl } },
      virt_text_win_col = star.col,
      hl_mode = "combine",
      priority = 95,
    })
    if ok then
      mi = mi + 1
      marks[mi] = id
    end
  else
    queue[#queue + 1] = { filler_row = star.filler_row, col = star.col, char = head_char, hl = head_hl }
  end

  -- Truncate any leftover slots from a previous, longer mark list.
  for i = mi + 1, #marks do
    marks[i] = nil
  end
end

-- ============================================================================
-- Vertical falling stars -- fall straight through real code lines and keep
-- going into the blank canvas below your file, all the way to the bottom.
-- ============================================================================

local function draw_falling(ctx, star, queue)
  local cfg = state.cfg
  draw_streak(ctx, star, queue, cfg.falling_char, "StarfallFallingHead", cfg.trail_chars, FALLING_TRAIL_HLS)
end

local function spawn_falling(ctx, layout, queue)
  local cfg = state.cfg
  if layout.real_rows <= 0 then
    return
  end
  local row = layout.topline - 1
  local line = get_line(ctx.buf, row, layout.line_count)
  local col = pick_col(safe_ranges(line, layout.width, cfg.margin))
  if not col then
    return
  end

  local star = { kind = "falling", region = "buffer", row = row, col = col, fall_tick = 0, history = {}, marks = {} }
  draw_falling(ctx, star, queue)
  ctx.stars[#ctx.stars + 1] = star
end

---@return boolean alive
local function update_falling(ctx, star, layout)
  local cfg = state.cfg

  star.fall_tick = star.fall_tick + 1
  if star.fall_tick < cfg.fall_speed then
    return true -- not time to move yet, keep current frame
  end
  star.fall_tick = 0

  local history = star.history
  if star.region == "buffer" then
    history[#history + 1] = { region = "buffer", row = star.row, col = star.col }
  else
    history[#history + 1] = { region = "filler", filler_row = star.filler_row, col = star.col }
  end
  while #history > cfg.trail_length do
    tremove(history, 1)
  end

  if star.region == "buffer" then
    local new_row = star.row + 1
    if new_row >= layout.line_count then
      -- Reached the end of the file: keep falling into the blank canvas
      -- below EOF instead of despawning.
      if layout.filler_rows <= 0 then
        return false
      end
      star.region = "filler"
      star.filler_row = 0
      return true
    end

    local line = get_line(ctx.buf, new_row, layout.line_count)
    local ranges = safe_ranges(line, layout.width, cfg.margin)
    local new_col = star.col + random(-1, 1)
    if not range_contains(ranges, new_col) then
      new_col = star.col
      if not range_contains(ranges, new_col) then
        return false -- text has shifted into our path; despawn gracefully
      end
    end
    star.row = new_row
    star.col = new_col
    return true
  else
    local new_fr = star.filler_row + 1
    if new_fr >= layout.filler_rows then
      return false -- hit the bottom edge of the window
    end
    local new_col = star.col + random(-1, 1)
    if new_col < 0 or new_col >= layout.width then
      new_col = star.col
    end
    star.filler_row = new_fr
    star.col = new_col
    return true
  end
end

-- ============================================================================
-- Golden shooting stars -- rare, fast, diagonal streaks across the window.
-- Unlike the gentle vertical falling stars, these move sideways as well as
-- down each step, cutting a fast corner-to-corner path with a golden tail.
-- Capped both by concurrency AND a rolling per-minute budget (see
-- `shooting_budget_ok`, checked in the tick loop) so they stay a rare treat.
-- ============================================================================

local function draw_shooting(ctx, star, queue)
  local cfg = state.cfg
  draw_streak(ctx, star, queue, cfg.shooting_char, "StarfallShootingHead", cfg.shooting_trail_chars, SHOOTING_TRAIL_HLS)
end

---Finds the safe column closest to the left (side=0) or right (side=1) edge
---of the given ranges, so the streak can enter right at the window border.
local function edge_col(ranges, side)
  local best = nil
  for i = 1, #ranges do
    local r = ranges[i]
    local candidate = (side == 0) and r[1] or (r[2] - 1)
    if not best or (side == 0 and candidate < best) or (side == 1 and candidate > best) then
      best = candidate
    end
  end
  return best
end

---True if fewer than `shooting_max_per_minute` shooting stars have spawned
---in this window within the last 60 seconds. Prunes the log in place; the
---log is capped at a handful of entries so this stays cheap.
local function shooting_budget_ok(ctx, cfg, now)
  local log = ctx.shooting_log
  local kept = 0
  for i = 1, #log do
    if now - log[i] < 60 then
      kept = kept + 1
      log[kept] = log[i]
    end
  end
  for i = kept + 1, #log do
    log[i] = nil
  end
  return kept < cfg.shooting_max_per_minute
end

local function spawn_shooting(ctx, layout, queue, now)
  local cfg = state.cfg
  if layout.real_rows <= 0 then
    return
  end

  -- Start somewhere in the upper portion of the visible area, so the streak
  -- has room to cross the rest of the window as it falls.
  local span = max(1, floor(layout.real_rows * 0.4))
  local row = layout.topline - 1 + random(0, span - 1)
  local line = get_line(ctx.buf, row, layout.line_count)
  local ranges = safe_ranges(line, layout.width, cfg.margin)
  if #ranges == 0 then
    return
  end

  local side = random(0, 1) -- 0 = enters from the left, 1 = from the right
  local col = edge_col(ranges, side)
  if not col then
    return
  end

  local speed = random(cfg.shooting_speed_col[1], cfg.shooting_speed_col[2])
  local star = {
    kind = "shooting",
    region = "buffer",
    row = row,
    col = col,
    dx = (side == 0) and speed or -speed,
    move_tick = 0,
    history = {},
    marks = {},
  }
  draw_shooting(ctx, star, queue)
  ctx.stars[#ctx.stars + 1] = star

  local log = ctx.shooting_log
  log[#log + 1] = now
end

---@return boolean alive
local function update_shooting(ctx, star, layout)
  local cfg = state.cfg

  star.move_tick = star.move_tick + 1
  if star.move_tick < cfg.shooting_move_every then
    return true
  end
  star.move_tick = 0

  local history = star.history
  if star.region == "buffer" then
    history[#history + 1] = { region = "buffer", row = star.row, col = star.col }
  else
    history[#history + 1] = { region = "filler", filler_row = star.filler_row, col = star.col }
  end
  while #history > cfg.shooting_trail_length do
    tremove(history, 1)
  end

  local new_col = star.col + star.dx
  if new_col < 0 or new_col >= layout.width then
    return false -- streaked off the side of the window -- a clean exit
  end

  if star.region == "buffer" then
    local new_row = star.row + 1
    if new_row >= layout.line_count then
      if layout.filler_rows <= 0 then
        return false
      end
      star.region = "filler"
      star.filler_row = 0
      star.col = new_col
      return true
    end

    local line = get_line(ctx.buf, new_row, layout.line_count)
    if not range_contains(safe_ranges(line, layout.width, cfg.margin), new_col) then
      return false -- crossed into text; end the streak cleanly rather than jump around
    end
    star.row = new_row
    star.col = new_col
    return true
  else
    local new_fr = star.filler_row + 1
    if new_fr >= layout.filler_rows then
      return false
    end
    star.filler_row = new_fr
    star.col = new_col
    return true
  end
end

-- ============================================================================
-- The shared "below EOF" canvas: a single extmark using virt_lines to paint
-- every filler-region star (ambient + falling/shooting heads + trails) for
-- this window in one batch, sized to exactly fill the remaining blank rows.
-- ============================================================================

local function render_filler_block(ctx, layout, queue)
  if layout.filler_rows <= 0 then
    if ctx.filler_id then
      pcall(del_extmark, ctx.buf, ns, ctx.filler_id)
      ctx.filler_id = nil
    end
    return
  end

  local virt_lines = {}
  local n_queue = #queue

  if n_queue == 0 then
    -- Nothing to draw this tick -- still reserve the space with `filler_rows`
    -- blank lines (otherwise the "~" tildes would flicker back in), reusing
    -- one shared blank-line table instead of allocating filler_rows of them.
    for i = 1, layout.filler_rows do
      virt_lines[i] = BLANK_FILLER_LINE
    end
  else
    local grouped = {}
    for i = 1, n_queue do
      local item = queue[i]
      local fr = item.filler_row
      if fr >= 0 and fr < layout.filler_rows then
        local list = grouped[fr]
        if not list then
          list = {}
          grouped[fr] = list
        end
        list[#list + 1] = item
      end
    end

    for i = 0, layout.filler_rows - 1 do
      local items = grouped[i]
      if not items then
        virt_lines[i + 1] = BLANK_FILLER_LINE
      else
        if #items > 1 then
          tsort(items, function(a, b)
            return a.col < b.col
          end)
        end
        local chunks = {}
        local ci, cursor = 0, 0
        for j = 1, #items do
          local it = items[j]
          if it.col > cursor then
            ci = ci + 1
            chunks[ci] = { string.rep(" ", it.col - cursor), "Normal" }
          end
          ci = ci + 1
          chunks[ci] = { it.char, it.hl }
          cursor = it.col + 1
        end
        virt_lines[i + 1] = chunks
      end
    end
  end

  local ok, id = pcall(set_extmark, ctx.buf, ns, layout.last_row, 0, {
    id = ctx.filler_id,
    virt_lines = virt_lines,
    priority = 90,
  })
  if ok then
    ctx.filler_id = id
  end
end

-- ============================================================================
-- Tick loop
-- ============================================================================

local function tick_window(win, ctx, now)
  if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(ctx.buf) then
    return
  end
  local layout = compute_layout(win, ctx.buf)
  if not layout then
    return
  end
  local cfg = state.cfg
  local queue = {} -- glyphs destined for the shared below-EOF canvas

  local stars = ctx.stars
  local alive, ai = {}, 0
  local twinkle_count, falling_count, shooting_count = 0, 0, 0

  for i = 1, #stars do
    local star = stars[i]
    local kind = star.kind
    if kind == "twinkle" then
      if update_twinkle(ctx, star) then
        render_twinkle(ctx, star, queue)
        twinkle_count = twinkle_count + 1
        ai = ai + 1
        alive[ai] = star
      end
    elseif kind == "falling" then
      if update_falling(ctx, star, layout) then
        draw_falling(ctx, star, queue)
        falling_count = falling_count + 1
        ai = ai + 1
        alive[ai] = star
      else
        local marks = star.marks
        for j = 1, #marks do
          pcall(del_extmark, ctx.buf, ns, marks[j])
        end
      end
    else -- "shooting"
      if update_shooting(ctx, star, layout) then
        draw_shooting(ctx, star, queue)
        shooting_count = shooting_count + 1
        ai = ai + 1
        alive[ai] = star
      else
        local marks = star.marks
        for j = 1, #marks do
          pcall(del_extmark, ctx.buf, ns, marks[j])
        end
      end
    end
  end
  ctx.stars = alive

  if twinkle_count < cfg.density and random() < cfg.twinkle_spawn_chance then
    spawn_twinkle(ctx, layout, queue)
  end
  if falling_count < cfg.falling_stars and random() < cfg.falling_spawn_chance then
    spawn_falling(ctx, layout, queue)
  end
  if
    shooting_count < cfg.shooting_stars
    and random() < cfg.shooting_spawn_chance
    and shooting_budget_ok(ctx, cfg, now)
  then
    spawn_shooting(ctx, layout, queue, now)
  end

  render_filler_block(ctx, layout, queue)
end

function M.tick()
  if not state.active then
    return
  end
  local ok, err = pcall(function()
    sync_contexts()
    local now = time()
    for win, ctx in pairs(state.contexts) do
      tick_window(win, ctx, now)
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

  local interval = max(16, floor(1000 / cfg.fps))
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
    if api.nvim_buf_is_valid(ctx.buf) then
      api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
    end
  end
  state.contexts = {}
end

function M.is_active()
  return state.active
end

return M
