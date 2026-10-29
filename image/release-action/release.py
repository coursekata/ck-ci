"""Releases the head of the branch.

Reads the facts, plans the writes, makes them in the plan's order, and writes the step summary and
outputs. Only reads happen before the plan, so a run that stops before a write has changed nothing.
crane does every registry read and write, with the login the caller made; a copy keeps the bytes and
the digest. The decisions are pure functions of the facts, tested on data in tests/test_release.py.

Outputs digest (this commit's release, or the latest release when unchanged; empty when no longer the
head) and released.
env: CANDIDATE, RELEASE, CACHE, DIGEST, TAGS, CACHE_DIGEST, ALWAYS_UPDATE_CACHE, TOKEN (read access
     to the repository, or empty), and the job's GITHUB_* variables
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Any, Literal

HERE = Path(__file__).resolve().parent
READ_REGISTRY = HERE.parent / "lib" / "read-registry.sh"

Configs = dict[str, dict[str, Any]]


@dataclass(frozen=True)
class Tag:
    name: str
    digest: str | None  # what the tag names in the release repository now, or None


@dataclass(frozen=True)
class Latest:
    tag: str  # its run tag
    digest: str
    commit: str | None  # the commit its revision label names, read only when compared


@dataclass(frozen=True)
class Cache:
    repository: str
    digest: str


@dataclass(frozen=True)
class Facts:
    head: bool  # whether this run's commit is still the branch's head
    branch_head: str
    release: str  # the release repository
    candidate_repository: str
    candidate: str  # the build's digest in candidate_repository
    sha_tag: str
    run_tag: str
    tags: tuple[Tag, ...] = ()  # each tag the caller asked for, in the caller's order
    latest: Latest | None = None
    latest_tag: str | None = None  # what the latest tag names now
    unchanged: bool | None = None  # whether the build matches the latest release; None if not compared
    cache: Cache | None = None
    always_update_cache: bool = False


@dataclass(frozen=True)
class Write:
    op: Literal["copy", "tag"]
    source: str
    to: str


Kind = Literal["new", "finish", "earlier", "unchanged", "behind"]


@dataclass(frozen=True)
class Plan:
    """What the release does.

    kind says which case this is: new, finish (this build was released already, in full or cut
    short), earlier (another build of this commit was released), unchanged, or behind (no longer the
    head). copy lists the missing tags to put on the target, apart from the run tag; order says
    whether the target gets the run tag, which makes it the latest release, and released whether
    this build is this commit's release.
    """

    kind: Kind
    target: str | None
    copy: tuple[str, ...] = ()
    order: bool = False
    move_latest: bool = False
    move_cache: bool = False
    released: bool = False
    writes: tuple[Write, ...] = ()


class Failure(Exception):
    """A release that must not go ahead; the message is the step's error."""


class Reported(Exception):
    """A failure whose error a tool has already printed."""


def truthy(value: Any) -> bool:
    """jq's truth: only null and false are false, so an empty string or list is true."""
    return value is not None and value is not False


def latest_run(names: list[str]) -> str | None:
    """The highest run-<id> among tag names, the last of equals. Run ids only increase; commit
    hashes do not sort."""
    runs = [n for n in names if re.fullmatch(r"run-[0-9]+", n)]
    return max(reversed(runs), key=lambda n: int(n.removeprefix("run-")), default=None)


def normal(configs: Configs) -> Configs:
    """Configs with what every build sets afresh removed: the creation times, each history entry's
    time, and the created, revision and version labels. What stays is the layers' content digests,
    every instruction's history entry and the runtime settings, a HEALTHCHECK among them, and any
    other label."""
    dropped = {f"org.opencontainers.image.{k}" for k in ("created", "revision", "version")}
    out: Configs = {}
    for platform, config in configs.items():
        c = {k: v for k, v in config.items() if k != "created"}
        # Every config gets history and config.Labels, so absent and null compare alike.
        history: Any = c.get("history")
        c["history"] = [{k: v for k, v in h.items() if k != "created"} for h in history] if truthy(history) else history
        inner = c.get("config") or {}
        labels: Any = inner.get("Labels")
        c["config"] = {
            **inner,
            "Labels": {k: v for k, v in labels.items() if k not in dropped} if truthy(labels) else labels,
        }
        out[platform] = c
    return out


