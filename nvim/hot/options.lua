vim.cmd [[
  highlight Normal guibg=none ctermbg=none
  highlight NormalNC guibg=none ctermbg=none
  highlight SignColumn guibg=none ctermbg=none
  highlight VertSplit guibg=none ctermbg=none
  highlight StatusLine guibg=none ctermbg=none
  highlight LineNr guibg=none ctermbg=none
  highlight EndOfBuffer guibg=none ctermbg=none
  highlight LineNrAbove guibg=none ctermbg=none
  highlight LineNrBelow guibg=none ctermbg=none
  highlight MsgArea guibg=none ctermbg=none
]] -- To make the window transparent

vim.o.number = true
vim.o.relativenumber = true

vim.o.scrolloff = 10
vim.o.signcolumn = "yes"
vim.g.have_nerd_font = true
vim.o.showmode = false -- using mini.status

vim.o.list = true
vim.opt.listchars = { tab = "»-", trail = "", nbsp = "␣" }

vim.o.shiftwidth = 4
vim.o.undofile = true
vim.o.breakindent = true
vim.o.timeoutlen = 300
vim.o.updatetime = 1000

vim.o.inccommand = "split"
vim.o.ignorecase = true
vim.o.smartcase = true

vim.o.mouse = "a"
vim.o.confirm = true
vim.o.splitright = true
vim.o.splitbelow = true

