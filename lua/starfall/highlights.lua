local M = {}

-- Builds/refreshes all Starfall highlight groups from the user's config.
-- Safe to call repeatedly (e.g. on ColorScheme reload).
---@param cfg StarfallConfig
function M.setup(cfg)
  for i, color in ipairs(cfg.colors) do
    vim.api.nvim_set_hl(0, "StarfallColor" .. i, {
      fg = color,
      bold = true,
      default = true,
    })
  end

  vim.api.nvim_set_hl(0, "StarfallFallingHead", {
    fg = cfg.falling_color,
    bold = true,
    default = true,
  })

  -- Trail highlights fade from bright (closest to head) to dim (oldest).
  vim.api.nvim_set_hl(0, "StarfallTrail1", { fg = cfg.falling_color, default = true })
  vim.api.nvim_set_hl(0, "StarfallTrail2", { fg = "#9a9a9a", default = true })
  vim.api.nvim_set_hl(0, "StarfallTrail3", { fg = "#4d4d4d", default = true })
end

---Returns the highlight group name for the i-th palette color.
function M.color_group(i)
  return "StarfallColor" .. i
end

return M