@dataclass(frozen=True)
class Comparison:
    unchanged: bool
    revision: str | None  # the commit the release names in its revision label


def compare(built: Configs, released: Configs) -> Comparison:
    """Whether a build's configs match a release's apart from build metadata. Another set of
    platforms is a change."""
    revisions = (
        ((c.get("config") or {}).get("Labels") or {}).get("org.opencontainers.image.revision")
        for c in released.values()
    )
    return Comparison(normal(built) == normal(released), next((r for r in revisions if truthy(r)), None))


def commit_release(f: Facts) -> str | None:
    """What this commit's tag names already, if anything."""
    return next((t.digest for t in f.tags if t.name == f.sha_tag), None)


def needs_comparison(f: Facts) -> bool:
    """The build is compared only when its commit has no release yet: once sha-<commit> names one,
    that release stands whatever the build is. A build with the latest release's own digest is
    unchanged without a comparison."""
    return f.latest is not None and commit_release(f) is None and f.latest.digest != f.candidate


def plan(f: Facts) -> Plan:
    """The release for these facts. A release becomes the latest only with its run tag, written after
    its other tags and before latest, so the head's next run finishes a release cut short at any
    point."""
    if not f.head:
        return Plan(kind="behind", target=None)
    now = {t.name: t.digest for t in f.tags}
    if f.sha_tag not in now:
        raise Failure(f"The tags must include {f.sha_tag}, which marks this commit as released.")
    if f.run_tag not in now:
        raise Failure(f"The tags must include {f.run_tag}, which orders this release.")
    if "latest" in now:
        raise Failure("The tags must not include latest, which the release moves itself after the run tag.")

    latest = f.latest.digest if f.latest else None
    unchanged = f.unchanged is True or (latest is not None and latest == f.candidate)
    kind: Kind
    target: str | None
    if now[f.sha_tag] is None and unchanged:
        kind, target = "unchanged", latest
    elif now[f.sha_tag] is None:
        kind, target = "new", f.candidate
    elif now[f.sha_tag] == f.candidate:
        kind, target = "finish", f.candidate
    else:
        kind, target = "earlier", now[f.sha_tag]
    this_build = kind in ("new", "finish")
    tagging = kind != "unchanged"

    taken = [t for t in f.tags if t.digest is not None and t.digest != target]
    if tagging and taken:
        raise Failure(
            f"{f.release}:{taken[0].name} already names {taken[0].digest}, not this image {target}, "
            "and a release tag can't be moved. Every tag must be new to each release."
        )
    p = Plan(
        kind=kind,
        target=target,
        copy=tuple(t.name for t in f.tags if t.digest is None and t.name != f.run_tag) if tagging else (),
        order=target != latest and now[f.run_tag] != target,
        move_latest=f.latest_tag != target,
        move_cache=f.cache is not None and (this_build or f.always_update_cache),
        released=this_build,
    )
    return replace(p, writes=writes(f, p))


def writes(f: Facts, p: Plan) -> tuple[Write, ...]:
    """The plan's writes as crane makes them, in order. A copy puts the image at `source` in another
    repository under the reference `to`; a tag gives the image at `source` the tag `to` in its own
    repository. A new release's first tag copies the build into the release repository; every other
    tag names an image already there, so a release never mixes images."""
    here = f"{f.release}@{p.target}"
    out = [
        Write("copy", f"{f.candidate_repository}@{f.candidate}", f"{f.release}:{name}")
        if p.kind == "new" and i == 0
        else Write("tag", here, name)
        for i, name in enumerate(p.copy)
    ]
    if p.order:
        out.append(Write("tag", here, f.run_tag))
    if p.move_latest:
        out.append(Write("tag", here, "latest"))
    if p.move_cache and f.cache:
        out.append(Write("copy", f"{f.candidate_repository}@{f.cache.digest}", f"{f.cache.repository}:current"))
    return tuple(out)


