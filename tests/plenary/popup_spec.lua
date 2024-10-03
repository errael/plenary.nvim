local popup = require "plenary.popup"

local eq = assert.are.same

describe("plenary.popup", function()
  before_each(function()
    vim.cmd [[highlight PopupColor1 ctermbg=lightblue guibg=lightblue]]
    vim.cmd [[highlight PopupColor2 ctermbg=lightcyan guibg=lightcyan]]
  end)

  -- TODO: Probably want to clear all the popups between iterations
  -- after_each(function() end)

  it("can create a very simple window", function()
    local win_id = popup.create("hello there", {
      line = 1,
      col = 1,
      width = 20,
    })

    local win_config = vim.api.nvim_win_get_config(win_id)
    eq(20, win_config.width)
    local border = win_config.border
    border = border == nil and "none" or border
    assert(border == "none", "Should not have a border")
  end)

  it("can create a very simple window after 'set nomodifiable'", function()
    vim.o.modifiable = false
    local win_id = popup.create("hello there", {
      line = 1,
      col = 1,
      width = 20,
    })

    local win_config = vim.api.nvim_win_get_config(win_id)
    eq(20, win_config.width)
    vim.o.modifiable = true
  end)

  it("can apply a highlight", function()
    local win_id = popup.create("hello there", {
      highlight = "PopupColor1",
    })

    eq("Normal:PopupColor1,EndOfBuffer:PopupColor1", vim.api.nvim_win_get_option(win_id, "winhl"))
  end)

  it("can create a border", function()
    local win_id, config = popup.create("hello border", {
      line = 2,
      col = 3,
      border = {},
    })

    eq(true, vim.api.nvim_win_is_valid(win_id))

    local border = vim.api.nvim_win_get_config(win_id).border
    border = border == nil and "none" or border
    assert(border ~= "none", "Has a border")
  end)

  -- TODO: borderhighlight
  -- it("can apply a border highlight", function()
  --   local _, opts = popup.create("hello there", {
  --     border = true,
  --     borderhighlight = "PopupColor2",
  --   })

  --   local border_win_id = opts.border.win_id
  --   eq("Normal:PopupColor2", vim.api.nvim_win_get_option(border_win_id, "winhl"))
  -- end)

  -- TODO: borderhighlight
  -- it("can ignore border highlight with no border", function()
  --   local _ = popup.create("hello there", {
  --     border = false,
  --     borderhighlight = "PopupColor3",
  --   })
  -- end)

  it("can do basic padding", function()
    local win_id = popup.create("12345", {
      line = 1,
      col = 1,
      padding = {},
    })

    local bufnr = vim.api.nvim_win_get_buf(win_id)
    eq({ "", " 12345 ", "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("can do padding and border", function()
    local win_id, config = popup.create("hello border", {
      line = 2,
      col = 2,
      border = {},
      padding = {},
    })

    local bufnr = vim.api.nvim_win_get_buf(win_id)
    eq({ "", " hello border ", "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

    local border = vim.api.nvim_win_get_config(win_id).border
    border = border == nil and "none" or border
    assert(border ~= "none", "Has a border")
  end)

  describe("borderchars", function()
    local test_border = function(name, borderchars, expected)
      it(name, function()
        local win_id, config = popup.create("all the plus signs", {
          line = 8,
          col = 55,
          padding = { 0, 3, 0, 3 },
          border = {},
          borderchars = borderchars,
        })

        local border = vim.api.nvim_win_get_config(win_id).border
        eq(expected, border)
      end)
    end

    test_border("can support multiple border patterns", { "+" }, {
      "+", "+", "+", "+", "+", "+", "+", "+"
    })

    test_border("can support multiple patterns inside the borderchars", { "-", "+" }, {
      "+", "-", "+", "-", "+", "-", "+","-",
    })

    test_border("can support 4 edges", {
      "1", "2", "3", "4",
    }, {
      "╔", "1" ,"╗", "2", "╝", "3", "╚", "4"
    })

    test_border("can support 4 edges and 4 corners", {
      "1", "2", "3", "4", "5", "6", "7", "8",
    }, {
      "5", "1" ,"6", "2", "7", "3", "8", "4"
    })
  end)

  describe("callback option", function()
    local callback_result
    local function callback(wid, result)
      callback_result = result
    end

    it("without a callback", function()
      callback_result = nil
      local popup_wid = popup.create("hello there", {})
      vim.api.nvim_win_close(popup_wid, true)

      eq(nil, callback_result)
    end)

    it("with a callback", function()
      callback_result = nil
      local popup_wid = popup.create("hello there", {
        callback = callback,
      })
      vim.api.nvim_win_close(popup_wid, true)

      eq(-1, callback_result)
    end)
  end)

  describe("enter option", function()
    it("enter not specified", function()
      local main_wid = vim.fn.win_getid()
      -- same as enter = false
      local popup_wid = popup.create("hello there", {})
      cur_wid = vim.fn.win_getid()
      -- current window should still be the main window
      eq(main_wid, cur_wid)
      vim.api.nvim_win_close(popup_wid, true)
    end)

    it("enter = false", function()
      local main_wid = vim.fn.win_getid()
      local popup_wid = popup.create("hello there", {
        enter = false,
      })
      cur_wid = vim.fn.win_getid()
      -- current window should still be the main window
      eq(main_wid, cur_wid)
      vim.api.nvim_win_close(popup_wid, true)
    end)

    it("enter = true", function()
      local main_wid = vim.fn.win_getid()
      local popup_wid = popup.create("hello there", {
        enter = true,
      })
      cur_wid = vim.fn.win_getid()
      -- current window should be the popup
      eq(popup_wid, cur_wid)
      vim.api.nvim_win_close(popup_wid, true)
    end)
  end)

  describe("moved option", function()
    local callback_result
    local function callback(wid, result)
      callback_result = result
    end

    it("with moved but not used", function()
      callback_result = nil
      local popup_wid = popup.create("hello there", {
        moved = "any",
        callback = callback,
      })
      vim.api.nvim_win_close(popup_wid, true)
      eq(-1, callback_result)
    end)
  end)

  describe("what", function()
    it("can be an existing bufnr", function()
      local bufnr = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "pass bufnr 1", "pass bufnr 2" })
      local win_id = popup.create(bufnr, {
        line = 8,
        col = 55,
        minwidth = 20,
      })

      eq(bufnr, vim.api.nvim_win_get_buf(win_id))
      eq({ "pass bufnr 1", "pass bufnr 2" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)
  end)

  describe("cursor", function()
    pending("not yet tested", function()
      popup.create({ "option 1", "option 2" }, {
        line = "cursor+2",
        col = "cursor+2",
        border = { 1, 1, 1, 1 },
        enter = true,
        cursorline = true,
        callback = function(win_id, sel)
          print(sel)
        end,
      })
    end)
  end)
end)
