# ck-ci

CourseKata's shared CI: the reusable workflows, actions and Renovate preset that other repositories' CI calls. What belongs here is in the name: only things another repository's CI calls. The OpenTofu modules that infrastructure code imports live in [ck-tf-modules](https://github.com/coursekata/ck-tf-modules), and workflows tied to the delivery control plane, such as the plan workflow, stay in ck-tooling.

The repository is public, so a workflow in either organization calls it with no token. It pins nothing in another repository, so a release here never waits on one elsewhere.

## Contents

| Path | Called by |
|---|---|
| `image/build-action`, `image/health-action`, `image/push-action` and `image/release-action` | A repository's image workflow. Each image is built once and tested on that build, the caller's checks run before anything is pushed, the push sends exactly the tested bytes, and a release copies that digest when it differs from the newest release and does nothing for an unchanged image. A consumer pins a release by digest, and Renovate moves the pin. [`image/README.md`](image/README.md) is the contract. |
| `.github/workflows/quality.yml` | Any repository's `ci.yml`, for the secret and CVE scans. |
| `.github/workflows/tf-quality.yml`, with the hook config it runs and its own hooks' scripts in `tf-quality/` | Each OpenTofu repository's `ci.yml`, in place of `quality.yml`, which it runs. |
| `.github/workflows/renovate.yml` | The Renovate workflow of a repository whose CI holds cloud credentials. |
| `renovate/default.json` | Every repository's `renovate.json`, through `extends`. |
| `renovate/ecr-image-pin.json` | A consumer's `renovate.json`, through `extends`, for each tfvars pin of an image the image pipeline released. |

## Pinning and releases

A caller pins a workflow or action by a release tag, never a commit SHA. GitHub resolves a SHA from any fork of a public repository, so a reviewer cannot tell a fork's commit from one here, while a `v*` tag resolves only here and a ruleset blocks moving or deleting it. The caller's dependency bot moves the pin and keeps the tag form.

```yaml
jobs:
  quality:
    uses: coursekata/ck-ci/.github/workflows/tf-quality.yml@vX.Y.Z
```

```yaml
    steps:
      - uses: coursekata/ck-ci/image/build-action@vX.Y.Z
```

Releases follow SemVer. While the version is 0.y.z, MINOR marks a change a caller must make and PATCH covers everything else. A release is a new tag, never a moved one, and a lightweight one: `git tag vX.Y.Z <commit> && git push origin vX.Y.Z`. Actions resolves a same-repository reference inside a called workflow, such as `tf-quality.yml`'s call to `quality.yml`, at the object the caller's tag names, and an annotated tag's object is the tag, not its commit, so a caller on an annotated tag fails at startup with no jobs. GitHub has confirmed the bug and given no date for a fix.

## Quality bars (`quality.yml` and `tf-quality.yml`)

`quality.yml` is the bar any repository needs, whatever it is written in: a full-history scan for committed secrets, since a secret committed and later deleted is still disclosed to anyone who can clone, and a CVE scan over any lockfile the caller declares. `tf-quality.yml` is the bar for an OpenTofu repository, and it runs `quality.yml` too, so an OpenTofu repository makes one call and cannot take half the bar. Its checks are the hooks in [`tf-quality/pre-commit-config.yaml`](tf-quality/pre-commit-config.yaml), which the workflow runs with prek over every tracked file. It bans plan-time code-execution constructs, JSON configuration, which the ban cannot read, and a committed `testing = true` before anything initialises, then runs `tofu fmt`, `tofu validate` in every directory with a `.tf` or `.tofu` file, `tflint`, one `trivy config` from the root and `tofu test`. Each hook runs even when one before it failed, though a failed ban stops them all, since the first init runs provider code.

Both workflows run their own checks, at the versions pinned here, and neither reads the caller's `.pre-commit-config.yaml`. A caller's `.tflint.hcl` and `.trivyignore` set how strict a tool is, not whether it runs, and the bar needs a `.tflint.hcl` at the repository root. Both are credential-free. A tool version moves here, in a release, so a caller's bar changes only when it moves to that release.

```yaml
jobs:
  quality:
    uses: coursekata/ck-ci/.github/workflows/tf-quality.yml@vX.Y.Z
    with:
      tofu_version: "1.12.2"
```

