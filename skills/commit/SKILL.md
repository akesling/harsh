---
name: commit
description: Stage changes and write a clean, conventional git commit.
---

# Commit skill

Create a well-formed git commit for the current working tree.

Steps:
1. Run `git status --short` and `git diff --stat` with the bash tool to see what changed.
2. Run `git diff` (and `git diff --staged`) to understand the actual changes.
3. Stage the relevant files with `git add`. Do not stage unrelated junk.
4. Write a commit message:
   - First line: `<type>: <imperative summary>` under ~72 chars
     (`type` is one of feat, fix, refactor, docs, test, chore).
   - Blank line, then a short body explaining *why* if it is not obvious.
5. Commit with `git commit -m "..."` (use multiple `-m` for the body).
6. Show the result with `git log -1 --stat`.

Never commit secrets, large binaries, or `.env` files. If `git` reports nothing
to commit, say so and stop.
