--- popup.lua
---
--- Wrapper to make the popup api from vim in neovim.
--- Hope to get this part merged in at some point in the future.
---
--- Please make sure to update "POPUP.md" with any changes and/or notes.

local Window = require "plenary.window"
local utils = require "plenary.popup.utils"
-- TODO: local bit = require("bit")

local if_nil = vim.F.if_nil

local popup = {}

-- translate vim's "pos" to neovim's "anchor".
-- Include x/y (col/row) adjust becacuse nvim's anchor is a point, not a cell.
popup._pos_map = {
  topleft = {"NW", 0, 0},
  topright = {"NE", 1, 0},
  botleft = {"SW", 0, 1},
  botright = {"SE", 1, 1},
}

local neovim_passthru = {
  "title",
  "title_pos",
  "footer",
  "footer_pos",
}

----------------------------------------------------------------------------------
-- TODO:  Some state is saved when set through this interface.                  --
--        NeedToDocument: changes made to window parameters not throught popup  --
--        may interfere with correct operation.                                 --
----------------------------------------------------------------------------------

-- State info of each active popup; each entry is a table for the given popup.
-- Indexed by win_id. See popup_win_closed.
-- Use win_id as key to check if win_id is an active popup.
--      POPUP-ITEM: win_id self reference
--      POPUP-ITEM: vim_options popup create/config options
--      POPUP-ITEM: result any Value to pass to callback
--      POPUP-ITEM: extras any Calculated values useful for later calculations
--      POPUP-ITEM: callback? function(id?:integer, result?:any)
--      POPUP-ITEM: ns_id? namespace for on_key callback
popup._popups = {}

-- ===========================================================================
--
-- popup mouse event handling
--

local mp_press  -- mousepos when press
local drag_start_win_x
local drag_start_win_y
local is_drag = nil   -- nil no drag events; false not dragging a popup
local win_id_press = nil

