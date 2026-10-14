# agents-skills

Personal [Agent Skills](https://agentskills.io): one folder per skill under `skills/`,
each with a `SKILL.md` (YAML frontmatter + instructions) and optional `scripts/`,
`references/` and `assets/`. The same format works for Claude Code and Codex.

## Skills

| Skill | What it does |
|---|---|
| [onedrive-macos-free-up-fix](skills/onedrive-macos-free-up-fix/SKILL.md) | OneDrive on macOS: files that stay downloaded after "Free Up Space" (stuck Content Policy 3) |

## Install

`install.sh` symlinks every skill in `skills/` into the personal skill folder of each
agent you pick. Edits in the repo go live immediately, and `git pull` updates them.

| Agent | Skills folder |
|---|---|
| Claude Code | `~/.claude/skills` |
| Codex | `~/.agents/skills` |

```sh
./install.sh                     # interactive: ↑/↓ move, space toggle, a all, enter confirm
./install.sh --claude --codex    # non-interactive (or --all)
./install.sh --uninstall         # remove links that point into this repo
```

- Installed agents (`~/.claude`, `~/.codex` present) are pre-selected in the menu.
- Re-running refreshes links and prunes links to skills deleted from the repo.
- Real folders (not symlinks) with the same name are never overwritten.
- Override folders with `CLAUDE_SKILLS_DIR` / `CODEX_SKILLS_DIR`.

## Conventions

- Folder name = `name:` in the frontmatter (lowercase, hyphens).
- `description` says what the skill does and when to use it. It's what triggers the skill.
- Record what a skill was verified against in `metadata` (e.g. app/OS versions + date),
  and re-verify when those change.
- No personal paths, IDs or secrets: scripts discover machine-specific values at runtime.
