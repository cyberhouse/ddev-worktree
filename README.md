# ddev-worktree

DDEV add-on for several branches at once, each in its own [git worktree](https://git-scm.com/docs/git-worktree) with
its own DDEV project (URL, database, containers), managed by [Worktrunk](https://worktrunk.dev) (`wt`). A worktree of
`feature/PROJ-5-x` of project `myproject` runs as DDEV project `myproject-proj-5` next to the main checkout.

| File | Purpose |
|---|---|
| `worktree/pre-start` | DDEV name of a new worktree: project name plus the ticket of the branch (the whole branch without a ticket or when another worktree has the ticket), written to `.ddev/config.local.yaml` |
| `worktree/post-start` | `ddev start` in the background, with an empty database unless the project's own DDEV hooks import one |
| `worktree/pre-remove` | `ddev delete -Oy` before the worktree is removed, only for a name written by `pre-start` |
| `worktree/worktrunk.toml` | Worktrunk hooks that run the main checkout's `.ddev/worktree/` scripts, plus `wt step copy-ignored` |
| `worktree/install-worktrunk` | writes `worktrunk.toml` as marked block into your Worktrunk user config |

## Requirements

- DDEV >= v1.25.4
- [Worktrunk](https://github.com/max-sixty/worktrunk#install), installed by every developer on the host, on Windows
it is `git-wt` (`wt` is Windows Terminal). The add-on doesn't install it, `ddev add-on get` only warns if it's
missing.
- Optional, for [Claude Code](https://docs.anthropic.com/en/docs/claude-code): Worktrunk's plugin, `wt config plugins claude install`.
Without it `claude --worktree` bypasses Worktrunk and none of the hooks run: no own DDEV name, no `ddev start`,
no `ddev delete` on removal.

## Installation / update

```
ddev add-on get cyberhouse/ddev-worktree
```

Installs the latest release, run it again to update. A specific release: `--version vX.Y.Z`.

The files are copied to `.ddev/` and committed with the project. The install also runs `install-worktrunk`, every
other developer runs it once in a project with the add-on (no sudo):

```
sh .ddev/worktree/install-worktrunk
```

It writes the hooks into `~/.config/worktrunk/config.toml` (Windows `%APPDATA%\worktrunk\config.toml`,
`WORKTRUNK_CONFIG_PATH` if set) as block between `# >>> ddev-worktree >>>` and `# <<< ddev-worktree <<<`, before your
first table, so your top-level settings stay top-level and our hooks run first:

- Don't edit the block, the next run replaces it. Everything outside stays as is, the first write keeps a
`config.toml.bak`.
- Own `pre-start`, `post-start` and `pre-remove` hooks must be `[[pre-start]]` blocks, a `[pre-start]` table or a
top-level `pre-start = "..."` next to ours is invalid TOML. The script then writes nothing and says so.
- The hooks are the same for all projects and do nothing in repositories without this add-on.
- `ddev add-on remove worktree` removes the block again, other developers run
`sh .ddev/worktree/install-worktrunk --remove` (before the removal is pulled).

## Project requirements

- `.ddev/config.yaml` committed, with `name:` as single line at the top level (`name: myproject`, quotes and a
trailing comment are fine). Without it DDEV would use the directory name, the worktree names are built from it.
- Optional `.worktreeinclude` (gitignore syntax): ignored files copied from the main checkout into a new worktree,
e.g. `.env`. Without it nothing is copied.
- Every worktree has its own host, `myproject-proj-5.ddev.site` instead of `myproject.ddev.site`. Its
`additional_hostnames` are only `*.myproject-proj-5`, the ones of the main `.ddev/config.yaml` are not used.
- No fixed host in the app's config: relative URLs, or URLs built from the environment of the web container
(`DDEV_PRIMARY_URL`, `DDEV_SITENAME`, `DDEV_TLD`). A fixed `https://myproject.ddev.site/` leads from the worktree
to the main checkout's project, further hosts follow the same pattern: `https://shop.${DDEV_SITENAME}.${DDEV_TLD}/`.

## Usage

```bash
wt switch -c feature/PROJ-5-x   # create worktree + DDEV project, ddev start in the background
wt list                         # all worktrees
wt remove                       # remove the current worktree and its DDEV project
git fetch && wt step prune      # after the pull request is merged: remove merged worktrees (--dry-run first)
```

- Merge via a pull request as usual, or locally in the main checkout:
`git pull && git merge --no-ff feature/PROJ-5-x && git push`, then `wt remove feature/PROJ-5-x`.
Not with `wt merge`: it rebases the branch (by default also squashes it) instead of a plain merge commit.
- `wt step prune` only removes branches merged into the default branch (or `origin/<default>` after `git fetch`),
worktrees of branches merged elsewhere, e.g. into `develop`, are removed with `wt remove`. It skips worktrees
younger than a day, `--min-age=0s` includes them.
- `wt remove` deletes the database **without a snapshot**. To keep it: `ddev export-db --file=../proj-5.sql.gz` first.
- Claude Code with the plugin: `claude --worktree PROJ-5` creates and removes the worktree via `wt`, with its DDEV
project. Worktrees of Claude Code subagents stay, remove them later with `wt remove` or `wt step prune`.
- Created another way (IDE, `git worktree add`): run `wt hook pre-start` in it, then `ddev start`.
- Removed another way (IDE, `git worktree remove`, `rm -rf`): the DDEV project stays, delete it by name:
`ddev delete -Oy myproject-proj-5` and `git worktree prune`. A stopped leftover may be missing in `ddev list`,
its database still shows up in `docker volume ls`.
- Don't run `ddev config` in a worktree, it removes `name:` from the committed `.ddev/config.yaml`.
- Personal additions go outside the block, e.g. a new editor window per worktree:
`[[post-start]]` `editor = "cursor {{ worktree_path }}"`.

## Tests

[Bats](https://bats-core.readthedocs.io/) tests in `tests/test.bats`, run by GitHub Actions on pull requests and
pushes to `main` (not for Markdown-only changes) and daily, against DDEV stable and HEAD. Locally, with
[bats-core and its libraries bats-support, bats-assert, bats-file](https://bats-core.readthedocs.io/en/stable/installation.html)
installed:

```
bats tests/test.bats --filter-tags '!release'
```

The tests use their own Worktrunk config (`WORKTRUNK_CONFIG_PATH`), yours stays untouched. Without `wt` the
Worktrunk tests are skipped.