local function mouse_cb(event)
  local msg = ""
  local function output_msg(msgx)
    if not msgx then msgx = msg end
    --vim.print(string.format("popup: mouse_cb: %s: '%s'", event, msgx))
  end

  local mp = vim.fn.getmousepos()
  local pup

  if event == "<LeftMouse>" then
    win_id_press = mp.winid
    pup = popup._popups[win_id_press]
    mp_press = mp
    is_drag = nil

    output_msg(vim.inspect({mp.screencol, mp.screenrow}))
    -- popup: mouse_cb: <LeftMouse>: '{ 30, 16 }'
    local xx = popup.getpos(win_id_press)
    output_msg(string.format("x,y (%d,%d) w,h (%d,%d)",xx.col, xx.line, xx.width, xx.height))
    -- popup: mouse_cb: <LeftMouse>: 'x,y (20,10) w,h (11,7)'

    return output_msg()
  elseif win_id_press then
    pup = popup._popups[win_id_press]
  end

  if not pup then
    return
  end

  if event == "<LeftRelease>" then
    -- If is_drag is nil then the mouse hasn't moved since the mouse press.
    if is_drag == nil then
      if pup.vim_options.close == "click" then
        popup.close(pup.win_id, -2)
      elseif pup.vim_options.close == "button" and pup.extras.button_close_pad ~= nil
            and mp.winrow == 1
            and mp.wincol == (vim.api.nvim_win_get_width(pup.win_id)
                          + pup.extras.button_close_pad) then
        popup.close(pup.win_id, -2)
      end
    end
      -- vim.print(string.format("popup: button: %s: %d %d",
      --     event, mp.wincol, vim.api.nvim_win_get_width(pup.win_id)))

    -- cautious
    is_drag = nil
    win_id_press = nil
    return output_msg()
  end

  -- (x,y) distance from "loc" to mouse pos; loc default to mp_press
  ---@param loc? table as returned from mousepos, only screencol/screenrow used
  local function delta(loc)
    loc = loc or mp_press
    if loc == nil then
      return 123456, 123456
    else
      return mp.screencol - loc.screencol, mp.screenrow - loc.screenrow
    end
  end

  -- is the mouse press on a border
  local function on_border()
    -- Need to check each edge separately
    local win_pos = popup.getpos(win_id_press)
    local on_edge = {} -- do in top/left/bot/right
    on_edge[#on_edge+1] = mp_press.screenrow == win_pos.line
    on_edge[#on_edge+1] = mp_press.screencol == win_pos.col + win_pos.width - 1
    on_edge[#on_edge+1] = mp_press.screenrow == win_pos.line + win_pos.height - 1
    on_edge[#on_edge+1] = mp_press.screencol == win_pos.col
    local thickness = pup.extras.border_thickness
    local drag_ok = false
    for i = 1, 4 do
      if on_edge[i] and thickness[i] ~= 0 then
        drag_ok = true
        break;
      end
    end
    -- vim.print(string.format("drag_ok %s. edge %s, border %s",
    --     drag_ok, vim.inspect(on_edge), vim.inspect(pup.extras.border_thickness)))
    return drag_ok
  end

  -- note: win_id_press should be something
  if event == "<LeftDrag>" then
    if is_drag == nil then
      -- first drag event since press
      if pup.vim_options.dragall or pup.vim_options.drag and on_border() then
        is_drag = true
        drag_start_win_x,drag_start_win_y = popup._getxy(win_id_press)
      else
        is_drag = false
      end
    end
    output_msg(string.format("is_drag %s", is_drag))
    if is_drag == false then
      return
    end
    local x,y = delta()
    popup.move(win_id_press, {col = x + drag_start_win_x, line = y + drag_start_win_y})
    msg = string.format("(%d,%d) (%d, %d) %d", x, y,
                        x + drag_start_win_x, y + drag_start_win_y, mp.winid)
    return output_msg()
  end
end

-- ===========================================================================
--
-- popup filter handling
--

-- If a popup needs a filter, then the popup gets it's own namespace and on_key listener.
-- Don't need a listener for a hidden popup.
-- return a function as needed.

-- TODO:  While 1 on_key per popup is simpler, in the case of multiple popups
--        they're supposed to be invoked in zindex order. That may require
--        one listener that multicasts.
--
--        Keep list of popups' win_id sorted by zindex. spin through that
--        to dispatch.

-- see table at end of this file
local mode_to_short_mode

-- Check if current mode is specified in filtermode
--    1. Convert the return of "mode()" to a single char mode as used in filtermode.
--    2. If single char found check against filtermode 
--    3.    Check if found
local function mode_match(filtermode_match)
  local current_mode = vim.fn.mode()
  -- string.find(xxx, current_mode) == 1
  local short_mode = mode_to_short_mode[current_mode]
  -- TODO: Not sure there's a good fix for the possibility that new modes may b added.
  -- If it's a new mode not handled then just use the first character.
  short_mode = short_mode or current_mode:sub(1,1)
  return filtermode_match:find(short_mode) ~= nil
end

---Convert a filtermode designation, to unique modes.
---Basically, if filtermode has an "v", then add "x" and "s" to the mode
---@param filtermode string specified by popup configuration
---@return string filtermode to check for filter dispatch
local function convert_to_mode_match_string(filtermode)
  return filtermode .. (filtermode:find("v") and "xs" or "")
end

---@return function that invokes popup's filter, used as on_key callback.
local function create_on_key_cb(pup, mapping)
  local win_id = pup.win_id
  local filter = pup.vim_options.filter
  local filtermode = pup.vim_options.filtermode
  -- TODO: could have 4 cases since "mapping" is constant while on_key fn lives.
  -- TODO: I think construct string and then "loadstring" for optimal...
  if not filtermode or string.find(filtermode, "a") then
    -- Since all modes, just invoke the filter.
    return function(key, typed)
      local filter_key = mapping and key or typed
      if #filter_key ~= 0 then
        return filter(win_id, filter_key)
      else
        return false
      end
    end
  else
    local filtermode_match = convert_to_mode_match_string(filtermode)
    -- Only invoke the filter if the right mode.
    return function(key, typed)
      local filter_key = mapping and key or typed
      if mode_match(filtermode_match) and #filter_key ~= 0 then
        return filter(win_id, filter_key)
      else
        return false
      end
    end
  end
end

-- TODO: may want to set a re_filter flag indicating a new filter should be constructed

-- This is called after a popup is created or changed and, if needed, recreates on_key_cb.
-- Note that when a popup is closed, the on_key callback is removed.
-- TODO: does this need to be "scheduled"? Probably, maybe better scheduled only when needed.
local function setup_on_key_cb(win_id)
  local pup = popup._popups[win_id]
  local vim_options = pup.vim_options

  -- Only a visible popup needs a filter. Note must use popup.hide/show.
  local hidden = vim.api.nvim_win_get_config(win_id).hide

  if not hidden and vim_options.filter then
    pup.ns_id = pup.ns_id or vim.api.nvim_create_namespace("")
    local on_key_opts = {
      may_discard = true,
    }
    -- default mapping to true
    on_key_opts.allow_mapping = not (vim_options.mapping == false)
    vim.on_key(create_on_key_cb(pup, on_key_opts.allow_mapping), pup.ns_id, on_key_opts)
  elseif pup.ns_id then
    vim.on_key(nil, pup.ns_id)
  end
end

local function dict_default(options, key, default)
  if options[key] == nil then
    return default[key]
  else
    return options[key]
  end
end

-- ===========================================================================
--
-- popup close handling
--

--- Closes the popup window
--- Adapted from vim.lsp.util.close_preview_autocmd
---
---@param winnr integer window id of popup window
---@param bufnrs table|nil optional list of ignored buffers
local function close_window_for_aucmd(winnr, bufnrs)
  vim.schedule(function()
    -- exit if we are in one of ignored buffers
    if bufnrs and vim.list_contains(bufnrs, vim.api.nvim_get_current_buf()) then
      return
    end

    local augroup = "popup_window_" .. winnr
    pcall(vim.api.nvim_del_augroup_by_name, augroup)
    pcall(vim.api.nvim_win_close, winnr, true)
  end)
end

--- Creates autocommands to close a popup window when events happen.
---
---@param events table list of events
---@param winnr integer window id of popup window
---@param bufnrs table list of buffers where the popup window will remain visible, {popup, parent}
---@see autocmd-events
local function close_window_autocmd(events, winnr, bufnrs)
  local augroup = vim.api.nvim_create_augroup("popup_window_" .. winnr, {
    clear = true,
  })

  -- close the popup window when entered a buffer that is not
  -- the floating window buffer or the buffer that spawned it
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      close_window_for_aucmd(winnr, bufnrs)
    end,
  })

  if #events > 0 then
    vim.api.nvim_create_autocmd(events, {
      group = augroup,
      buffer = bufnrs[2],
      callback = function()
        close_window_for_aucmd(winnr)
      end,
    })
  end
end
--- End of code adapted from vim.lsp.util.close_preview_autocmd

--- Only used from 'WinClosed' autocommand
--- Cleanup after popup window closes.
---@param win_id integer window id of popup window
local function popup_win_closed(win_id)
  -- Invoke the callback with the win_id and result.
  local pup = popup._popups[win_id]
  if pup.ns_id then
    -- Remove an on_key filter.
    vim.on_key(nil, pup.ns_id)
  end
  if pup.callback then
    pcall(pup.callback, win_id, pup.result)
  end
  -- Forget about this window.
  popup._popups[win_id] = nil
end

-- ===========================================================================
--
-- popup positioning
--

-- Convert the positional {vim_options} to compatible neovim options and add them to {win_opts}
-- If an option is not given in {vim_options}, fall back to {default_opts}
local function add_position_config(win_opts, vim_options, default_opts)
  default_opts = default_opts or {}

  local cursor_relative_pos = function(pos_str, dim)
    assert(string.find(pos_str, "^cursor"), "Invalid value for " .. dim)
    win_opts.relative = "cursor"
    local line = 0
    if (pos_str):match "cursor%+(%d+)" then
      line = line + tonumber((pos_str):match "cursor%+(%d+)")
    elseif (pos_str):match "cursor%-(%d+)" then
      line = line - tonumber((pos_str):match "cursor%-(%d+)")
    end
    return line
  end

  -- Feels like maxheight, minheight, maxwidth, minwidth will all be related
  --
  -- maxheight  Maximum height of the contents, excluding border and padding.
  -- minheight  Minimum height of the contents, excluding border and padding.
  -- maxwidth  Maximum width of the contents, excluding border, padding and scrollbar.
  -- minwidth  Minimum width of the contents, excluding border, padding and scrollbar.
  local width = if_nil(vim_options.width, default_opts.width)
  local height = if_nil(vim_options.height, default_opts.height)
  win_opts.width = utils.bounded(width, vim_options.minwidth, vim_options.maxwidth)
  win_opts.height = utils.bounded(height, vim_options.minheight, vim_options.maxheight)

  if vim_options.line and vim_options.line ~= 0 then
    if type(vim_options.line) == "string" then
      win_opts.row = cursor_relative_pos(vim_options.line, "row")
    else
      win_opts.row = vim_options.line - 1
    end
  else
    -- center "y"
    win_opts.row = math.floor((vim.o.lines - win_opts.height) / 2)
  end

  if vim_options.col and vim_options.col ~= 0 then
    if type(vim_options.col) == "string" then
      win_opts.col = cursor_relative_pos(vim_options.col, "col")
    else
      win_opts.col = vim_options.col - 1
    end
  else
    -- center "x"
    win_opts.col = math.floor((vim.o.columns - win_opts.width) / 2)
  end

  -- TODO:  BUG? in FOLLOWING code, if "center", sets line/col to 0/0,
  --        in ABOVE code if line or col is 0, then that gets centered.
  --        Looks like it's OUT OF ORDER.
  --        Also, if "center" need to move the row/col to account for the anchor.

  -- pos
  --
  -- The "pos" field defines what corner of the popup "line" and "col" are used
  -- for. When not set "topleft" behaviour is used. "center" positions the popup
  -- in the center of the Neovim window and "line"/"col" are ignored.
  if vim_options.pos then
    if vim_options.pos == "center" then
      vim_options.line = 0
      vim_options.col = 0
      win_opts.anchor = "NW"
    else
      local pos = popup._pos_map[vim_options.pos]
      win_opts.anchor = pos[1]
      -- Neovim uses a point, not a cell. Adjust col/row so the anchor corner
      -- covers the indicated cell.
      win_opts.col = win_opts.col + pos[2]
      win_opts.row = win_opts.row + pos[3]
    end
  else
    win_opts.anchor = "NW" -- This is the default, but makes `posinvert` easier to implement
  end

  -- , fixed    When FALSE (the default), and:
  -- ,      - "pos" is "botleft" or "topleft", and
  -- ,      - "wrap" is off, and
  -- ,      - the popup would be truncated at the right edge of
  -- ,        the screen, then
  -- ,     the popup is moved to the left so as to fit the
  -- ,     contents on the screen.  Set to TRUE to disable this.
end

-- ===========================================================================
--
-- popup border handling
--

--- Convert a vim border spec into a nvim border spec.
--- If no borderchars, then border is directly passed to window configuration,
--- so can use the full neovim border spec.

---
--- @param vim_options { }
--- @param win_opts { }
--- @param extras { }
local function translate_border(win_opts, vim_options, extras)
  if not vim_options.border or vim_options.border == "none" then
    extras.border_thickness = { 0, 0, 0, 0}
    return
  end
  if type(vim_options.border) == "string" then
    -- TODO: convert to border chars instead of string, then "X" close can work.
    win_opts.border = vim_options.border  -- allow neovim border style name
    extras.border_thickness = { 1, 1, 1, 1}
    return
  end

  local win_border

  -- set border_thickness if border is an array of 4 or less numbers
  -- If border is an array of 4 numbers or less, then it's vim's border thickness
  local border_thickness = { 1, 1, 1, 1}

  if vim_options.border and type(vim_options.border) == "table" then
    local next_idx = 1  -- first thickness value goes here
    for idx, thick in pairs(vim_options.border) do
      if type(idx) ~= "number" or type(thick) ~= "number" or idx ~= next_idx then
        border_thickness = { 0, 0, 0, 0}
        break
      end
      border_thickness[idx] = thick
      if idx == 4 then
        break
      end
      next_idx = next_idx + 1
    end
  end
  extras.border_thickness = border_thickness

  -- Use "borderchars" to build 8 char array. Want all 8 characters since it
  -- is adjusted when a border_thickness is zero to turn off an edge.
  if vim_options.borderchars then
    win_border = {}
    -- neovim: the array specifies the eight chars building up the border in
    -- a clockwise fashion starting with the top-left corner. The double box
    -- style could be specified as: [ "╔", "═" ,"╗", "║", "╝", "═", "╚", "║" ].
    if #vim_options.borderchars == 1 then
      -- use the same char for everything, list of length 1
      for i = 1, 8 do
        win_border[i] = vim_options.borderchars[1]
      end
    elseif #vim_options.borderchars == 2 then
      -- vim: [ borders, corners ]; neovim: repeat [ corner, border ]
      for i = 0, 3 do
        win_border[(i*2)+1] = vim_options.borderchars[2]
        win_border[(i*2)+2] = vim_options.borderchars[1]
      end
    elseif #vim_options.borderchars == 4 then
      -- vim: top/right/bottom/left border. Default corners.
      local corners = { "╔", "╗", "╝", "╚" }
      for i = 1, 4 do
        win_border[#win_border+1] = corners[i]
        win_border[#win_border+1] = vim_options.borderchars[i]
      end
    elseif #vim_options.borderchars == 8 then
      -- vim: top/right/bottom/left / topleft/topright/botright/botleft
      win_border[1] = vim_options.borderchars[5]
      win_border[2] = vim_options.borderchars[1]
      win_border[3] = vim_options.borderchars[6]
      win_border[4] = vim_options.borderchars[2]
      win_border[5] = vim_options.borderchars[7]
      win_border[6] = vim_options.borderchars[3]
      win_border[7] = vim_options.borderchars[8]
      win_border[8] = vim_options.borderchars[4]
    else
      assert(false, string.format("Invalid number of 'borderchars': '%s'",
          vim.inspect(vim_options.borderchars)))
    end
  else
    win_border = { "╔", "═" ,"╗", "║", "╝", "═", "╚", "║" }
  end

  -- Turn off the borderchars for any side that has 0 thickness.
  -- In "win_border", a side's index start at 1, 3, 5, 7 and is 3 characters.
  for idx, is_border_present in ipairs(border_thickness) do
    if is_border_present == 0 then
      -- start_char is zero based so simplify the wraparound logic
      local start_char = (idx - 1) * 2
      for i = start_char, start_char + 2 do
        win_border[(i % 8) + 1] = ""
      end
    end
  end

  win_opts.border = win_border
end

-- ===========================================================================
--
-- popup API
--

function popup.create(what, vim_options)
  vim_options = vim.deepcopy(vim_options)
  local win_opts = {}
  local extras = {}

  local bufnr
  if type(what) == "number" then
    bufnr = what
    extras.line_count = vim.api.nvim_buf_line_count(bufnr)
  else
    bufnr = vim.api.nvim_create_buf(false, true)
    assert(bufnr, "Failed to create buffer")

    vim.api.nvim_set_option_value("bufhidden", "wipe", {buf = bufnr})
    vim.api.nvim_set_option_value("modifiable", true, {buf = bufnr})

    -- TODO: Handle list of lines
    if type(what) == "string" then
      what = { what }
    else
      assert(type(what) == "table", '"what" must be a table')
    end
    extras.line_count = #what

    -- padding    List with numbers, defining the padding
    --     above/right/below/left of the popup (similar to CSS).
    --     An empty list uses a padding of 1 all around.  The
    --     padding goes around the text, inside any border.
    --     Padding uses the 'wincolor' highlight.
    --     Example: [1, 2, 1, 3] has 1 line of padding above, 2
    --     columns on the right, 1 line below and 3 columns on
    --     the left.
    if vim_options.padding then
      local pad_top, pad_right, pad_below, pad_left
      if vim.tbl_isempty(vim_options.padding) then
        pad_top = 1
        pad_right = 1
        pad_below = 1
        pad_left = 1
      else
        local padding = vim_options.padding
        pad_top = padding[1] or 0
        pad_right = padding[2] or 0
        pad_below = padding[3] or 0
        pad_left = padding[4] or 0
      end
      extras.padding = { pad_top, pad_right, pad_below, pad_left }

      local left_padding = string.rep(" ", pad_left)
      local right_padding = string.rep(" ", pad_right)
      for index = 1, #what do
        what[index] = string.format("%s%s%s", left_padding, what[index], right_padding)
      end

      for _ = 1, pad_top do
        table.insert(what, 1, "")
      end

      for _ = 1, pad_below do
        table.insert(what, "")
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, what)
  end
  if not extras.padding then
    extras.padding = { 0, 0, 0, 0 }
  end


  local option_defaults = {
    posinvert = true,
    zindex = 50,
  }

  vim_options.width = if_nil(vim_options.width, 1)
  if type(what) == "number" then
    vim_options.height = vim.api.nvim_buf_line_count(what)
  else
    for _, v in ipairs(what) do
      vim_options.width = math.max(vim_options.width, #v)
    end
    vim_options.height = #what
  end

  win_opts.relative = "editor"
  win_opts.style = "minimal"

  -- Some neovim fields are simply copied.
  -- title/footer.
  for _, field in ipairs(neovim_passthru) do
    win_opts[field] = vim_options[field]
  end

  win_opts.hide = vim_options.hidden

  -- noautocmd, undocumented vim default per https://github.com/vim/vim/issues/5737
  win_opts.noautocmd = if_nil(vim_options.noautocmd, true)

  -- focusable,
  -- vim popups are not focusable windows
  win_opts.focusable = if_nil(vim_options.focusable, false)

  -- add positional and sizing config to win_opts
  add_position_config(win_opts, vim_options, { width = 1, height = 1 })

  -- -- Set up the border.
  translate_border(win_opts, vim_options, extras)

  -- set up for "close == button"
  if vim_options.close == "button" then
    -- TODO: at some point win_opts.border will have been converted to array
    -- With neovim style borders can't just change a border.
    if type(win_opts.border) ~= "string" then
      if win_opts.border and win_opts.border[3] ~= "" then
        -- There's a top-right border corner.
        win_opts.border[3] = "X"
        -- Need to add left+right border to column column size for checking.
        extras.button_close_pad = extras.border_thickness[2] + extras.border_thickness[4]
      elseif extras.border_thickness[1] == 0 and extras.border_thickness[2] == 0 then
        -- There's no border on top or right, overlay the buffer.
        vim.api.nvim_buf_set_extmark(bufnr, vim.api.nvim_create_namespace(""), 0, 0, {
          virt_text = { { "X", "" } },
          virt_text_pos = "right_align",
        })
        extras.button_close_pad = 0
      end
      -- NOTE: if extras.button_close_pad is nil, then "button" can't be handled.
    end
  end


  -- posinvert, When FALSE the value of "pos" is always used.  When
  -- ,   TRUE (the default) and the popup does not fit
  -- ,   vertically and there is more space on the other side
  -- ,   then the popup is placed on the other side of the
  -- ,   position indicated by "line".
  if dict_default(vim_options, "posinvert", option_defaults) then
    if win_opts.anchor == "NW" or win_opts.anchor == "NE" then
      if win_opts.row + win_opts.height > vim.o.lines and win_opts.row * 2 > vim.o.lines then
        -- Don't know why, but this is how vim adjusts it
        win_opts.row = win_opts.row - win_opts.height - 2
      end
    elseif win_opts.anchor == "SW" or win_opts.anchor == "SE" then
      if win_opts.row - win_opts.height < 0 and win_opts.row * 2 < vim.o.lines then
        -- Don't know why, but this is how vim adjusts it
        win_opts.row = win_opts.row + win_opts.height + 2
      end
    end
  end

  -- textprop, When present the popup is positioned next to a text
  -- ,   property with this name and will move when the text
  -- ,   property moves.  Use an empty string to remove.  See
  -- ,   |popup-textprop-pos|.
  -- related:
  --   textpropwin
  --   textpropid

  -- zindex, Priority for the popup, default 50.  Minimum value is
  -- ,   1, maximum value is 32000.
  local zindex = dict_default(vim_options, "zindex", option_defaults)
  win_opts.zindex = utils.bounded(zindex, 1, 32000)
  vim_options.zindex = win_opts.zindex -- save this for sorting

  -- Install a mouse handler.
  -- TODO: could only install the handler if it's needed.
  win_opts.mouse = mouse_cb

  local win_id = vim.api.nvim_open_win(bufnr, false, win_opts)

  -- Set the default result. The table keys also indicate active popups.
  -- Also keep track of all the options; they may be used for other functions.
  popup._popups[win_id] = {
    win_id = win_id,    -- for convenience
    result = -1,
    extras = extras,
    vim_options = vim_options,
    -- win_opts = win_opts,          -- may not need
  }

  -- Always catch the popup's close
  local augroup = vim.api.nvim_create_augroup("popup_close_" .. win_id, {
    clear = true,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win_id),
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_name, augroup)
      popup_win_closed(win_id)
    end,
  })

  -- Moved, handled after since we need the window ID
  if vim_options.moved then
    if vim_options.moved == "any" then
      close_window_autocmd({ "CursorMoved", "CursorMovedI" }, win_id, { bufnr, vim.fn.bufnr() })
      -- TODO:  Calculate and set a boundary; if the cursor moves outside that
      --        boundary then close. This should handle all the cases.
      --[[
      else
        --   TODO: Handle word, WORD, expr, and the range functions... which seem hard?
        assert(false, "moved ~= 'any': not implemented yet and don't know how")
      ]]
    end
  else
    -- TODO: If the buffer's deleted close the window. Is this needed?
    local silent = false
    vim.cmd(
      string.format(
        "autocmd BufDelete %s <buffer=%s> ++once ++nested :lua require('plenary.window').try_close(%s, true)",
        (silent and "<silent>") or "",
        bufnr,
        win_id
      )
    )
  end

  if vim_options.time then
    local timer = vim.uv.new_timer()
    timer:start(
      vim_options.time,
      0,
      -- TODO: investigate the wrap
      vim.schedule_wrap(function()
          --Window.try_close(win_id, false)
          popup.close(win_id)
      end)
    )
  end

  -- Window and Buffer Options

  if vim_options.cursorline then
    vim.api.nvim_set_option_value("cursorline", true, { win = win_id })
  end

  -- Window's "wrap" defaults to true, nothing to do if no "wrap" option.
  if vim_options.wrap ~= nil then
    -- set_option wrap should/will trigger autocmd, see https://github.com/neovim/neovim/pull/13247
    if vim_options.noautocmd then
      vim.cmd(string.format("noautocmd lua vim.api.nvim_set_option(%s, wrap, %s)", win_id, vim_options.wrap))
    else
      vim.api.nvim_set_option_value("wrap", vim_options.wrap, { win = win_id })
    end
  end

  -- ===== Not Implemented Options =====
  -- See POPUP.md
  --
  -- flip: not implemented at the time of writing
  -- Mouse:
  --    mousemoved: no idea how to do the things with the mouse, so it's an exercise for the reader.
  --    resize: mouses are hard
  --    close: partially implemented
  --
  -- scrollbar
  -- scrollbarhighlight
  -- thumbhighlight

  -- tabpage: seems useless


  -- ---------------------------------------- TODO: highlight handling

  -- TODO: borderhighlight

  -- borderhighlight List of highlight group names to use for the border.
  --                 When one entry it is used for all borders, otherwise
  --                 the highlight for the top/right/bottom/left border.
  --                 Example: ['TopColor', 'RightColor', 'BottomColor,
  --                 'LeftColor']

  -- border_options.highlight = vim_options.borderhighlight
  --               and string.format("Normal:%s", vim_options.borderhighlight)
  -- border_options.titlehighlight = vim_options.titlehighlight

  -- ---------------------------------------- TODO: highlight handling

  if vim_options.highlight then
    vim.api.nvim_set_option_value(
      "winhl",
      string.format("Normal:%s,EndOfBuffer:%s", vim_options.highlight, vim_options.highlight),
      { win = win_id }
    )
  end

  -- enter

  if vim_options.enter then
    -- set focus after border creation so that it's properly placed (especially
    -- in relative cursor layout)
    if vim_options.noautocmd then
      vim.cmd("noautocmd lua vim.api.nvim_set_current_win(" .. win_id .. ")")
    else
      vim.api.nvim_set_current_win(win_id)
    end
  end

  -- callback
  if vim_options.callback then
    local pup = popup._popups[win_id]
    pup.callback = vim_options.callback
  end

  setup_on_key_cb(win_id)

  -- TODO: Remove this, if async related, then should not be part of popup.
  -- TODO: Wonder what this is about? Debug? Convenience to get bufnr?
  if vim_options.finalize_callback then
    vim_options.finalize_callback(win_id, bufnr)
  end

  return win_id
end

--- Close the specified popup window; the "result" is available through callback.
--- Do nothing if there is no such popup with the specified id.
---
---@param win_id integer window id of popup window
---@param result any? value to return in a callback
function popup.close(win_id, result)
  -- Only save the result if there is a popup with that window id.
  local pup = popup._popups[win_id]
  if pup == nil then
    return
  end
  -- update the result as specified
  if result == nil then
    result = 0
  end

  pup.result = result
  Window.try_close(win_id, true)
end

--- Return list of window id of existing popups
---
---@return integer[]
function popup.list()
  local ids = {}
  for win_id, _ in pairs(popup._popups) do
    if type(win_id) == 'number' then
      ids[#ids+1] = win_id
    end
  end
  return ids
end

--- Close all popup windows
---
--- @param force? boolean
function popup.clear(force)
  local cur_win_id = vim.fn.win_getid()
  if popup._popups[cur_win_id] and not force then
    assert(false, "Not allowed in a popup window")
    return
  end
  for win_id, _ in pairs(popup._popups) do
    if type(win_id) == 'number' then
      local pup = popup._popups[win_id]
      -- no callback when clear
      pup.callback = nil
      Window.try_close(win_id, true)
    end
  end
end


--- Hide the popup.
--- If win_id does not exist nothing happens.  If win_id
--- exists but is not a popup window an error is given.
---
---@param win_id integer window id of popup window
function popup.hide(win_id)
  if not vim.api.nvim_win_is_valid(win_id) then
    return
  end
  local pup = popup._popups[win_id]
  assert(pup ~= nil, "popup.hide: not a popup window")
  vim.api.nvim_win_set_config(win_id, { hide = true })
  setup_on_key_cb(win_id)
end

--- Show the popup.
--- Do nothing if non-existent window or window not a popup.
---
---@param win_id integer show the popup with this win_id
function popup.show(win_id)
  local pup = popup._popups[win_id]
  if not vim.api.nvim_win_is_valid(win_id) or not pup then
    return
  end
  vim.api.nvim_win_set_config(win_id, { hide = false })
  setup_on_key_cb(win_id)
end

-- Move popup with window id {win_id} to the position specified with {vim_options}.
-- {vim_options} may contain the following items that determine the popup position/size:
-- - line
-- - col
-- - pos
-- - height
-- - width
-- - max/min width/height
-- Unspecified options correspond to the current values for the popup.
--
-- Unimplemented vim options here include: fixed
--
function popup.move(win_id, vim_options)
  local pup = popup._popups[win_id]
  if not pup then
    return
  end
  vim_options = vim.deepcopy(vim_options)
  local cur_vim_options = pup.vim_options

  -- Create win_options
  local win_opts = {}
  win_opts.relative = "editor"

  -- width/height can not be set with "popup_move", use current values
  vim_options.width = vim.api.nvim_win_get_width(win_id)
  vim_options.height = vim.api.nvim_win_get_height(win_id)

  local current_pos = vim.api.nvim_win_get_position(win_id)
  vim_options.line = vim_options.line or (current_pos[1] + 1)
  vim_options.col = vim_options.col or (current_pos[2] + 1)

  -- Use specified option if set; otherwise the current value; save to current.
  local function fixopt(field)
    vim_options[field] = vim_options[field] or cur_vim_options[field]
    cur_vim_options[field] = vim_options[field]
  end
  fixopt("minheight")
  fixopt("maxheight")
  fixopt("minwidth")
  fixopt("maxwidth")

  -- Add positional and sizing config to win_opts
  add_position_config(win_opts, vim_options)

  -- Update content window
  vim.api.nvim_win_set_config(win_id, win_opts)
end

-- TODO:  "popup.setoptions" is tricky, need to refactor some of popup.create.
--
--        Consider changing padding
--
--function popup.setoptions(win_id)
--end


--
-- Notice
--       vim-win     == neovim + border
--       vim-core    == neovim - padding
--
--       neovim + border ==  vim-win
--       neovim          ==  vim-core + padding
--

---@return integer x
---@return integer y
function popup._getxy(win_id)
  local position = vim.api.nvim_win_get_position(win_id)
  return position[2] + 1, position[1] + 1
end

--- The "core_*" fields are the original text boundaries without padding or border.
--- The width/height fields include border and padding. nvim_win_get_config does
--- not include border.
--- Positional values are converted to 1 based.
---
function popup.getpos(win_id)
  local pup = popup._popups[win_id]
  if not pup then
    return {}
  end
  local extras = pup.extras
  --local win_opts = pup.win_opts
  local config = vim.api.nvim_win_get_config(win_id)
  local position = vim.api.nvim_win_get_position(win_id)
  local col = position[2] + 1
  local line = position[1] + 1
  local ret = {
    col = col,
    line = line,
    -- width/height include the border in the "popup in screen cells"
    width = config.width + extras.border_thickness[2] + extras.border_thickness[4],
    height = config.height + extras.border_thickness[1] + extras.border_thickness[3],

    -- offset "core_col" by border/padding on the left
    core_col = col + extras.border_thickness[4] + extras.padding[4],
    -- offset "core_line" by border/padding on the top
    core_line = line + extras.border_thickness[1] + extras.padding[1],
    -- core_width/core_height do not include padding
    core_width = config.width - extras.padding[2] - extras.padding[4],
    core_height = config.height - extras.padding[1] - extras.padding[3],

    visible = not config.hide,

    -- TODO: just throw some stuff in for scrollbar/first/last
    scrollbar = false,
    firstline = 1,
    lastline = extras.line_count,
  }
  return ret
end

mode_to_short_mode = {
["n"]        = "n",

["no"]       = "o",
["nov"]      = "o",
["noV"]      = "o",
["noCTRL-V"] = "o",

["niI"]      = "n",
["niR"]      = "n",
["niV"]      = "n",
["nt"]       = "n",
["ntT"]      = "n",

["v"]        = "x",
["vs"]       = "x",
["V"]        = "x",
["Vs"]       = "x",
["CTRL-V"]   = "x",
["CTRL-Vs"]  = "x",

["s"]        = "s",
["S"]        = "s",
["CTRL-S"]   = "s",

["i"]        = "i",
["ic"]       = "i",
["ix"]       = "i",
["R"]        = "i",
["Rc"]       = "i",
["Rx"]       = "i",
["Rv"]       = "i",
["Rvc"]      = "i",
["Rvx"]      = "i",

["c"]        = "c",
["cr"]       = "c",
["cv"]       = "c",
["cvr"]      = "c",
["r"]        = "c",
["rm"]       = "c",
["r?"]       = "c",
["!"]        = "c",

["t"]        = "l",
}

return popup
