# The fleet's actions

Every script a workflow of this kit runs lives here, as a composite action,
and every workflow refers to it by its full name rather than by path:

```yaml
- uses: cynkra/cynkratemplate/.github/actions/install@main
```

That is what lets the actions be *shared* rather than *copied*.
A repository on this kit needs the workflow files and nothing else;
the actions are fetched from here at run time,
into the runner's action cache and not into the workspace,
which is also why a job with no checkout can still use one.

`@main` everywhere, deliberately.
There are no tags to move and no versions to bump,
and a change merged here is live in every repository on the next run.

## An action is one directory

An action is fetched with the whole repository into the runner's action cache, never into the workspace.
Its `action.yml` reaches the files beside it through `${{ github.action_path }}`:

```yaml
- run: Rscript --no-init-file "${{ github.action_path }}/build.R"
  shell: bash
```

Prefer such a script to a long `run:` block: it can be read, linted and run on its own.
A short step stays inline, and the older actions still carry long inline blocks until someone moves them out.

Call the script through its interpreter, as above, so that its file mode does not matter.
From R, prefer `Rscript` in a `shell: bash` step over `source()` in a `shell: Rscript {0}` step:
on Windows the path holds backslashes, which an R string reads as escapes.

Never refer to a script by a workspace-relative path.
That path resolves inside the *consuming* repository, where the file does not exist.
The step then dies at run time, in nine repositories at once, and nothing says so beforehand:
`actionlint` does not follow paths, and a repository that still had a stale copy would even pass.

Scripts that several actions share live in a directory of their own,
reached with a relative path from `${{ github.action_path }}`.
The revdep subsystems keep theirs in `revdep2/`, `revdep4/` and `revdepx/`, each with a README of its own.
A workflow step cannot see `github.action_path`,
so a job that runs one of these scripts from a step of its own first calls the `revdep-scripts` action,
which exports the three directories as `REVDEP2_DIR`, `REVDEP4_DIR` and `REVDEPX_DIR`.

## Testing a change to an action

Because every caller says `@main`,
a pull request that edits an action changes nothing about what its own run executes:
the run still fetches the action from `main`, and the scripts beside it with it.
A green pull request therefore says nothing at all about the change,
and the first time the new action runs is the moment it lands on every repository at once.

So point the callers at the branch first, and put them back before merging.

1. Edit the action on a branch of this repository.

2. Point its callers at that branch:

   ```bash
   name=collect-checks
   branch=$(git branch --show-current)
   grep -rl "actions/${name}@main" .github/workflows .github/actions |
     xargs sed -i "s|\(actions/${name}\)@main|\1@${branch}|g"
   ```

3. Push, and read the run. The action now comes from the branch, so what runs is what you wrote.

4. Iterate until it is green.

5. Put `@main` back as the last commit of the pull request, and merge that:

   ```bash
   grep -rl "actions/${name}@${branch}" .github/workflows .github/actions |
     xargs sed -i "s|\(actions/${name}\)@${branch}|\1@main|g"
   ```

What this proves is that the action's content works, byte for byte:
between step 4 and step 5 only the ref changes.
What it does not prove is the merge itself,
which is the one combination that is never executed before it becomes live.
That is the residual risk of `@main`, and the reason to keep such a change small
and to read the first run on `main` afterwards.

### Testing against another repository

Some actions do nothing worth watching here.
A database matrix, a revdep universe or a package with compiled sources
only exists in the repository that has it.
Open a throwaway branch there and point the one call site at your branch of this repository:

```yaml
- uses: cynkra/cynkratemplate/.github/actions/revdepx-build-universe@my-branch
```

Nothing has to be merged here first, and nothing has to be copied.

### Linting locally

`actionlint` reads a local action and checks the call against it;
it cannot fetch a remote one, so with `@main` it stops checking inputs and outputs entirely.
That is not a small loss: an undeclared output on a composite action
silently breaks the job output that reads it, and this is what used to catch it.

Point the refs at the copy in this checkout, lint, and point them back:

```bash
files() { git ls-files -z '.github/workflows/*.yaml' '.github/actions/*/action.yml'; }
files | xargs -0 sed -i 's|cynkra/cynkratemplate/\.github/actions/\([a-z0-9-]*\)@main|./.github/actions/\1|g'
actionlint
files | xargs -0 sed -i 's|\./\.github/actions/\([a-z0-9-]*\)|cynkra/cynkratemplate/.github/actions/\1@main|g'
```

The second substitution is the exact inverse of the first,
so the tree comes back byte-identical -- check with `git diff` if you interrupted it partway.
Use this rather than `git checkout -- .github`, which would take your uncommitted work with it.

### Two things the branch trick cannot reach

- A workflow triggered by `workflow_run` -- `rcc-status`, `commit-suggest` --
  always uses the *workflow file* from the default branch, whatever the branch under test.
  A change to the workflow around the action needs merging, or a `workflow_dispatch` run.
- A pull request from a fork cannot fetch `cynkra/cynkratemplate/...@<its branch>`,
  because that ref does not exist in this repository.
  Point it at the fork for the test: `<owner>/cynkratemplate/.github/actions/<name>@<branch>`.

## Versioning, when it is needed

There are no tags. Where a change cannot keep every caller working,
copy the directory instead of breaking them:

```bash
cp -r .github/actions/install .github/actions/install-v2
```

Then change `-v2`, move callers onto it one repository at a time,
and delete the original once nothing refers to it.
`-v3` after that, and so on.

A change needs a new version when it removes or renames an input,
changes what an input means, removes an output,
or changes behaviour that a caller relies on.
Adding an input with a default does not, and neither does anything a caller cannot observe.

## What is not here, and why

- **`.github/workflows/custom/before-install` and `after-install`** are each repository's own.
  They are referenced with `./` and guarded by `hashFiles()`, so a repository without them skips the step.
  Fetching them from here would give every repository the same hooks,
  which is the opposite of what they are for, so they stay local and stay where they are.
  `after-install` runs once `install` has written the ccache wrappers and `MAKEFLAGS` to `~/.R/Makevars`.
  A hook that adds to that file appends, with `>>` or `tee -a`; overwriting it drops them.
