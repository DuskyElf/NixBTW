require("hot.options")
require("hot.keybinds")

require("mini.statusline").setup {
  use_icons = true
}

vim.api.nvim_create_autocmd("TextYankPost", {
  desc = "Highlight when yanking (copying) text",
  group = vim.api.nvim_create_augroup("kickstart-highlight-yank", { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function(args)
    pcall(function() vim.treesitter.stop(args.buf) end)
  end
})

