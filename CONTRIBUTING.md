# Contributing

## Branches and pull requests

- `main` changes only through pull requests. Never commit or push to `main` directly, and don't merge your own pull request without review.
- Start every change on a new branch from the latest `main`, named for the change, for example `fix/search-cursor`, `feat/any-state-ui-actions` or `docs/install-steps`.
- Commit small and often, and push the branch after each meaningful step so the work is never only on one machine.
- Open the pull request early, as a draft if the work isn't done. Keep each pull request to one change, so it's easy to review and easy to revert.
- Describe what changed, why, and how you tested it. Say plainly what you couldn't test.

## Before you open a pull request

- `swift build` and `swift test` pass with no warnings.
- For packaging or install changes, `scripts/build.sh` still builds and `scripts/tests/install-test.sh` passes.
- For changes to the skill, `scripts/check-skill-tokens.sh` passes.
- Behavior changes come with a test that fails without the change.

## What never goes in the repo

- Signing material: keychains, certificates, private keys and password files. `.gitignore` excludes the usual names, but check `git status` before every commit.
- Personal data: phone numbers, email addresses, contact names or message text from a real Messages database. Tests use the synthetic fixture in `Tests/Fixtures`.
- Build output: `out/`, `.build*/` and release tarballs.

## Live tests

The release tests in `scripts/release-tests` drive the real Messages app. Run them only against your own Apple ID, with `IMSG_TEST_HANDLE` set to your own address, and never against anyone else's chats.