def named(f: Facts, p: Plan) -> list[str]:
    """The tags on the release once the plan is made: those already on it and those the plan writes."""
    if p.kind in ("unchanged", "behind"):
        return []
    return [t.name for t in f.tags if t.digest == p.target or t.name in p.copy or (t.name == f.run_tag and p.order)]


def summary(f: Facts, p: Plan) -> str:
    """The step summary."""
    out = "### Image release\n\n"
    if p.kind == "behind":
        return out + (
            f"The branch has moved on to {f.branch_head}, whose run releases its changes. This run released nothing.\n"
        )
    if p.kind == "unchanged":
        matched = (
            f", sha-{f.latest.commit} (`{p.target}`)," if f.latest and f.latest.commit is not None else f" `{p.target}`"
        )
        line = f"Unchanged from the latest release{matched} apart from build metadata. Nothing new was released."
    elif p.released:
        line = f"Released `{p.target}`."
    else:
        line = f"This commit's release is `{p.target}`."
    if p.kind == "earlier" and p.order:
        line += (
            " An earlier release of this commit was cut short before its run tag, and this run finished it."
            f" Nothing was tagged with {f.candidate}."
        )
    elif p.kind == "earlier":
        line += f" An earlier release stands. Nothing was tagged with {f.candidate}."
    elif p.kind == "new" and f.latest is None:
        line += " The release repository held no release, so this image releases as new."
    if p.move_latest:
        line += " `latest` now names it." if f.latest_tag is None else f" `latest` moved to it from `{f.latest_tag}`."
    if p.move_cache:
        line += " This build's cache is now current."
    out += line + "\n"
    tags = named(f, p)
    if tags:
        out += "\n| Tag |\n|---|\n" + "".join(f"| {f.release}:{t} |\n" for t in tags)
    return out


def read(*args: str) -> str:
    """A crane read through read-registry.sh: its answer, or empty for a missing tag or repository.
    Any other failure fails the release, with read-registry.sh's error."""
    done = subprocess.run([str(READ_REGISTRY), *args], stdout=subprocess.PIPE, text=True)
    if done.returncode != 0:
        raise Reported
    return done.stdout.strip()


def crane(*args: str) -> str:
    return subprocess.run(["crane", *args], stdout=subprocess.PIPE, text=True, check=True).stdout


def children(manifest: dict[str, Any], digest: str) -> list[str]:
    """The manifests whose configs an image has: its own for a single-platform image, each platform's
    for an index, whose attestation entries are left out. An index with none is unreadable."""
    if not truthy(manifest.get("manifests")):
        return [digest]
    found = [m["digest"] for m in manifest["manifests"] if (m.get("platform") or {}).get("os") != "unknown"]
    if not found:
        raise ValueError(f"the index {digest} names no platform")
    return found


def read_configs(ref: str) -> Configs:
    """An image's configs keyed by platform (os/architecture[/variant])."""
    repository, digest = ref.rsplit("@", 1)
    configs: Configs = {}
    for child in children(json.loads(crane("manifest", ref)), digest):
        c = json.loads(crane("config", f"{repository}@{child}"))
        configs["/".join(p for p in (c.get("os"), c.get("architecture"), c.get("variant")) if p)] = c
    return configs


