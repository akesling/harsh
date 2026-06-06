---
name: explain
description: Explain how a file, function, or subsystem works.
---

# Explain skill

Produce a clear explanation of the code referenced in the arguments.

Steps:
1. Locate the relevant code with the grep and ls tools.
2. Read the key files with the read tool.
3. Explain, in order:
   - **Purpose** — what problem this code solves, in one or two sentences.
   - **Flow** — the main entry points and how control/data moves through them.
   - **Key details** — non-obvious decisions, invariants, and gotchas.
4. Reference concrete `file:line` locations so the reader can follow along.

Keep it concise and concrete. Prefer showing the actual call path over abstract
description. Do not modify any files.
