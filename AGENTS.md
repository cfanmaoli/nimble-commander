# Working agreement for this repository

This checkout is used for **local development**. The maintainer decides when anything leaves the
machine.

## Never do these without explicit, prior approval from the maintainer

- `git push` to any remote (including the `fork` remote), force pushes, or pushing tags.
- Creating, moving, or deleting tags, branches on the remote, or releases (including the rolling
  `nightly` pre-release).
- Dispatching, re-running, cancelling, or otherwise touching GitHub Actions workflows
  (`gh workflow run`, `gh run rerun`, `gh run cancel`, ...).
- Any other change to GitHub state (settings, release assets, appcast feed, ...).

Ask first, describe the exact command and its effect, and wait for a clear "yes". A previous
approval does not extend to later actions.

## Always fine locally

Reading code and logs, editing sources, building, running the unit and integration tests, running
benchmarks and profiling, inspecting crash reports, installing the built app into /Applications.

## When in doubt

Do less. Prepare the change locally, verify it, and then ask whether to publish it.