def branch_head(env: dict[str, str]) -> str:
    """The branch's head, read live. The token goes in a header through git's environment, never in a
    command line or URL."""
    ref = env["GITHUB_REF"]
    # A tag's ref reads as its tag object, never the commit, so a run on one would release nothing
    # and pass. A pull request's merge ref is a branch head GitHub keeps.
    if not (ref.startswith("refs/heads/") or re.fullmatch(r"refs/pull/.*/merge", ref, re.S)):
        raise Failure(f"{ref} is not a branch, so nothing was released. release-action releases the head of a branch.")
    git_env = dict(env)
    if env.get("TOKEN"):
        auth = base64.b64encode(f"x-access-token:{env['TOKEN']}".encode()).decode()
        git_env |= {
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.extraHeader",
            "GIT_CONFIG_VALUE_0": f"Authorization: Basic {auth}",
        }
    remote = f"{env['GITHUB_SERVER_URL']}/{env['GITHUB_REPOSITORY']}"
    # ls-remote exits 0 for a ref that does not exist.
    done = subprocess.run(["git", "ls-remote", remote, ref], stdout=subprocess.PIPE, text=True, env=git_env)
    lines = done.stdout.splitlines() if done.returncode == 0 else []
    head = next((sha for sha, _, name in (line.partition("\t") for line in lines) if name == ref), "")
    if not head:
        raise Failure(f"Could not read {ref}'s head from {env['GITHUB_REPOSITORY']}.")
    return head


def gather(env: dict[str, str]) -> Facts:
    """Every fact the plan needs, read from the branch and the registry."""
    head, sha, release = branch_head(env), env["GITHUB_SHA"], env["RELEASE"]
    f = Facts(
        head=head == sha,
        branch_head=head,
        release=release,
        candidate_repository=env["CANDIDATE"],
        candidate=env["DIGEST"],
        sha_tag=f"sha-{sha}",
        run_tag=f"run-{env['GITHUB_RUN_ID']}",
    )
    if not f.head:
        return f
    tags = tuple(Tag(n, read("digest", f"{release}:{n}") or None) for n in env["TAGS"].split("\n") if n)
    run = latest_run(read("ls", release).splitlines())
    latest = Latest(run, read("digest", f"{release}:{run}"), None) if run else None
    f = replace(f, tags=tags, latest=latest)
    if f.latest and needs_comparison(f):
        built, baseline = f"{f.candidate_repository}@{f.candidate}", f"{release}@{f.latest.digest}"
        try:
            c = compare(read_configs(built), read_configs(baseline))
        except (subprocess.CalledProcessError, ValueError, KeyError, TypeError, AttributeError) as e:
            raise Failure(
                f"Could not read the configs of {built} and {baseline} to compare them, so nothing was released."
            ) from e
        f = replace(f, unchanged=c.unchanged, latest=replace(f.latest, commit=c.revision))
    cache, cache_digest = env.get("CACHE", ""), env.get("CACHE_DIGEST", "")
    return replace(
        f,
        latest_tag=read("digest", f"{release}:latest") or None,
        cache=Cache(cache, cache_digest) if cache and cache_digest else None,
        always_update_cache=env.get("ALWAYS_UPDATE_CACHE") == "true",
    )


def main() -> int:
    # Line by line, so the log interleaves with what git and crane print.
    sys.stdout.reconfigure(line_buffering=True)  # pyrefly: ignore[missing-attribute]
    env = dict(os.environ)
    try:
        print("::group::Read the facts")
        facts = gather(env)
        print(json.dumps(asdict(facts), indent=2))
        print("::endgroup::")
        p = plan(facts)
        print(json.dumps(asdict(p), indent=2))
    except Reported:
        return 1
    except Failure as e:
        if e.__cause__:
            print(e.__cause__, file=sys.stderr)
        print(f"::error::{e}")
        return 1
    # In the plan's order, so a run that stops between two writes leaves nothing a consumer reads: a
    # release without its run tag is not the latest, and the head's next run finishes it.
    for w in p.writes:
        if subprocess.run(["crane", w.op, w.source, w.to]).returncode != 0:
            print(f"::error::crane {w.op} {w.source} {w.to} failed, so the release stopped there.")
            return 1
    with open(env["GITHUB_STEP_SUMMARY"], "a") as s:
        s.write(summary(facts, p) + "\n")
    with open(env["GITHUB_OUTPUT"], "a") as o:
        o.write(f"digest={p.target or ''}\nreleased={'true' if p.released else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
