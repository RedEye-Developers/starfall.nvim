local config = require("starfall.config")
local engine = require("starfall.engine")
local highlights = require("starfall.highlights")

local M = {}

M.config = vim.deepcopy(config.defaults)

---@param opts StarfallConfig|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), opts or {})
  highlights.setup(M.config)

  local augroup = vim.api.nvim_create_augroup("Starfall", { clear = true })

  -- Highlight groups get wiped on colorscheme changes; redefine them.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      highlights.setup(M.config)
    end,
  })

  -- Make sure the animation timer never outlives the editor session.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      engine.stop()
    end,
  })

  vim.api.nvim_create_user_command("StarfallStart", function()
    engine.start(M.config)
  end, { desc = "Start the starfall twinkling/falling star animation" })

  vim.api.nvim_create_user_command("StarfallStop", function()
    engine.stop()
  end, { desc = "Stop the starfall animation and clear all stars" })

  vim.api.nvim_create_user_command("StarfallToggle", function()
    if engine.is_active() then
      engine.stop()
    else
      engine.start(M.config)
    end
  end, { desc = "Toggle the starfall animation" })
end

return M
