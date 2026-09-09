local highlights = require("starfall.highlights")

local M = {}

local uv = vim.uv or vim.loop

local ns = vim.api.nvim_create_namespace("starfall")

---@class StarfallWinCtx
---@field buf integer
---@field stars table[]
---@field filler_id integer|nil  -- extmark id of the shared below-EOF canvas

local state = {
  active = false,
  timer = nil,
  cfg = nil,
  -- winid -> StarfallWinCtx
  contexts = {},
}

math.randomseed(os.time())

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
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
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

  local line_count = vim.api.nvim_buf_line_count(buf)
  local topline = wi.topline
  local botline = math.min(wi.botline, line_count)
  local real_rows = math.max(0, botline - topline + 1)

  -- Only claim filler rows when the window's bottom edge actually shows EOF
  -- (i.e. there's nothing left to scroll to) -- otherwise the "blank" area
  -- is really just unscrolled buffer content we haven't reached yet.
  local filler_rows = 0
  if wi.botline >= line_count then
    filler_rows = math.max(0, wi.height - real_rows)
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
          state.contexts[win] = { buf = buf, stars = {}, filler_id = nil }
        elseif ctx.buf ~= buf then
          -- Buffer changed underneath the window (e.g. :bnext); drop old
          -- decorations and start fresh.
          if vim.api.nvim_buf_is_valid(ctx.buf) then
            vim.api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
          end
          state.contexts[win] = { buf = buf, stars = {}, filler_id = nil }
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

---Renders one twinkle star for this tick. Buffer-region stars get their own
---reusable extmark; filler-region stars (below EOF) are queued so they can
---be batched into the shared below-EOF canvas.
local function render_twinkle(ctx, star, queue)
  local ch = state.cfg.twinkle_chars[star.stage]
  if star.region == "buffer" then
    if not vim.api.nvim_buf_is_valid(ctx.buf) then
      return
    end
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
  else
    table.insert(queue, { filler_row = star.filler_row, col = star.col, char = ch, hl = star.hl })
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
  local pick = math.random(0, layout.total_rows - 1)

  local star
  if pick < layout.real_rows then
    local row = layout.topline - 1 + pick
    local line = get_line(ctx.buf, row)
    local ranges = safe_ranges(line, layout.width, cfg.margin)
    local col = pick_col(ranges)
    if not col then
      return
    end
    star = { region = "buffer", row = row, col = col }
  else
    local fr = pick - layout.real_rows
    local col = math.random(0, layout.width - 1)
    star = { region = "filler", filler_row = fr, col = col }
  end

  star.kind = "twinkle"
  star.stage = 1
  star.dir = 1
  star.age = 0
  star.life = math.random(cfg.min_life, cfg.max_life)
  star.hl = highlights.color_group(math.random(1, #cfg.colors))
  star.id = nil

  render_twinkle(ctx, star, queue)
  table.insert(ctx.stars, star)
end

---@return boolean alive
local function update_twinkle(ctx, star)
  local cfg = state.cfg
  star.age = star.age + 1
  if star.age >= star.life then
    if star.region == "buffer" and star.id then
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
  return true
end

-- ============================================================================
-- Shared trail renderer: both the vertical falling stars and the diagonal
-- shooting stars are a moving head + a short fading trail behind it. This
-- draws either kind, routing buffer-region pieces to their own extmark and
-- filler-region pieces (below EOF) into the shared canvas queue.
-- ============================================================================

local function draw_streak(ctx, star, queue, head_char, head_hl, trail_chars, trail_hls)
  for _, id in ipairs(star.marks) do
    pcall(vim.api.nvim_buf_del_extmark, ctx.buf, ns, id)
  end
  star.marks = {}

  local n = #star.history
  for i, pos in ipairs(star.history) do
    local age_rank = n - i -- 0 = newest trail piece, closest to head
    local hl = trail_hls[math.max(1, #trail_hls - age_rank)]
    local ch = trail_chars[math.min(#trail_chars, age_rank + 1)]
    if pos.region == "buffer" then
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
    else
      table.insert(queue, { filler_row = pos.filler_row, col = pos.col, char = ch, hl = hl })
    end
  end

  if star.region == "buffer" then
    local opts = {
      virt_text = { { head_char, head_hl } },
      virt_text_win_col = star.col,
      hl_mode = "combine",
      priority = 95,
    }
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, ctx.buf, ns, star.row, 0, opts)
    if ok then
      table.insert(star.marks, id)
    end
  else
    table.insert(queue, { filler_row = star.filler_row, col = star.col, char = head_char, hl = head_hl })
  end
end

-- ============================================================================
-- Vertical falling stars -- fall straight through real code lines and keep
-- going into the blank canvas below your file, all the way to the bottom.
-- ============================================================================

local function draw_falling(ctx, star, queue)
  local cfg = state.cfg
  draw_streak(
    ctx, star, queue,
    cfg.falling_char, "StarfallFallingHead",
    cfg.trail_chars, { "StarfallTrail3", "StarfallTrail2", "StarfallTrail1" }
  )
end

local function spawn_falling(ctx, layout, queue)
  local cfg = state.cfg
  if layout.real_rows <= 0 then
    return
  end
  local row = layout.topline - 1
  local line = get_line(ctx.buf, row)
  local ranges = safe_ranges(line, layout.width, cfg.margin)
  local col = pick_col(ranges)
  if not col then
    return
  end

  local star = {
    kind = "falling",
    region = "buffer",
    row = row,
    col = col,
    fall_tick = 0,
    history = {},
    marks = {},
  }
  draw_falling(ctx, star, queue)
  table.insert(ctx.stars, star)
end

---@return boolean alive
local function update_falling(ctx, star, layout)
  local cfg = state.cfg

  star.fall_tick = star.fall_tick + 1
  if star.fall_tick < cfg.fall_speed then
    return true -- not time to move yet, keep current frame
  end
  star.fall_tick = 0

  if star.region == "buffer" then
    table.insert(star.history, { region = "buffer", row = star.row, col = star.col })
  else
    table.insert(star.history, { region = "filler", filler_row = star.filler_row, col = star.col })
  end
  while #star.history > cfg.trail_length do
    table.remove(star.history, 1)
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

    local line = get_line(ctx.buf, new_row)
    local ranges = safe_ranges(line, layout.width, cfg.margin)
    local drift = math.random(-1, 1)
    local new_col = star.col + drift
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
    local drift = math.random(-1, 1)
    local new_col = star.col + drift
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
-- ============================================================================

local function draw_shooting(ctx, star, queue)
  local cfg = state.cfg
  draw_streak(
    ctx, star, queue,
    cfg.shooting_char, "StarfallShootingHead",
    cfg.shooting_trail_chars, { "StarfallShootingTrail3", "StarfallShootingTrail2", "StarfallShootingTrail1" }
  )
end

---Finds the safe column closest to the left (side=0) or right (side=1) edge
---of the given ranges, so the streak can enter right at the window border.
local function edge_col(ranges, side)
  local best = nil
  for _, r in ipairs(ranges) do
    local candidate = (side == 0) and r[1] or (r[2] - 1)
    if not best then
      best = candidate
    elseif side == 0 and candidate < best then
      best = candidate
    elseif side == 1 and candidate > best then
      best = candidate
    end
  end
  return best
end

local function spawn_shooting(ctx, layout, queue)
  local cfg = state.cfg
  if layout.real_rows <= 0 then
    return
  end

  -- Start somewhere in the upper portion of the visible area, so the streak
  -- has room to cross the rest of the window as it falls.
  local span = math.max(1, math.floor(layout.real_rows * 0.4))
  local row = layout.topline - 1 + math.random(0, span - 1)
  local line = get_line(ctx.buf, row)
  local ranges = safe_ranges(line, layout.width, cfg.margin)
  if #ranges == 0 then
    return
  end

  local side = math.random(0, 1) -- 0 = enters from the left, 1 = from the right
  local col = edge_col(ranges, side)
  if not col then
    return
  end

  local speed = math.random(cfg.shooting_speed_col[1], cfg.shooting_speed_col[2])
  local dx = (side == 0) and speed or -speed

  local star = {
    kind = "shooting",
    region = "buffer",
    row = row,
    col = col,
    dx = dx,
    move_tick = 0,
    history = {},
    marks = {},
  }
  draw_shooting(ctx, star, queue)
  table.insert(ctx.stars, star)
end

---@return boolean alive
local function update_shooting(ctx, star, layout)
  local cfg = state.cfg

  star.move_tick = star.move_tick + 1
  if star.move_tick < cfg.shooting_move_every then
    return true
  end
  star.move_tick = 0

  if star.region == "buffer" then
    table.insert(star.history, { region = "buffer", row = star.row, col = star.col })
  else
    table.insert(star.history, { region = "filler", filler_row = star.filler_row, col = star.col })
  end
  while #star.history > cfg.shooting_trail_length do
    table.remove(star.history, 1)
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

    local line = get_line(ctx.buf, new_row)
    local ranges = safe_ranges(line, layout.width, cfg.margin)
    if not range_contains(ranges, new_col) then
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
-- every filler-region star (ambient + falling heads + trails) for this
-- window in one batch, sized to exactly fill the remaining blank rows.
-- ============================================================================

local function render_filler_block(ctx, layout, queue)
  if layout.filler_rows <= 0 then
    if ctx.filler_id then
      pcall(vim.api.nvim_buf_del_extmark, ctx.buf, ns, ctx.filler_id)
      ctx.filler_id = nil
    end
    return
  end

  local rows = {}
  for i = 0, layout.filler_rows - 1 do
    rows[i] = {}
  end
  for _, item in ipairs(queue) do
    if rows[item.filler_row] then
      table.insert(rows[item.filler_row], item)
    end
  end

  local virt_lines = {}
  for i = 0, layout.filler_rows - 1 do
    local items = rows[i]
    table.sort(items, function(a, b)
      return a.col < b.col
    end)
    local chunks = {}
    local cursor = 0
    for _, it in ipairs(items) do
      if it.col > cursor then
        table.insert(chunks, { string.rep(" ", it.col - cursor), "Normal" })
      end
      if it.col >= cursor then
        table.insert(chunks, { it.char, it.hl })
        cursor = it.col + 1
      end
    end
    if #chunks == 0 then
      chunks = { { "", "Normal" } }
    end
    table.insert(virt_lines, chunks)
  end

  local opts = {
    id = ctx.filler_id,
    virt_lines = virt_lines,
    priority = 90,
  }
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, ctx.buf, ns, layout.last_row, 0, opts)
  if ok then
    ctx.filler_id = id
  end
end

-- ============================================================================
-- Tick loop
-- ============================================================================

local function tick_window(win, ctx)
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(ctx.buf) then
    return
  end
  local layout = compute_layout(win, ctx.buf)
  if not layout then
    return
  end
  local cfg = state.cfg
  local queue = {} -- glyphs destined for the shared below-EOF canvas

  local alive = {}
  local twinkle_count, falling_count, shooting_count = 0, 0, 0

  for _, star in ipairs(ctx.stars) do
    if star.kind == "twinkle" then
      if update_twinkle(ctx, star) then
        render_twinkle(ctx, star, queue)
        twinkle_count = twinkle_count + 1
        table.insert(alive, star)
      end
    elseif star.kind == "falling" then
      if update_falling(ctx, star, layout) then
        draw_falling(ctx, star, queue)
        falling_count = falling_count + 1
        table.insert(alive, star)
      else
        for _, id in ipairs(star.marks) do
          pcall(vim.api.nvim_buf_del_extmark, ctx.buf, ns, id)
        end
      end
    else -- "shooting"
      if update_shooting(ctx, star, layout) then
        draw_shooting(ctx, star, queue)
        shooting_count = shooting_count + 1
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
    spawn_twinkle(ctx, layout, queue)
  end
  if falling_count < cfg.falling_stars and math.random() < cfg.falling_spawn_chance then
    spawn_falling(ctx, layout, queue)
  end
  if shooting_count < cfg.shooting_stars and math.random() < cfg.shooting_spawn_chance then
    spawn_shooting(ctx, layout, queue)
  end

  render_filler_block(ctx, layout, queue)
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
