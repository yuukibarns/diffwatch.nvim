# DiffWatch.nvim

A QoL plugin that displays inline diffs between the previous and current buffer
state, with intuitive navigation and change resolution.

## Usage

This plugin provides two commands:

- `DiffWatch`\
  Toggles watching the current buffer for changes.

- `DiffWatchReset`\
  Resets the "original buffer" reference to the current state, showing diffs
  between now and future changes

## Showcase

|    ![DiffAdd](./static/DiffAdd.png)    |
| :------------------------------------: |
|                Diff Add                |
| ![DiffDelete](./static/DiffDelete.png) |
|              Diff Delete               |
| ![DiffChange](./static/DiffChange.png) |
|              Diff Change               |

## Features

- **Inline diffs**\
  Shows previous versions inline rather than side-by-side, which many find more
  readable (as shown in the examples)

- **Non-invasive**\
  Never automatically modifies your file - previous versions appear as virtual
  text without affecting treesitter, LSP, etc. Changes only apply when manually
  accepted

- **Flexible resolution**\
  When your cursor is in a changed region, hints appear showing resolution
  options, `<leader>co:ours | <leader>ca:theirs...`.

  Available actions:
  - `ours`: Keep previous version
  - `theirs`: Keep current changes
  - `both`: Combine versions
  - `none`: Remove both

- **Change navigation**\
  Default keymaps `[w` and `]w` for jumping between changes

## Why This Plugin?

Keep It Simple and Stupid!

I previously used `avante.nvim` for applying AI-generated code, but found it
unnecessarily complex when I only needed one small feature that may be even
borrowed from plugins like `git-conflict.nvim`.
