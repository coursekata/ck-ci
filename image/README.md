# Image pipeline

Four composite actions build, check, push and release a repository's container images, one image per call:

| Action | Does |
|---|---|
| `image/build-action` | Builds the image once to an OCI layout on the runner, runs its tests on that build, and loads it into Docker for the caller's checks. It pushes nothing. |
| `image/health-action` | Runs the image's own `HEALTHCHECK` in a container with no network and no mounts, and fails if it does not become healthy. |
| `image/push-action` | Pushes the tested layout and its build cache, byte for byte, by digest and untagged, to a candidate repository. |
| `image/release-action` | Copies a pushed image by digest to a release repository under its tags and makes its build cache current, or, when the image matches the newest release apart from build metadata, releases and tags nothing. It builds nothing. |

A caller orders them in two jobs of its own workflow:

```
build job:    build-action  ->  checks (health-action, the caller's own, or none)  ->  push-action
release job:  release-action
```

A failed step stops its job, so nothing is pushed after a failed check and nothing is released after a failed build job. Nothing enforces that a caller runs a check: a caller with none says so in its workflow, where review sees it. The [`ecr-image-pipeline`](https://github.com/coursekata/ck-tf-modules/tree/main/modules/ecr-image-pipeline) module in ck-tf-modules provides the ECR repositories and roles.

## What it guarantees

Every released digest is exactly the bytes that one default-branch run built and tested, released by a job of that same run that never builds, and tagged with the one commit that built them. push-action sends the tested layout itself, so the registry receives the bytes the tests ran on, and the checks run on an export of the same build whose layers are checked against it. A build that matches the newest release apart from build metadata is released nowhere and tagged nowhere. No pull request can write the release repository, every build reads its cache only from the cache repository's `current` tag, pinned by digest, and nothing deploys a release until a consumer pins its digest in its own files.

## build-action

1. **Checks the targets before building.** The image's bake target must name the stage it builds, the test target must build a stage of its own, and the test target must build every platform the image ships. A platform is compared as Docker names it, so `linux/arm64/v8` is `linux/arm64`. Neither target may set `cache-from`, `cache-to` or `output`, since build-action sets those itself.
2. **Pins the cache.** Unless `no-cache` is set, the cache repository's `current` tag is read once and used by digest, so every step reads the same cache. With no cache yet, the build starts cold and says so in a notice. A lookup the registry refuses fails the build.
3. **Makes the labels and tags.** `docker/metadata-action` makes the image's OCI labels and its tag names from one set of tag settings: `sha-<commit>`, `run-<run id>` and any `extra-tags`. The first two outrank every tag metadata-action makes by default, so the commit is the `version` label, `revision` is the commit the run built and `created` is when. Labels a caller writes in its Dockerfile stay as written, unless metadata-action sets the same key.
4. **Builds the image** to an OCI layout on the runner, and exports its cache to a directory beside it, both under a directory named for the target, so a job can build several images. Nothing leaves the runner.
5. **Runs the tests on that build.** The test target is built with the layout's image swapped in for the stage it builds `FROM`, so the tests run on that image whatever the test target's own settings. Every test step runs fresh, and a test stage whose build never used the image fails, since its tests ran on something else.
6. **Loads the image** for the runner's platform into Docker, as `image-build/<target>:candidate`, from the build's cache. The load is a second export, so it fails unless its layers are the tested layout's for that platform. An image that does not ship the runner's platform loads nothing and warns, and its `image` output is empty.

Inputs: `target` and `test-target` (required), `cache-repository`, `bake-file` (default `docker-bake.hcl`), `no-cache`, `extra-tags`. Outputs: `image`, `digest`, `layout`, `cache-digest`, `cache-layout` and `tags`, one tag name per line, `sha-<commit>` and `run-<run id>` first.

## Checks before the push

A check runs on build-action's `image` output, between build-action and push-action, and a failed check stops the job before anything is pushed.

For an image with a `HEALTHCHECK`, use health-action. It runs the image under compose, from a compose file this repository ships: the image is the only service, with no mounts and no network, so its code holds none of the job's credentials, files or outputs. Docker decides what healthy means, from the image's own interval, timeout, retries and start period, and the run fails if the container turns unhealthy or exits. Ten minutes is only a backstop. On failure the step prints the container's logs. An image that declares no `HEALTHCHECK`, or `HEALTHCHECK NONE`, gets a warning and no run, because compose calls a service with no health check healthy the moment it starts. An empty `image` fails the step, so a caller on a runner whose platform the image does not ship guards it with `if:`.

For an image with no `HEALTHCHECK`, such as a batch job, the caller writes its own step and runs the image the same way, with `docker run --rm --network none` on build-action's `image` and no mounts or env file. Project code never runs as a process on the runner. ck-datalake's dbt runner, for example, must start and stop in its preflight when it has no task environment:

```yaml
      # The runner has no HEALTHCHECK: a batch run's check is that it starts. With no task environment
      # its entrypoint must stop in its preflight, run as the image's own ENTRYPOINT and user. An `if`,
      # not `!`: bash -e does not stop on a negated command that succeeds.
      - name: The runner starts and stops in its preflight
        env:
          IMAGE: ${{ steps.build.outputs.image }}
        run: |
          if docker run --rm --network none "$IMAGE" 2>"$RUNNER_TEMP/runner.err"; then
            echo "::error::The runner exited 0 with no task environment."; exit 1
          fi
          grep -q 'container environment is missing' "$RUNNER_TEMP/runner.err" || { cat "$RUNNER_TEMP/runner.err"; exit 1; }
```

An image whose health check needs other services, such as a database, runs a check of the caller's own too.

## push-action

On a push or a run by hand, after the checks, it pushes the layout's image by digest to the candidate repository, untagged, and the cache layout's manifest beside it, tagged `cache-<run id>-<run attempt>`. Both go with `imagetools create --prefer-index=false` straight from the layouts, so nothing is rebuilt, and a digest a layout does not hold fails and pushes nothing. It uses the `docker` driver and starts no builder.

Inputs, all required: `candidate-repository` and build-action's `layout`, `digest`, `cache-layout` and `cache-digest`. Outputs: `digest` and `cache-digest`.

## release-action

The caller passes the baseline, the newest image in the release repository, found with the registry's own tooling (see The caller), or empty when the repository holds none. The action reads no registry listing itself, so it is the same on every registry.

1. It reads what the release repository holds under this commit's tags. If `sha-<commit>` already names the candidate, an earlier attempt of this commit released it, and the action adds only the tags still missing. If it names another image, an earlier release of this commit stands: nothing is tagged, the action outputs that digest, and the summary and a notice say so. This comes first because a release cut short leaves the candidate as the newest image, and compared with itself it would read as unchanged.
2. Otherwise, with a baseline, it compares the candidate with it. A match makes the candidate unchanged (see When nothing changed): nothing is tagged or copied, and the cache stays unless `always-update-cache` is set.
3. Otherwise it copies the candidate from the candidate repository under every tag and `latest`, in one copy, then moves the cache repository's `current` tag to this build's cache. Every release moves `latest` in the release repository, for development pulls; nothing that deploys or pins names it, and the repository must let that one name move. With no baseline the image releases as new, and the summary says so.

Any tag that already names another image fails the release, since release tags never move, except `latest`, which every release re-points: a tag like `main` cannot be one of them. A rebuild by hand sets `always-update-cache` to move the cache whatever the release does. Every copy keeps the bytes: `--prefer-index=false` stops buildx wrapping a single-platform image in a new index.

The summary names the released digest and the tags on it, or the release the build matched by its commit and digest, and says whether this build's cache became current.

Inputs: `candidate-repository`, `release-repository`, `digest` and `tags` (required), `baseline-digest`, `cache-repository`, `cache-digest`, `always-update-cache`. Outputs: `released`, true when this run copied the image, and `digest`, the released digest or, for an unchanged image, the baseline's.

## When nothing changed

A merge that changes nothing in the image, or only its tests or docs, still builds, and the warm cache keeps that build cheap. Its image differs from the newest release only in build metadata, so release-action releases nothing and tags nothing, and the summary names the release it matched. No consumer sees anything, because nothing deploys a release until its pin moves.

The two images match when, for every platform, their configs are identical once the `created`, `revision` and `version` labels, the image's creation time and each history entry's time are removed. What stays is the layers' content digests, every instruction's history entry and the runtime settings, so a `HEALTHCHECK` change shows in the history even though buildx's parsed config drops it. Any other label, such as one the Dockerfile writes, still counts. A different set of platforms, a config the action cannot read, or no baseline is a change, and the image releases as new.

Its limits:

- The newest release is the baseline, not the image any consumer deploys. A consumer still on an older pin sees every release since in one pull request, which proposes only the newest.
- The comparison reads buildx's view of each config. A change visible only in a config field buildx does not read, with no history entry, would compare as unchanged; every Dockerfile instruction writes a history entry.
- A cold rebuild never matches a release: BuildKit stamps the directories it creates with the build time, so even a `COPY` and a `RUN` that writes nothing give new layer digests, and a run by hand's layers reach the consumer with the next merge. The history-time rule serves the cached case, where a step's recorded time can move while its layers are reused.
- Two merges close together: the second may compare before the first has released, and then releases its own bytes even if they match. Renovate proposes the newer, and the older is never pinned.

## On a run by hand

A build that reads the cache reuses each step whose instruction and earlier steps are unchanged, whatever that step would install today. A run by hand that sets `no-cache` on build-action and `always-update-cache` on release-action builds every step from scratch, runs the tests and checks as a push does, and on release makes its cache current. A cold build does not reproduce its layers: BuildKit stamps the directories it creates, a `COPY`'s parent and a `RUN`'s mount points among them, with the build time, so the rebuilt image differs from every release. On a commit already released, which the default branch's head usually is, that release stands, the cache moves to the rebuilt layers, and the next merge releases them, with a pull request to the consumer. On a commit not yet released it releases as new. The next push reads the new cache, so the image it releases carries the rebuilt layers.

Run it when a cached layer is suspect, or when an image installs packages it does not pin and needs newer ones now. A change to the base image already rebuilds every step. A push that was already building when the run released carries the earlier layers and puts them back in the cache, so run it again once that push has released.

## Adopting it

### Repository settings

- Changes land only through pull requests, with no bypass: rulesets list no bypass actors, and classic branch protection includes administrators.
- The required check is `image / build`, pinned to the GitHub Actions app.
- With a second maintainer, one approval and "Require approval of the most recent reviewable push" are required, and CODEOWNERS covers `.github/**`, `**/Dockerfile*` and `**/docker-bake.hcl`.
- The default `GITHUB_TOKEN` is read-only.
- Where the ruleset requires an approving review, GitHub Actions may not create or approve pull requests, since a workflow's approval would stand in for a person's. A repository that requires none may leave it on, so a workflow-run Renovate can open pull requests.
- Dependency bots run with automerge off. A bot's pull request, like any other, pushes nothing and can only read the cache.
- An environment named `release` exists before any role or secret trusts it, with a "Selected branches" deployment policy naming only the default branch. A workflow that names a missing environment creates it with no rules. Only the release job declares it.
- No workflow in the repository runs on `pull_request_target`.

### Dockerfile and bake file

Each image has a bake target that builds the shipped stage and a test target that builds a stage on top of it, for the same platforms, usually by inheriting them:

```dockerfile
FROM python:3.13-slim@sha256:... AS runtime
COPY . /app

FROM runtime AS test
RUN cd /app && pytest -q
```

```hcl
target "app" {
  context    = "app"
  dockerfile = "Dockerfile"
  target     = "runtime"
  platforms  = ["linux/arm64"]
}

target "app-test" {
  inherits = ["app"]
  target   = "test"
}
```

Set each stage's `WORKDIR` once. Two steps that produce the same layer, such as a second `WORKDIR` that changes nothing, share one creation time in the registry cache, so a cached rebuild rewrites the image's history and gets a new digest. Every merge then releases a new digest from unchanged code, and a deployment that follows it redeploys an identical image.

A served image declares a `HEALTHCHECK` that probes it over loopback, since health-action gives it no network of its own:

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
```

### Registries

ck-tf-modules' `ecr-image-pipeline` module creates, for each image, a candidate, a release and a cache repository, and three roles: a candidate role for default-branch builds, a cache-read role for pull requests, and a release role for the `release` environment. Release tags are immutable there, which `release-action` relies on. Its README has the details.

### The caller

A caller pins each action by a release tag of this repository, never a commit SHA. GitHub resolves a SHA from any fork of a public repository, so a reviewer cannot tell a fork's commit from a real one, while a tag resolves only here, where tags cannot be moved or deleted. The repository's dependency bot should keep the tag form.

Each image gets one workflow with two jobs, and a third where the repository deploys its own images:

- **build**, named `image / build`, the required check. It logs in with the cache-read role on a pull request, or the candidate role when it will push, then runs build-action, its checks and, except on a pull request, push-action.
- **release**, on the default branch only, in the `release` environment. It logs in with the release role, finds the baseline with the registry's own tooling, and runs release-action on the build job's outputs.
- **pin**, where the repository is its own consumer: when the release job released, it dispatches the repository's Renovate workflow, so the pin's pull request opens within minutes instead of on the next daily run. A consumer in another repository gets the pull request from its own Renovate's schedule.

Each login hands its keys to the registry login step alone, never to the job's environment, so no build step can read them. Neither job reads or writes the GitHub Actions cache. The workflow has no path filters: every commit builds every image, the cache keeps an unchanged image cheap, and only a changed image gets its `sha-<commit>` tag.

```yaml
name: image
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:
permissions: {}
concurrency:
  group: image-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  build:
    name: image / build
    runs-on: ubuntu-24.04-arm
    cache-mode: none
    permissions:
      contents: read
      id-token: write
    outputs:
      digest: ${{ steps.push.outputs.digest }}
      cache-digest: ${{ steps.push.outputs.cache-digest }}
      tags: ${{ steps.build.outputs.tags }}
    steps:
      - if: github.event_name == 'workflow_dispatch' && github.ref != 'refs/heads/main'
        run: |
          echo "::error::Run by hand only on main."
          exit 1
      - uses: actions/checkout@<sha> # <version>
        with:
          persist-credentials: false
      # log in: cache-read role on a pull request, candidate role otherwise; skipped on a fork's
      # pull request, which gets no OIDC token
      - id: build
        uses: coursekata/ck-ci/image/build-action@v0.1.0
        with:
          target: app
          test-target: app-test
          cache-repository: ${{ !github.event.pull_request.head.repo.fork && '<cache repo>' || '' }}
          no-cache: ${{ github.event_name == 'workflow_dispatch' }}
      - uses: coursekata/ck-ci/image/health-action@v0.1.0
        with:
          image: ${{ steps.build.outputs.image }}
      - id: push
        if: github.event_name != 'pull_request'
        uses: coursekata/ck-ci/image/push-action@v0.1.0
        with:
          candidate-repository: <candidate repo>
          layout: ${{ steps.build.outputs.layout }}
          digest: ${{ steps.build.outputs.digest }}
          cache-layout: ${{ steps.build.outputs.cache-layout }}
          cache-digest: ${{ steps.build.outputs.cache-digest }}
  release:
    needs: build
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-24.04-arm
    cache-mode: none
    environment: release
    permissions:
      contents: read
      id-token: write
    outputs:
      released: ${{ steps.release.outputs.released }}
    steps:
      # log in with the release role, as the build job does: the keys go to the ECR login step and
      # to the baseline step, never into the job's environment
      # The baseline: the newest tagged image in the release repository, or empty when it holds
      # none. JSON output applies the query once over every page, where text output applies it per
      # page of 100; the tag filter leaves out a multi-platform index's untagged children.
      - id: baseline
        env:
          AWS_ACCESS_KEY_ID: ${{ steps.aws.outputs.aws-access-key-id }}
          AWS_SECRET_ACCESS_KEY: ${{ steps.aws.outputs.aws-secret-access-key }}
          AWS_SESSION_TOKEN: ${{ steps.aws.outputs.aws-session-token }}
          AWS_REGION: <region>
          RELEASE_NAME: <release repository name>
        run: |
          d=$(aws ecr describe-images --repository-name "$RELEASE_NAME" --filter tagStatus=TAGGED \
            --query 'sort_by(imageDetails, &imagePushedAt)[-1].imageDigest' --output json | jq -r '. // empty')
          echo "digest=$d" >>"$GITHUB_OUTPUT"
      - id: release
        uses: coursekata/ck-ci/image/release-action@v0.1.0
        with:
          candidate-repository: <candidate repo>
          release-repository: <release repo>
          cache-repository: <cache repo>
          digest: ${{ needs.build.outputs.digest }}
          baseline-digest: ${{ steps.baseline.outputs.digest }}
          cache-digest: ${{ needs.build.outputs.cache-digest }}
          tags: ${{ needs.build.outputs.tags }}
          always-update-cache: ${{ github.event_name == 'workflow_dispatch' }}
  pin:
    needs: release
    if: needs.release.outputs.released == 'true'
    runs-on: ubuntu-latest
    permissions:
      actions: write
    steps:
      # This repository deploys the image it just released: start Renovate now, so the pin's pull
      # request opens within minutes. The token may dispatch a workflow; it starts no other run.
      - env:
          GH_TOKEN: ${{ github.token }}
        run: gh workflow run renovate.yml --ref main -R "$GITHUB_REPOSITORY"
```

Other CI, such as lint and unit tests, lives in other workflow files.

actionlint 1.7.12 does not know the `cache-mode` job key yet and reports it as unexpected. A caller that runs actionlint ignores that one finding in its `.github/actionlint.yaml`:

```yaml
paths:
  .github/workflows/image.yml:
    ignore:
      - 'unexpected key "cache-mode"'
```

### A build secret

A build that needs a credential, such as a token for a private package registry, declares it in its bake file as an `env=` secret and mounts it where it is used:

```hcl
target "app" {
  # ...
  secret = ["id=registry_token,env=REGISTRY_TOKEN"]
}
```

```dockerfile
RUN --mount=type=secret,id=registry_token,required=true \
    REGISTRY_TOKEN="$(cat /run/secrets/registry_token)" npm ci
```

The caller sets the variable on the `build-action` step's `env`, so the same bake file works on a workstation. The value reaches every build that step runs, pull requests included, and every install script those builds run, so it must be a read-only credential. A fork's pull request gets it empty, and buildx hands an empty variable to the build as an empty secret, so the build fails where it uses the token. A secret mount never enters a layer, but a Dockerfile that copies the secret into one exports it through the cache to every later build.

## When something fails

| Situation | Outcome |
|---|---|
| The targets fail the preflight | The build fails before anything builds |
| A build, test or check fails on a pull request | The required check fails; the pull request cannot merge |
| A build, test or check fails on the default branch | Nothing is pushed or released for that commit; a re-run or the next merge releases |
| A merge that changes nothing in the image, or only its tests or docs | Nothing is released or tagged and no pull request opens; the summary names the release it matched |
| A merge that changes only a label the Dockerfile writes | A change: the image releases |
| The release repository is empty | The image releases as new |
| The candidate ships other platforms than the newest release | A change: the image releases |
| The release fails partway | Re-run failed jobs: the release adds only the tags still missing on the digest its first attempt released |
| A released run is re-run in full and rebuilds another digest | The first release stands, and the summary says so |
| A run by hand | A cold build, whose layers differ from every release's: on a released commit that release stands and the cache moves to the rebuilt layers, which the next merge releases; on an unreleased commit it releases as new |
| The release repository is empty, or the caller's lookup yields nothing | The image releases as new, and the summary says no baseline was given |
| Two merges close together | The second may release its own bytes even if they match the first's; Renovate proposes the newer |
| A consumer's Renovate cannot read the release repository | No pull request opens; the run logs the refusal, and the next daily run tries again |
| The kick after a release fails | The release stands; the next daily Renovate run opens the pull request |
| A tag other than `sha-<commit>` already names another image | The release fails: release tags never move, except `latest`, which every release re-points |
| A merge whose message carries `[skip ci]` | No run starts; that commit gets no release, and the next merge releases its changes |
| An image with no cache yet, or a misnamed cache repository | The build starts cold, with a notice |
| The registry refuses a lookup | The build or release fails rather than guess |
| A replaced cache expires while a build that pinned it runs | The build fails; a re-run reads the current cache |
| A release on a branch the `release` environment does not allow | The release job is refused |
| An image does not become healthy, or its process exits | As a failed test: the pull request's check fails, or nothing is pushed |
| An image declares no `HEALTHCHECK` | health-action warns; the job goes on |
| An image does not ship the runner's platform | A warning; no image is loaded, and health-action given the empty image fails unless the caller guards it |
| A caller runs no check before the push | Its workflow says so; nothing in the actions refuses it |
| A fork's pull request | It gets no OIDC token, so the caller skips the login and passes no cache repository; it builds and tests cold |
| A fork's pull request builds an image that reads the build secret | The build gets the secret empty and fails where it uses it |
| A bake target sets its own cache or output | The build fails before anything builds |

## What it does not claim

- A pull request and its merge are two builds. The pull request tested a build of its merge commit, and the default-branch run builds the merged commit again, once, and releases that build. Pinned inputs, such as base images by digest and lockfiles, give both the same software. Unpinned ones can differ, and the default-branch tests are what stand behind the released bytes.
- Nothing is signed. A released digest maps to its commit through `sha-<commit>` and to its run through `run-<run id>`.
- On ECR, only review keeps the caller's pin on a release tag of this repository.
- Third-party code that runs inside a default-branch build shapes that image. The cache carries it into later builds until its step or an earlier one changes, or a run by hand rebuilds it.
- Anyone who can run the workflow by hand can rebuild the default branch without the cache and replace the cache, with no merge. It builds only reviewed code, but anything that code does not pin resolves again.
- health-action covers the runner's platform only, with no network and no other services.
- A release nobody pins is not deployed. The open Renovate pull request is the only signal that a consumer is behind, and a consumer without Renovate learns of releases from no one.
- The newest release is the baseline, not the deployed image, and only the registry says which release is newest. The caller's baseline step is what answers that, with the registry's own tooling.
- bake runs with the job's environment, so a bake file that names a job variable, such as the OIDC request token, as an `env=` secret or a variable would pass it into the build. Review of the bake file is the guard.
- The build secret reaches third-party code inside every build that reads it.

## Changing a pin

`build-action`, `push-action` and `release-action` each name the buildx version in their `docker/setup-buildx-action` step, `build-action` also names the BuildKit image by tag and digest, and this repository's integration test sets up the same pair. Renovate's pull request for a new release changes every copy. BuildKit and buildx move together, and a new 0.x minor waits for approval on the dependency dashboard. buildx does every registry read, push and copy. Docker and its compose plugin come with the runner image, so nothing else is installed. Actions are pinned by commit SHA.

## Working on it

The scripts sit beside the actions, and each action calls them as `$GITHUB_ACTION_PATH/../<script>.sh`. `tests/` holds their bats tests, which run against a fake `docker` in `tests/bin`, and `tests/integration.sh`, which runs them against real BuildKit, Docker and a registry on `localhost:5000`, or the `REG` it is given, with a docker-container builder as the current builder.