**The bar's hooks run before a push too.** A repository copies the bar's hook config into its own `.pre-commit-config.yaml`, with ck-ci at the release it calls the workflow at, and Renovate's `pre-commit` manager moves both revs. The bar's own hooks take the file names prek passes, so on a commit they check only what it touches. `tofu test` runs on push instead, over every commit being pushed, since it takes tens of seconds in a large repository; `prek install` installs both hooks when the copy keeps the bar's `default_install_hook_types`, and a clone whose hooks were installed before needs `prek install` again. It runs every suite whose module tree, as `tofu get` resolves it, holds a changed file: a change inside a module runs the suite of every module that calls it, and no other. Given every file, as the workflow gives it, it runs every suite.

**A repository's own hooks are its own.** One that wants them in CI runs them in a job of its own and skips the hooks the bar already runs. Nothing in that job installs OpenTofu, so a hook added later that needs it fails there rather than repeat the bar:

```yaml
  hooks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha> # v7.0.1
      - uses: j178/prek-action@<sha> # v3.0.0
        env:
          SKIP: tofu-ban,tofu-testing-guard,terraform_fmt,terraform_validate,terraform_tflint,terraform_trivy,tofu-test,gitleaks-system
        with:
          extra-args: --all-files
```

A copy of the bar's hooks that drifts costs a red CI run, not a weaker bar.

This repository calls both workflows locally from `ci.yml`, `tf-quality.yml` against the fixture in `tf-quality/tests/fixture`, so a change to either runs on its own pull request before any caller can pin it.

## Dependency updates (`renovate.yml` and `renovate/default.json`)

A repository whose CI holds cloud credentials calls the workflow at a pinned tag and extends the preset:

```yaml
# .github/workflows/renovate.yml
on:
  schedule: [{ cron: "0 13 * * 1" }]
  workflow_dispatch:
permissions:
  contents: write
  pull-requests: write
  issues: write
  statuses: write
  id-token: write
jobs:
  renovate:
    uses: coursekata/ck-ci/.github/workflows/renovate.yml@vX.Y.Z
```

Every caller grants `id-token: write`, since a called job may ask for no more than its caller grants and the workflow's job asks for it to assume a consumer's release-read role. In a repository that pins no image the identity reaches nothing: no role in the org trusts a default-branch subject except an image repository's own candidate role, which any job on that branch already carries.

```json
{ "extends": ["github>coursekata/ck-ci//renovate/default.json"] }
```

**The workflow is pinned and the preset is not.** A workflow executes code, so it is pinned by tag and the caller's dependency bot moves the pin. The preset is policy that executes nothing, so it resolves from `main` and a change reaches every repository at once, which is the point of having one.

**`renovate.yml` runs on each caller's own `GITHUB_TOKEN`**, not a central App. Pull requests opened that way arrive with their CI held for a person to release; an App would start those runs at once, and no App setting restores the hold. `statuses: write` is required: `minimumReleaseAge` is enforced as a branch status, and without it Renovate creates the branch, fails, and reports "Repository has changed during renovation" without opening the pull request.

**A consumer that pins an image** the image pipeline released, as `<release repository>:run-<run id>@sha256:<digest>` in a tfvars file or in `docker-bake.hcl`, extends `renovate/ecr-image-pin.json` as well and passes the workflow the repository's release-read role as `aws_role_arn`. Renovate then reads the release repository, orders its releases by run id, and moves the pin by pull request, one per consumer for all its pins, with no release age and no dashboard approval. In a bake file the pin is a variable default that a target's `contexts` names. Like `default.json`, the preset resolves from `main`.

A repository-scoped token cannot write under `.github/workflows`, so the preset leaves the `github-actions` manager off and Dependabot keeps that ecosystem. It cannot read Dependabot alerts either, so vulnerability alerts surface through Dependabot and the CVE gate rather than through Renovate.

## Working here

Run `prek install` once. The hooks need `gitleaks`, `jq`, `tofu`, `shellcheck` and `bats` with its `bats-support` and `bats-assert` libraries. shellcheck is needed on `PATH` because actionlint checks the workflows' scripts only with it there; prek installs actionlint, the shellcheck hook and Renovate's config validator itself. On macOS:

```sh
brew install prek gitleaks jq opentofu shellcheck bats-core
brew tap bats-core/bats-core
brew trust --formula bats-core/bats-core/bats-support
brew trust --formula bats-core/bats-core/bats-assert
brew install bats-support bats-assert
```

The image and tf-quality tests are bats suites that run with the hooks, the tf-quality ones with real `tofu` on small modules that use only its built-in provider. The image integration test, `image/tests/integration.sh`, needs Docker, a registry on `localhost:5000` and a docker-container builder as the current builder, which `.github/workflows/ci.yml` sets up.
