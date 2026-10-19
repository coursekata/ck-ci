# Image pipeline

A repository's container images are built and tested on every pull request, which pushes nothing. On a push to the default branch, one run builds them again, pushes each by digest to a candidate repository, tests that digest, and releases exactly the tested digest. The job that holds release credentials never builds, and it takes its digests only from the build job of its own run.

One reusable workflow, `.github/workflows/image.yml`, does the work. `modules/ecr-image-pipeline` provides the ECR repositories and roles.

## What it guarantees

Every released digest is exactly the bytes that one default-branch run built and tested, released by a job of that same run that never builds. No pull request run can write the release area, and every build imports caches only from it.

## On a pull request

1. The bake targets are resolved once, with nothing from the job's environment, and the build runs from that definition. Each image target must build the stage its test replaces, and its test must build a stage of its own for the same platforms.
2. One bake call builds every image and every test target. Nothing is pushed and no cache is exported, and each test stage re-runs rather than matching a cache.
3. The build imports the image's release cache, by digest. On ECR that takes the cache-read role. A fork's pull request gets no OIDC token and builds without the cache.
4. Each image's own `HEALTHCHECK` runs (see Health run), on the image loaded into Docker from this build for the runner's platform.

The required check is the build job, `image / build`.

## On a push to the default branch

1. The images are built from the same resolved definition, importing the release cache, and each is pushed by digest to its candidate repository with its cache beside it, tagged `cache-<run id>-<run attempt>`. Both digests come from the build's own metadata, so no tag is read back.
2. Each image's tests run on its digest: the stage the test target builds on is replaced by `docker-image://<candidate>@<digest>`, with no cache imported or exported and `no-cache` set. A test whose stages never build on that image fails, since its tests would have run on something else.
3. Each image's own `HEALTHCHECK` runs on the tested candidate, pulled by digest for the runner's platform. A failure fails the build job, so nothing is released.
4. The release job, in the `release` environment, copies each tested image by digest to its release repository as `sha-<commit>` and `run-<run id>`, and its cache to the cache repository's `current` tag, then reads every tag back. It outputs the released digests.

A release repository that already holds `sha-<commit>` keeps it. Re-running failed jobs finishes whatever an earlier attempt left. A full re-run of a push that rebuilt the image leaves the first release and the cache where they are.

## On a run by hand

A build that imports the cache reuses each step whose instruction and earlier steps are unchanged, whatever that step would install today. Running the caller's workflow by hand on the default branch builds its head commit without the cache, tests and health-checks each image as a push does, and moves the `current` tag to the run's cache. A commit with no release yet is released. A commit already released keeps that release: `sha-<commit>` never moves, the run adds no `run-<run id>` tag, and the job outputs the existing digest while its summary notes the rebuilt one. The next push imports the new cache, so the image it releases carries the rebuilt layers. The caller's `on:` must list `workflow_dispatch`.

Run it when a cached layer is suspect, or when an image installs packages it does not pin and needs newer ones now. A change to the base image already rebuilds every step. A push that was already building when the run released carries the earlier layers and puts them back in the cache, so run it again once that push has released.

## Health run

Each image runs its own `HEALTHCHECK` under compose, from a compose file this repository ships: the image is the only service, with no mounts and no network, so its code holds none of the job's credentials, files or outputs. Docker decides what healthy means, using the image's own interval, timeout, retries and start period, and the run fails if the container turns unhealthy or exits. Ten minutes is only a backstop. On failure the job prints the container's logs.

An image that declares no `HEALTHCHECK`, or `HEALTHCHECK NONE`, gets a warning and no run, because compose calls a service with no health check healthy the moment it starts. An image that does not ship the runner's platform gets a warning and no run too. Set `"healthcheck": false` on a target to skip its run without the warning: for an image that needs its database or the network to become healthy, or one that runs to completion rather than serving.

## Adopting it

### Repository settings

- Changes land only through pull requests, with no bypass: rulesets list no bypass actors, and classic branch protection includes administrators.
- The required check is `image / build`, pinned to the GitHub Actions app.
- With a second maintainer, one approval and "Require approval of the most recent reviewable push" are required, and CODEOWNERS covers `.github/**`, `**/Dockerfile*` and `**/docker-bake.hcl`.
- The default `GITHUB_TOKEN` is read-only.
- Where the ruleset requires an approving review, GitHub Actions may not create or approve pull requests, since a workflow's approval would stand in for a person's. A repository that requires none may leave it on, so a workflow-run Renovate can open pull requests.
- Dependency bots run with automerge off. Which bots a repository runs is its own choice: a bot's pull-request run, like any other, pushes nothing and can only read the release cache.
- Every job that logs in to a cloud calls only an org reusable workflow, never a third-party action directly, so a dependency bot's unreviewed update to that action cannot reach the credentials.
- An environment named `release` exists before any role or secret trusts it, with a "Selected branches" deployment policy naming only the default branch. A workflow that names a missing environment creates it with no rules. Only the shared workflow's release job declares it.
- GitHub-hosted runners only. No workflow in the repository runs on `pull_request_target`.

### Dockerfile and bake file

