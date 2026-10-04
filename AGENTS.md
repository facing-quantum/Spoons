# AGENTS.md

Fork of the official Hammerspoon Spoons repository (https://www.hammerspoon.org/Spoons). Each Spoon is a self-contained Lua plugin for Hammerspoon on macOS. Hammerspoon embeds Lua 5.4, so write Lua 5.4; LuaJIT/5.1 is not a valid stand-in for checking syntax.

## Layout

- `Source/<Name>.spoon/` — the source of truth: `init.lua` (the Spoon), a generated `docs.json`, and sometimes a `test_*.lua`.
- `Spoons/<Name>.spoon.zip` — the release zips SpoonInstall downloads. Generated; committed.
- `docs/` — generated HTML docs plus `docs.json`/`docs_index.json`, the index SpoonInstall searches. Generated; committed.

## Spoon conventions

- `init.lua` returns a table `obj` with metadata `obj.name`, `obj.version`, `obj.author`, `obj.homepage`, `obj.license`. `obj.version` must match `obj.version = "1.2"` (digits and dots only) or `travis-enforce.sh` fails.
- Usual lifecycle: `init()` runs at `hs.loadSpoon`, so do not capture user-configurable values there; `start()`/`stop()` enable and disable; `bindHotkeys(mapping)` takes `{ action = { mods, key } }`.
- Docs are generated from `---` comment blocks: `--- === Name ===` for the module, then for each item `--- Name:method()` (colon for methods, dot for variables/functions), `--- Method` / `--- Variable` / `--- Function`, a one-line summary, then `Parameters:` / `Returns:` sections. The summary must be a single line: the doc builder treats warnings as fatal, so one malformed docstring aborts the build for every Spoon.

## Building

The doc builder lives in a Hammerspoon checkout at `../hammerspoon` (CI uses `./hammerspoon`); every docs command needs it.

```bash
# Regenerate one Spoon's docs.json (no extra Python packages needed)
/usr/bin/python3 ../hammerspoon/scripts/docs/bin/build_docs.py -o <tmpdir> -j -n Source/<Name>.spoon
cp <tmpdir>/docs.json Source/<Name>.spoon/docs.json

# Lint one Spoon's docstrings
/usr/bin/python3 ../hammerspoon/scripts/docs/bin/build_docs.py -l -o <tmpdir> -n Source/<Name>.spoon

# Rebuild one zip. -B is required: the rule depends on the directory mtime, which in-place edits don't change
make -B Spoons/<Name>.spoon.zip

# Regenerate docs/ and the index (needs jinja2, mistune, pygments from ../hammerspoon/requirements.txt)
./build_docs.sh

# Check obj.version in every Spoon
./travis-enforce.sh
```

`docs.json` records source line numbers, so any edit that shifts lines changes it. After changing a Spoon, run these in order: bump `obj.version`, regenerate its `docs.json`, rebuild its zip (which packs `docs.json`), run `./build_docs.sh`, then commit the source, zip and `docs/` together. Upstream CI (`.github/workflows/PR.yml`) does this automatically, but only on `Hammerspoon/Spoons`, so in this fork it has to be done by hand.

## Tests

A few Spoons have standalone tests (`Source/<Name>.spoon/test_*.lua`) that mock the `hs` global and need no Hammerspoon. Run them from the repo root with a Lua 5.4 interpreter:

```bash
lua Source/ScreenRecorder.spoon/test_screenrecorder.lua
```
