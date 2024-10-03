# Popup tracking

[WIP] An implementation of the Popup API from vim in Neovim. Hope to upstream
when complete

## Goals

Provide an API that is compatible with the vim `popup_*` APIs. After
stablization and any required features are merged into Neovim, we can upstream
this and expose the API in vimL to create better compatibility.

## Notices
- **2024-09-19:** change `enter` default to false to follow Vim.
- **2021-09-19:** we now follow Vim's convention of the first line/column of the screen being indexed 1, so that 0 can be used for centering.
- **2021-08-19:** we now follow Vim's default to `noautocmd` on popup creation. This can be overriden with `vim_options.noautocmd=false`

## List of Neovim Features Required:

- [ ] Mouse Work
    mouse event for buffer in non-focusable window #30504
    https://github.com/neovim/neovim/issues/30504
- [ ] Key handlers (used for `popup_filter`)
    vim.on_key() can consume the key and prevent mapping #30741
    https://github.com/neovim/neovim/issues/30741
    - [ ] filter
    - [ ] mapping
- [ ] scrollbar for floating windows
    - [ ] firstline
    - [ ] scrollbar
    - [ ] scrollbarhighlight
    - [ ] thumbhighlight

Optional:

- [ ] Add forced transparency to a floating window.
    - [ ] mask
        - Apparently overrides text?

Unlikely (due to technical difficulties):

- [ ] Add `textprop` wrappers?
    - [ ] textprop
    - [ ] textpropwin
    - [ ] textpropid

Unlikely (due to not sure if people are using):
- [ ] tabpage

## Progress

### Suported Functions

Creating a popup window:
- [x] popup.create

Manipulating a popup window:
- [x] popup.hide
- [x] popup.show
- [x] popup.move

Closing popup windows:
- [x] popup.close
- [x] popup.clear

Filter functions:

Other:
- [ ] popup.getoptions
- [x] popup.getpos
- [ ] popup.locate
- [x] popup.list


### Suported Features

- [x] what
    - string
    - list of strings
    - bufnr
- [x] popup_create-arguments
    - [x] line
    - [x] col
    - [x] pos
    - [x] posinvert
    - [ ] fixed
    - [x] {max,min}{height,width}
    - [x] hidden
    - [x] title
    - [x] wrap
    - [ ] drag
    - [ ] dragall
    - [?] close
        - [ ] "button"
        - [x] "click"
        - [x] "none"
    - [x] highlight
    - [x] padding
    - [x] border
    - [ ] borderhighlight
    - [x] borderchars
    - [x] zindex
    - [x] time
    - [?] moved
        - [x] "any"
        - [ ] "word"
        - [ ] "WORD"
        - [ ] "expr"
        - [ ] (list options)
    - [ ] mousemoved
        - [ ] "any"
        - [ ] "word"
        - [ ] "WORD"
        - [ ] "expr"
        - [ ] (list options)
    - [x] cursorline
    - [x] filter
    - [x] mapping
    - [x] filtermode
    - [x] callback


### Additional Features from `neovim`

- [x] enter
- [x] focusable
- [x] noautocmd
- [x] finalize_callback
- [x] title_pos
- [x] footer
- [x] footer_pos

## All known unimplemented vim features at the moment

- fixed
- flip (not implemented in vim yet)
- scrollbar related: firstline, scrollbar, scrollbarhighlight, thumbhighlight
- resize

## Functions not planned

- popup_beval
