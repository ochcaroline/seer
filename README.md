# Seer

A keyboard-driven macOS app for reviewing GitHub pull requests, with vim-style keys.
Native AppKit, no web view.

- **PR list** for the repos you configure, grouped by repo, with labels: `REVIEW` (you, or a team you belong to, were asked to review), `APPROVED`, `CHANGES`, `PENDING` and `DRAFT`.
- **Unified diff** with syntax highlighting (tree-sitter), per-file wrapping, search, visual line selection and a checks / files sidebar.
- **Reviews**: comment on lines, reply to and edit threads inline, then submit a review (approve / request changes / comment). Approving and merging are refused if the PR has commits newer than the ones you loaded.
- **Merge or close** a PR (merge commit, squash or rebase, with an editable commit message).
- **Copilot pane**: ask GitHub Copilot about the selected lines, a file or the whole PR. Answers render as numbered lines you can select and copy.
- Copy a `gh pr checkout` command for any PR.

## Requirements

- macOS 14+, Swift 6 toolchain (Xcode or Command Line Tools)
- Network access when building: SwiftPM fetches the tree-sitter runtime, and `make` downloads the grammars pinned in `grammars.txt` and compiles them into the app bundle
- GitHub access: `gh auth login` (or set `GITHUB_TOKEN`). With several `gh` accounts, set "GitHub account" in Settings to pin one (otherwise `GITHUB_TOKEN`, else the active `gh` account). Team review requests need the `read:org` scope.
- Optional: the [Copilot CLI](https://github.com/github/copilot-cli) (`copilot login`) for the Copilot pane.

## Build

```sh
make build     # builds Seer.app
make run       # build and open
make install   # copy to /Applications (override with PREFIX=)
make test      # builds the grammars too; the highlighter tests use them
make grammars  # just (re)build the grammars into .build/grammars
```

Syntax highlighting is self-contained: grammars and their highlight queries (from nvim-treesitter) ship inside `Seer.app/Contents/Resources/grammars`. To add or update a language, edit `grammars.txt` (and `Highlighter.byExtension`), then `make build`.

## Configure

Press `,` (or ⌘,) for Settings: add repos as `owner/name`, one per line, and adjust fonts and the Copilot model.
Settings are stored in `~/.config/seer/config.json` (or `$XDG_CONFIG_HOME/seer/config.json`).

## Keys

Press `?` in the app for the full list. The essentials:

| Where | Keys |
|---|---|
| Everywhere | `j`/`k` move (counts: `5j`), `Ctrl-d`/`Ctrl-u` half page, `gg`/`G` first/last, `?` help, `,` settings, `o` open in browser |
| PR list | `Enter` open, `h`/`l` previous/next repo, `/` filter, `r` refresh the selected PR, `R` refresh all, `Space g h` copy `gh pr checkout`, `Space g t` open in a terminal (Settings: terminal, source directory) as a tmux session with the PR checked out, nvim in the first window and a spare shell in the second |
| Diff | `h`/`l` (or `[f`/`]f`) previous/next file, `/` search with `n`/`N`, `w` wrap file, `V` visual lines, `{n}G` go to line, drag the mouse to select text and `y` to copy it, `q` back to list, `R` reload PR |
| Review | `c` comment (or reply on a thread), `e` edit your comment, `Enter` fold/unfold a thread, `Space s` submit review, `Space m` merge, `X` close PR |
| Comment field | opens under the line in normal mode: `i` type, `Esc` back to normal mode (or cancel), `Enter` send |
| Panes | `Ctrl-h/j/k/l` move between sidebar (checks, files) and diff |
| Copilot pane | `Space a i` open/close, `i` type, `Enter` send, `Esc` normal mode, `j`/`k` move, `V` select (or drag the mouse), `y` copy, `q` close, `Ctrl-h/l` switch pane |

## Layout

- `Sources/SeerCore`: GitHub GraphQL client, review session, diff parser, highlighter, vim key parser, config
- `grammars.txt`, `scripts/grammars.sh`: the bundled tree-sitter grammars
- `Sources/Seer`: the AppKit app
- `Tests`: `SeerCoreTests`
