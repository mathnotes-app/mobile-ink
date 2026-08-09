# Releasing `@mathnotes/mobile-ink`

Releases use an explicit, reviewed version bump. Publication begins only after the version-bump PR is merged into `main` and the existing CI workflow passes on that exact commit.

## Prepare a release

1. Create a release branch from `main`.
2. Run `npm version <patch|minor|major> --no-git-tag-version`. Automated prerelease publication is intentionally unsupported.
3. Add the new version and release notes to `CHANGELOG.md`.
4. Open a PR and let the normal approval, status-check, and merge rules run.

After merge, `.github/workflows/publish.yml` checks whether the `package.json` version already exists on npm. New versions are built and published using npm trusted publishing. The workflow then creates the matching `vX.Y.Z` tag and GitHub release. Existing npm versions and releases are skipped, so ordinary merges to `main` do not republish the package.

## One-time trusted-publisher setup

An npm owner for `@mathnotes/mobile-ink` must configure a GitHub Actions trusted publisher on npmjs.com with these values:

- Organization or user: `mathnotes-app`
- Repository: `mobile-ink`
- Workflow filename: `publish.yml`
- Environment: `npm`
- Allowed action: `npm publish`

The workflow uses short-lived GitHub OIDC credentials and does not require an `NPM_TOKEN` repository secret. Keep the GitHub `npm` environment restricted to protected branches.

Do not manually publish a version that is waiting in a release PR. If publication fails after merge, rerun the failed `Publish npm package` workflow after correcting the account-level configuration.
