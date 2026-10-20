---
description: Branching strategy and git workflow rules for BullshitNotch
globs: "**/*"
---

# Git Workflow & Branching Rules

1. **Never commit new features or fixes directly to `main` or `master`.**
2. **Always create a dedicated feature or fix branch** before writing code or committing:
   - Features: `feat/<feature-name>`
   - Bug fixes / performance: `fix/<issue-name>` or `perf/<improvement-name>`
3. **Commit changes to the branch**, push the branch to remote, and open a Pull Request against `main`.
4. Only merge into `main` after verification or when explicitly instructed by the user.
