# Scrolling & reading long output (tmux + Claude Code)

Config lives in `~/.tmux.conf`. Prefix is the tmux default: **`Ctrl-b`**.

## The fix that was applied

| Setting | Was | Now |
|---|---:|---:|
| `history-limit` (scrollback lines) | 2 000 | 200 000 |
| `mouse` | off | **on** |

> ⚠️ `history-limit` applies at pane creation. The pane you are in right now still
> has the old 2 000-line buffer. Open a new window (`Ctrl-b c`) or split
> (`Ctrl-b "`) to get the full 200 000.

## Scrolling

| Keys | Action |
|---|---|
| **mouse wheel** | scroll up (auto-enters copy-mode; scrolling to the bottom exits) |
| `Ctrl-b [` | enter copy-mode manually |
| `PgUp` / `PgDn` | page up / down (in copy-mode) |
| `k` / `j` | line up / down (vi keys) |
| `Ctrl-u` / `Ctrl-d` | half page up / down |
| `g` / `G` | jump to top / bottom of scrollback |
| `q` or `Esc` | leave copy-mode |

## Searching the scrollback

| Keys | Action |
|---|---|
| `Ctrl-b /` | incremental search **backwards** (custom binding) |
| `?` *(in copy-mode)* | search backwards |
| `/` *(in copy-mode)* | search forwards |
| `n` / `N` | next / previous match |

## Copying

| Keys | Action |
|---|---|
| `v` *(in copy-mode)* | start selection |
| `y` | copy selection & exit |
| drag with mouse | select & copy |
| `Ctrl-b ]` | paste |

## Saving output to a file (the reliable escape hatch)

| Keys / command | Action |
|---|---|
| `Ctrl-b P` | dump **entire pane scrollback** → `~/pane-YYYYMMDD-HHMMSS.txt` |
| `tmux capture-pane -p -S - > out.txt` | same thing, from the shell |
| `tmux capture-pane -p -S -5000 \| less` | last 5 000 lines in a pager |

## Claude Code TUI

- Mouse-wheel scroll works now that tmux mouse mode is on — tmux handles it,
  Claude Code does not capture the wheel.
- `Ctrl-b [` then `g` jumps to the very start of the session's output.
- `Esc` interrupts Claude mid-response · `Ctrl-c` cancel · `Ctrl-d` exit.
- `Shift-Tab` cycles permission mode.
- `/artifacts` lists published artifacts; `Ctrl-]` reopens the last one.
- **Long answers are written to files** (see `docs/ANALYSIS.md`) so nothing
  important lives only in scrollback.

## Other useful tmux

| Keys | Action |
|---|---|
| `Ctrl-b c` | new window (gets the full 200k scrollback) |
| `Ctrl-b d` | detach — session keeps running |
| `tmux attach` | re-attach after closing the terminal |
| `Ctrl-b R` | reload `~/.tmux.conf` (custom binding) |
