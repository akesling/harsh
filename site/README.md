# site/ — the harsh source tour

An interactive, annotated static site for **harsh.sh** whose landing page is,
quite literally, the `harsh.sh` script — rendered as live, syntax-lit code you
click around in a literate-programming fashion. Built with **Bun + TypeScript**.

```sh
cd site
bun install            # once
bun run build          # production build -> site/dist/
bun run dev            # dev server: serve + watch + live-reload (also: scripts/site.sh)
bun test               # unit + integration tests
```

Then open `site/dist/index.html` — directly via `file://` or served. That page
**is** harsh.sh.

## What you get

- **The script as the homepage.** `dist/index.html` is the page for `harsh.sh`.
  Every project file — tools, commands, hooks, skills, the library, config, docs
  — gets its own page.
- **Navigate by terminal.** Fitting for a shell-harness project, navigation is a
  Quake-style console that pops down from the top (toggle with <kbd>`</kbd>). Walk
  the project as a filesystem — `ls`, `cd tools`, `open harsh.sh`, `tree` — with
  Tab-completion, history, and clickable results. `grep <text>` runs full-text
  search.
- **The code annotates itself.** harsh is already a literate codebase: a run of
  comment lines precedes the code it explains. The build lifts each comment block
  into a margin note aligned to its line (docco-style); the file's header comment
  becomes the intro card.
- **Click around.** Every mention of a project file (`tools/agent.sh`) links to
  that page; every call to a harness function (`run_hooks`, `cmd_step`) jumps to
  its definition. <kbd>⌘K</kbd> / <kbd>/</kbd> opens a fuzzy jump palette.
- **Full-text search** over every file via **lunr.js**, bundled in — `grep` in
  the console links straight to the matching line.
- **Readable Markdown**, a light/dark toggle, deep-linkable lines
  (`…/harsh.sh.html#L335`), and a layout that collapses gracefully on mobile.

## How it's built

`build.ts` (run by Bun) walks a grouped manifest of the project's files (globs
keep it complete as harsh grows), and for each one extracts the docco
annotations and function definitions and emits a static HTML page embedding the
raw source. It then:

1. writes all page data — the file **index** and the **search corpus** — to
   `src/generated.json`;
2. bundles the client (`src/app.ts` + lunr + that data) into a single minified
   `dist/assets/app.js` with `Bun.build`;
3. copies `dist/harsh.sh.html` to `dist/index.html` so the site opens on the
   script.

Because the data is **bundled into the client** (not fetched), every page is
self-contained — it works opened straight from `file://` as well as served, and
makes **zero network requests** (one stylesheet, one script, an inline favicon).
The interactive runtime — syntax highlighter, cross-reference linkifier,
margin-note placement, pop-down terminal, lunr search, Markdown renderer, command
palette — all lives in `src/app.ts`.

```
site/
├── build.ts            # the generator + dev server (Bun)
├── package.json        # deps: lunr · scripts: build, dev, test
├── tsconfig.json
├── src/
│   ├── app.ts          # client runtime (bundled to dist/assets/app.js)
│   ├── app.test.ts     # unit tests (logic, search, highlighting)
│   ├── app.boot.test.ts# integration test: full render, no fetch
│   └── generated.json  # build-time data (git-ignored)
├── assets/
│   └── style.css       # theme (dark default, light via toggle)
└── dist/               # build output (git-ignored) — deploy this

scripts/site.sh         # thin wrapper for `bun run dev` (serve + watch + reload)
```

## Dev server

`bun run dev` (or `scripts/site.sh [--port N]`) builds in dev mode, serves
`dist/` over HTTP, watches the repo, and rebuilds on every change — pushing a
reload to the browser over a WebSocket. The reload client is injected only into
dev builds; production output never references it.

## Tests

`bun test` runs unit tests (highlighter, path/function linkification, Markdown,
the terminal's virtual filesystem and path resolution, lunr search) plus an
integration test that boots the whole client against a fake DOM and asserts it
renders from the bundled data with **no fetch** and no exceptions — the
regression guard for the `file://` breakage.

## Deploying

`dist/` is the whole site — static files, no server required. Host it anywhere
(e.g. https://harsh.sh), or preview locally with `bun run dev`.