Each image has a bake target that builds the shipped stage and a test target that builds a stage on top of it. The image target's `target` stage is what the caller's `replaces` names, and the test target builds for the same platforms, usually by inheriting them:

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

An image whose stage is not the one its test replaces is refused before anything builds, and a test whose stages never build on the replaced stage fails.

Set each stage's `WORKDIR` once. Two steps that produce the same layer, such as a second `WORKDIR` that changes nothing, share one creation time in the registry cache, so a cached rebuild rewrites the image's history and gets a new digest. Every merge then releases a new digest from unchanged code, and a deployment that follows it redeploys an identical image.

A served image declares a `HEALTHCHECK` that probes it over loopback, since the health run gives it no network:

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
```

### Registries

`modules/ecr-image-pipeline` creates, for each image, a candidate, a release and a cache repository, and three roles: a candidate role for default-branch builds, a cache-read role for pull requests, and a release role for the `release` environment. Its README has the details.

### The caller

Each repository has one caller workflow with one job. It pins the shared workflow by a release tag of this repository, never a commit SHA. GitHub resolves a SHA from any fork of a public repository, so a reviewer cannot tell a fork's commit from a real one, while a tag resolves only here, where tags cannot be moved or deleted. The repository's dependency bot should keep the tag form.

```yaml
name: image

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

jobs:
  image:
    cache-mode: none
    uses: coursekata/ck-tf-modules/.github/workflows/image.yml@vX.Y.Z
    with:
      targets: >-
        [{"target": "app", "test": "app-test", "replaces": "runtime",
          "candidate": "123456789012.dkr.ecr.us-west-2.amazonaws.com/ck-example-prd-app-image-candidate",
          "release": "123456789012.dkr.ecr.us-west-2.amazonaws.com/ck-example-prd-app-image-release",
          "cache": "123456789012.dkr.ecr.us-west-2.amazonaws.com/ck-example-prd-app-image-cache"}]
      aws-region: us-west-2
      candidate-role-arn: arn:aws:iam::123456789012:role/ck-example-prd-image-candidate
      cache-read-role-arn: arn:aws:iam::123456789012:role/ck-example-prd-image-cache-read
      release-role-arn: arn:aws:iam::123456789012:role/ck-example-prd-image-release
      runner: ubuntu-24.04-arm
```

Other CI, such as lint and unit tests, lives in other workflow files.

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

The caller passes the value and names the variable, so the same bake file works on a workstation:

```yaml
    with:
      # ...
      build-secret-env: REGISTRY_TOKEN
    secrets:
      build-secret: ${{ secrets.REGISTRY_TOKEN }}
```

The value reaches every build of the repository, pull requests included, and every install script those builds run, so it must be a read-only credential. A fork's pull request gets it empty: buildx hands an unset variable to the build as an empty secret, so the build fails where it uses the token. A secret mount never enters a layer, but a Dockerfile that copies the secret into one exports it through the cache to every later pull request.

## When something fails

| Situation | Outcome |
|---|---|
| A build or test fails on a pull request | The required check fails; the pull request cannot merge |
| A build or test fails on the default branch | Nothing is released for that commit; a re-run or the next merge releases |
| The release fails partway | Re-run failed jobs: the release copies the same run's digests, and tags already written stand |
| A released run is re-run in full | The first release stands, and the job summary notes the rebuilt digest |
| A merge whose message carries `[skip ci]` | No run starts; that commit gets no release, and the next merge releases its changes |
| An image with no release cache yet | The build starts cold |
| A run by hand on another branch | The build job fails before building |
| A replaced cache expires while a build that pinned it runs | The build fails; a re-run imports the current cache |
| An image does not become healthy, or its process exits | As a failed test: the pull request's check fails, or nothing is released |
| An image declares no `HEALTHCHECK`, or does not ship the runner's platform | A warning; the job goes on |
| A fork's pull request builds an image that reads the build secret | The build gets the secret empty and fails where it uses it |

## What it does not claim

- The release is a second build. The pull request tested a build of its merge commit; the default-branch run builds the merged commit again and tests that. Pinned inputs, such as base images by digest and lockfiles, give both builds the same software. Unpinned ones can differ, and the default-branch tests are what stand behind the released bytes.
- Nothing is signed. A released digest maps to its commit through `sha-<commit>` and to its run through `run-<run id>`.
- On ECR, only review keeps the caller's pin on a release tag of this repository.
- Third-party code that runs inside a default-branch build shapes that image. The cache carries it into later builds until its step or an earlier one changes, or a run by hand rebuilds it.
- Anyone who can run the workflow by hand can rebuild the default branch without the cache and replace the cache, with no merge. It builds only reviewed code, but anything that code does not pin resolves again.
- The health run covers the runner's platform only, with no network and no other services.
- The build secret reaches third-party code inside every build that reads it.

## Changing a pin

`image-pipeline/pins.sh` holds the BuildKit image and the buildx version, and the workflow hands both to `docker/setup-buildx-action`. buildx does every registry read, push and copy except the health run's pull, which Docker makes by digest. Docker and its compose plugin come with the runner image, so nothing else is installed. Actions are pinned by commit SHA in the workflow.
