# Branch ruleset for `main`

`protect-main.json` is the ruleset for this repo, kept as code. Apply or update it in the browser:
**Settings → Rules → Rulesets → New ruleset → Import a ruleset** → choose `protect-main.json` → **Create**.

What it does:
- every change to `main` goes through a pull request; no force-pushes, no deleting `main`
- a PR needs 1 approval, and a **code owner's** approval for files in `.github/CODEOWNERS` (prod values, prod Argo CD and Terraform)
- the `secret scan (gitleaks)` and `Dockerfile lint (hadolint)` checks must pass (they run on every PR)

Bypass list:
- **Repository admins, pull requests only**: you can merge your own PRs (GitHub won't let you approve your own), but you can't push to `main` directly.
- **GitHub Actions, always**: CI pushes the dev image-tag bumps to `main`, and `promote.yaml` merges stage promotions when `AUTO_MERGE_STAGE=true`.
