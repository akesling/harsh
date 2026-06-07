#!/usr/bin/env sh
# scripts/site.sh — live dev server for the source tour (site/).
#
# Thin wrapper around the Bun build: builds site/, serves dist/, watches the
# repo, and live-reloads the browser over a WebSocket on every change. All the
# real work is in site/build.ts.
#
#   scripts/site.sh                serve on http://localhost:8000
#   scripts/site.sh --port 9000    serve on a different port
#
# One-off production build instead:  (cd site && bun run build)
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

# Locate bun. It usually lives in ~/.bun/bin, which is on an interactive PATH but
# not the minimal PATH a non-interactive `sh` inherits — so fall back explicitly.
BUN=$(command -v bun 2>/dev/null || true)
if [ -z "${BUN}" ]; then
  for _c in "${HOME}/.bun/bin/bun" "${HOME}/.local/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
    [ -x "${_c}" ] && { BUN=${_c}; break; }
  done
fi
[ -n "${BUN}" ] || { echo "site.sh: bun not found — install from https://bun.sh" >&2; exit 1; }

cd "${ROOT}/site" || { echo "site.sh: cannot enter ${ROOT}/site" >&2; exit 1; }
[ -d node_modules ] || "${BUN}" install

# `bun run ./build.ts` (explicit ./ → run the file, not the `build` subcommand).
# --dev makes build.ts serve + watch + live-reload; extra args (e.g. --port) pass through.
exec "${BUN}" run ./build.ts --dev "$@"
