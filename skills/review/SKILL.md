---
name: review
description: Review the current diff for correctness bugs and obvious cleanups.
---

# Review skill

Review the pending changes in the working tree.

Steps:
1. Use the bash tool to get the diff: `git diff` (and `git diff --staged` if
   anything is staged). If there is no git repo, review the files named in the
   arguments instead.
2. Read surrounding context with the read tool where the diff alone is
   insufficient to judge correctness.
3. Report findings grouped as:
   - **Bugs** — correctness issues, with `file:line` and a concrete fix.
   - **Risks** — error handling, edge cases, portability concerns.
   - **Cleanups** — simplifications and reuse opportunities (optional).
4. Be specific and high-signal. If the change looks correct, say so plainly
   rather than inventing nitpicks.

Do not modify files unless explicitly asked; this skill only reviews.
