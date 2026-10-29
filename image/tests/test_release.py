"""release.py's decisions, on plain data: facts in, a plan or a summary out. Nothing here reads a
registry, a repository or the environment."""

from __future__ import annotations

import sys
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "release-action"))

from release import (  # noqa: E402
    Cache,
    Comparison,
    Facts,
    Failure,
    Latest,
    Plan,
    Tag,
    Write,
    children,
    compare,
    latest_run,
    needs_comparison,
    plan,
    summary,
)

A, B, C, K = (f"sha256:{n:064x}" for n in (1, 2, 3, 4))

# A head run releasing a changed build A, with B the latest release and latest and K the build's cache.
FACTS = Facts(
    head=True,
    branch_head="abc",
    release="r.example/release",
    candidate_repository="r.example/candidate",
    candidate=A,
    sha_tag="sha-abc",
    run_tag="run-7",
    tags=(Tag("sha-abc", None), Tag("run-7", None)),
    latest=Latest("run-6", B, "def"),
    latest_tag=B,
    unchanged=False,
    cache=Cache("r.example/cache", K),
)
NOT_COMPARED: dict[str, Any] = {"unchanged": None}


def facts(**changes: Any) -> Facts:
    return replace(FACTS, **changes)


def tags(*pairs: tuple[str, str | None]) -> tuple[Tag, ...]:
    return tuple(Tag(n, d) for n, d in pairs)


def plan_of(**changes: Any) -> Plan:
    return plan(facts(**changes))


def summary_of(**changes: Any) -> str:
    f = facts(**changes)
    return summary(f, plan(f))


class LatestRun(unittest.TestCase):
    def test_the_latest_release_is_the_highest_run_tag_by_number_not_by_text(self) -> None:
        names = ["run-9", "run-10", "run-100", "sha-abc", "latest", "run-x", "run-3-old"]
        self.assertEqual(latest_run(names), "run-100")

    def test_a_repository_with_no_run_tag_holds_no_release(self) -> None:
        self.assertIsNone(latest_run(["sha-abc", "latest"]))
        self.assertIsNone(latest_run([]))

    def test_of_equal_run_ids_the_last_listed_is_the_latest(self) -> None:
        self.assertEqual(latest_run(["run-5", "run-05"]), "run-05")


class Plans(unittest.TestCase):
    def test_a_changed_build_is_copied_under_every_tag_but_the_run_tag_then_made_the_latest(self) -> None:
        p = plan_of()
        self.assertEqual((p.kind, p.target, p.copy), ("new", A, ("sha-abc",)))
        self.assertTrue(p.order and p.released and p.move_latest and p.move_cache)

    def test_the_first_release_with_no_latest_release_is_made_the_latest(self) -> None:
        p = plan_of(latest=None, latest_tag=None, **NOT_COMPARED)
        self.assertEqual((p.kind, p.copy), ("new", ("sha-abc",)))
        self.assertTrue(p.order and p.move_latest)

    def test_every_extra_tag_is_copied_with_the_commits_in_the_callers_order(self) -> None:
        p = plan_of(tags=(*FACTS.tags, Tag("v1", None)))
        self.assertEqual(p.copy, ("sha-abc", "v1"))

    def test_an_unchanged_build_writes_nothing(self) -> None:
        p = plan_of(unchanged=True)
        self.assertEqual((p.kind, p.target, p.copy, p.writes), ("unchanged", B, (), ()))
        self.assertFalse(p.order or p.released or p.move_latest or p.move_cache)

    def test_an_unchanged_build_repairs_a_latest_left_behind(self) -> None:
        p = plan_of(unchanged=True, latest_tag=C)
        self.assertTrue(p.move_latest)
        self.assertFalse(p.order)

    def test_an_unchanged_build_made_without_the_cache_moves_the_cache_and_nothing_else(self) -> None:
        p = plan_of(unchanged=True, always_update_cache=True)
        self.assertEqual(p.copy, ())
        self.assertFalse(p.order)
        self.assertTrue(p.move_cache)

    def test_with_no_cache_repository_the_cache_never_moves(self) -> None:
        self.assertFalse(plan_of(cache=None, always_update_cache=True).move_cache)

    def test_a_release_cut_short_before_its_run_tag_gets_it(self) -> None:
        p = plan_of(tags=tags(("sha-abc", A), ("run-7", None)), **NOT_COMPARED)
        self.assertEqual((p.kind, p.target, p.copy), ("finish", A, ()))
        self.assertTrue(p.order and p.released and p.move_cache)

    def test_a_release_cut_short_after_its_run_tag_gets_latest_and_no_second_run_tag(self) -> None:
        p = plan_of(tags=tags(("sha-abc", A), ("run-7", A)), latest=Latest("run-7", A, None), **NOT_COMPARED)
        self.assertEqual((p.kind, p.copy), ("finish", ()))
        self.assertFalse(p.order)
        self.assertTrue(p.released and p.move_latest)

    def test_an_earlier_release_of_this_commit_that_is_the_latest_stands(self) -> None:
        p = plan_of(tags=tags(("sha-abc", B), ("run-7", None)), **NOT_COMPARED)
        self.assertEqual((p.kind, p.target, p.copy), ("earlier", B, ()))
        self.assertFalse(p.order or p.move_cache)

    def test_an_earlier_release_cut_short_before_its_run_tag_is_made_the_latest_with_this_runs(self) -> None:
        p = plan_of(tags=tags(("sha-abc", C), ("run-7", None)), **NOT_COMPARED)
        self.assertEqual((p.kind, p.target, p.copy), ("earlier", C, ()))
        self.assertTrue(p.order)
        self.assertFalse(p.released or p.move_cache)

    def test_an_earlier_release_cut_short_gets_the_tags_still_missing_on_that_release(self) -> None:
        p = plan_of(tags=tags(("sha-abc", B), ("run-7", None), ("v1", None)), **NOT_COMPARED)
        self.assertEqual((p.kind, p.target, p.copy), ("earlier", B, ("v1",)))
        self.assertFalse(p.order or p.move_cache)

    def test_an_earlier_release_fails_when_one_of_its_tags_names_another_image(self) -> None:
        with self.assertRaisesRegex(Failure, r"^r\.example/release:v1 already names"):
            plan_of(tags=tags(("sha-abc", B), ("run-7", None), ("v1", C)), **NOT_COMPARED)

    def test_a_run_tag_a_rerun_already_wrote_gets_no_second_though_a_higher_run_is_the_latest(self) -> None:
        p = plan_of(
            tags=tags(("sha-abc", A), ("run-7", A)), latest=Latest("run-9", C, None), latest_tag=C, **NOT_COMPARED
        )
        self.assertEqual((p.kind, p.copy), ("finish", ()))
        self.assertFalse(p.order)
        self.assertTrue(p.released and p.move_latest)

    def test_an_earlier_release_is_made_the_latest_when_the_repository_holds_no_release(self) -> None:
        self.assertTrue(plan_of(tags=tags(("sha-abc", C), ("run-7", None)), latest=None, **NOT_COMPARED).order)

    def test_a_run_by_hand_moves_the_cache_though_an_earlier_release_stands(self) -> None:
        p = plan_of(tags=tags(("sha-abc", B), ("run-7", None)), always_update_cache=True, **NOT_COMPARED)
        self.assertFalse(p.order)
        self.assertTrue(p.move_cache)

    def test_a_new_release_copies_the_build_in_once_tags_it_then_orders_it_moves_latest_and_the_cache(self) -> None:
        here = f"r.example/release@{A}"
        self.assertEqual(
            plan_of(tags=(*FACTS.tags, Tag("v1", None))).writes,
            (
                Write("copy", f"r.example/candidate@{A}", "r.example/release:sha-abc"),
                Write("tag", here, "v1"),
                Write("tag", here, "run-7"),
                Write("tag", here, "latest"),
                Write("copy", f"r.example/candidate@{K}", "r.example/cache:current"),
            ),
        )

    def test_an_earlier_release_gets_its_missing_tags_and_the_run_tag_from_itself_never_this_build(self) -> None:
        here = f"r.example/release@{C}"
        self.assertEqual(
            plan_of(tags=tags(("sha-abc", C), ("run-7", None), ("v1", None)), **NOT_COMPARED).writes,
            (Write("tag", here, "v1"), Write("tag", here, "run-7"), Write("tag", here, "latest")),
        )

    def test_a_build_with_the_latest_releases_own_digest_is_unchanged_though_not_compared(self) -> None:
        p = plan_of(latest=Latest("run-6", A, "def"), latest_tag=A, **NOT_COMPARED)
        self.assertEqual((p.kind, p.writes), ("unchanged", ()))
        self.assertFalse(p.released)

    def test_a_released_commit_is_finished_not_judged_unchanged_whatever_the_comparison_said(self) -> None:
        p = plan_of(tags=tags(("sha-abc", A), ("run-7", None)), unchanged=True)
        self.assertEqual(p.kind, "finish")
        self.assertTrue(p.order and p.released)

    def test_an_unchanged_build_writes_no_tags_so_a_tag_that_names_another_image_does_not_fail(self) -> None:
        p = plan_of(unchanged=True, tags=(*FACTS.tags, Tag("v1", C)))
        self.assertEqual((p.kind, p.copy), ("unchanged", ()))

    def test_a_run_whose_commit_is_no_longer_the_head_writes_nothing(self) -> None:
        p = plan_of(head=False)
        self.assertEqual((p.kind, p.target, p.writes), ("behind", None, ()))
        self.assertFalse(p.released)

    def test_a_tag_that_names_another_image_fails_since_release_tags_never_move(self) -> None:
        with self.assertRaises(Failure) as e:
            plan_of(tags=(*FACTS.tags, Tag("main", C)))
        self.assertEqual(
            str(e.exception),
            f"r.example/release:main already names {C}, not this image {A}, and a release tag can't be moved."
            " Every tag must be new to each release.",
        )

    def test_this_runs_tag_naming_another_image_fails(self) -> None:
        with self.assertRaisesRegex(Failure, r"^r\.example/release:run-7 already names"):
            plan_of(tags=tags(("sha-abc", C), ("run-7", B)), latest=Latest("run-6", A, "def"))

    def test_tags_that_include_latest_fail_since_the_release_moves_it_after_the_run_tag(self) -> None:
        with self.assertRaisesRegex(
            Failure, "^The tags must not include latest, which the release moves itself after the run tag.$"
        ):
            plan_of(tags=(*FACTS.tags, Tag("latest", None)))

    def test_tags_without_the_commits_tag_or_this_runs_fail(self) -> None:
        with self.assertRaisesRegex(Failure, "^The tags must include sha-abc, which marks this commit as released.$"):
            plan_of(tags=tags(("run-7", None)))
        with self.assertRaisesRegex(Failure, "^The tags must include run-7, which orders this release.$"):
            plan_of(tags=tags(("sha-abc", None)))


class Comparing(unittest.TestCase):
    def test_a_build_is_compared_only_when_its_commit_has_no_release_and_its_digest_is_not_the_latests(self) -> None:
        self.assertTrue(needs_comparison(facts(**NOT_COMPARED)))
        self.assertFalse(needs_comparison(facts(latest=None, **NOT_COMPARED)))
        self.assertFalse(needs_comparison(facts(tags=tags(("sha-abc", C), ("run-7", None)), **NOT_COMPARED)))
        self.assertFalse(needs_comparison(facts(latest=Latest("run-6", A, None), **NOT_COMPARED)))

    @staticmethod
    def config(**changes: Any) -> dict[str, Any]:
        """One platform's config as a registry returns it, with every field a build sets afresh."""
        c: dict[str, Any] = {
            "architecture": "arm64",
            "os": "linux",
            "created": "2026-10-27T00:00:00Z",
            "config": {
                "Cmd": ["serve"],
                "Labels": {
                    "org.opencontainers.image.created": "2026-10-27T00:00:00Z",
                    "org.opencontainers.image.revision": "def",
                    "org.opencontainers.image.version": "sha-def",
                    "team": "web",
                },
            },
            "rootfs": {"type": "layers", "diff_ids": ["sha256:aa"]},
            "history": [{"created": "2026-10-27T00:00:00Z", "created_by": "COPY f /f # buildkit"}],
        }
        return c | changes

    def labels(self, **labels: str) -> dict[str, Any]:
        c = self.config()
        return {**c["config"], "Labels": {**c["config"]["Labels"], **labels}}

    def test_a_rebuild_that_differs_only_in_what_every_build_sets_afresh_is_unchanged(self) -> None:
        rebuilt = self.config(
            created="2026-10-28T00:00:00Z",
            history=[{"created": "2026-10-28T00:00:00Z", "created_by": "COPY f /f # buildkit"}],
            config=self.labels(
                **{
                    "org.opencontainers.image.created": "x",
                    "org.opencontainers.image.revision": "abc",
                    "org.opencontainers.image.version": "sha-abc",
                }
            ),
        )
        self.assertEqual(compare({"linux/arm64": rebuilt}, {"linux/arm64": self.config()}), Comparison(True, "def"))

    def test_any_other_label_is_a_change(self) -> None:
        built = self.config(config=self.labels(team="api"))
        self.assertEqual(compare({"linux/arm64": built}, {"linux/arm64": self.config()}), Comparison(False, "def"))

    def test_a_healthcheck_alone_is_a_change(self) -> None:
        c = self.config()
        built = self.config(
            config={**c["config"], "Healthcheck": {"Test": ["CMD", "true"]}},
            history=[*c["history"], {"created_by": "HEALTHCHECK", "empty_layer": True}],
        )
        self.assertFalse(compare({"linux/arm64": built}, {"linux/arm64": c}).unchanged)

    def test_another_layer_is_a_change(self) -> None:
        built = self.config(rootfs={"type": "layers", "diff_ids": ["sha256:bb"]})
        self.assertFalse(compare({"linux/arm64": built}, {"linux/arm64": self.config()}).unchanged)

    def test_another_set_of_platforms_is_a_change(self) -> None:
        both = {"linux/arm64": self.config(), "linux/amd64": self.config(architecture="amd64")}
        self.assertFalse(compare(both, {"linux/arm64": self.config()}).unchanged)

    def test_absent_and_null_labels_history_and_config_compare_alike(self) -> None:
        c = self.config()
        no_labels = {k: v for k, v in c["config"].items() if k != "Labels"}
        no_history = {k: v for k, v in c.items() if k != "history"}
        no_config = {k: v for k, v in c.items() if k != "config"}
        for absent, null in (
            (self.config(config=no_labels), self.config(config={**no_labels, "Labels": None})),
            (no_history, self.config(history=None)),
            (no_config, self.config(config=None)),
            (self.config(config={}), self.config(config=None)),
        ):
            self.assertTrue(compare({"linux/arm64": absent}, {"linux/arm64": null}).unchanged)

    def test_a_revision_label_of_false_names_no_commit(self) -> None:
        released = self.config(config=self.labels(**{"org.opencontainers.image.revision": False}))  # pyrefly: ignore[bad-argument-type]
        self.assertIsNone(compare({"linux/arm64": released}, {"linux/arm64": released}).revision)

    def test_an_empty_revision_label_still_names_a_commit(self) -> None:
        released = self.config(config=self.labels(**{"org.opencontainers.image.revision": ""}))
        self.assertEqual(compare({"linux/arm64": released}, {"linux/arm64": released}).revision, "")

    def test_a_release_with_no_revision_label_names_no_commit(self) -> None:
        c = self.config()
        labels = {k: v for k, v in c["config"]["Labels"].items() if k != "org.opencontainers.image.revision"}
        released = self.config(config={**c["config"], "Labels": labels})
        self.assertEqual(compare({"linux/arm64": c}, {"linux/arm64": released}), Comparison(True, None))


class Children(unittest.TestCase):
    def test_a_single_platform_image_is_its_own_manifest(self) -> None:
        self.assertEqual(children({"config": {}}, A), [A])
        self.assertEqual(children({"manifests": None}, A), [A])

    def test_an_index_lists_its_platforms_without_attestations(self) -> None:
        index = {
            "manifests": [
                {"digest": B, "platform": {"os": "linux"}},
                {"digest": C, "platform": {"os": "unknown"}},
                {"digest": K, "platform": None},
            ]
        }
        self.assertEqual(children(index, A), [B, K])

    def test_an_index_with_no_platform_is_unreadable(self) -> None:
        with self.assertRaises(ValueError):
            children({"manifests": []}, A)
        with self.assertRaises(ValueError):
            children({"manifests": [{"digest": C, "platform": {"os": "unknown"}}]}, A)


class Summaries(unittest.TestCase):
    def test_the_summary_names_the_release_every_tag_on_it_and_where_latest_moved_from(self) -> None:
        self.assertEqual(
            summary_of(),
            "### Image release\n\n"
            f"Released `{A}`. `latest` moved to it from `{B}`. This build's cache is now current.\n\n"
            "| Tag |\n|---|\n| r.example/release:sha-abc |\n| r.example/release:run-7 |\n",
        )

    def test_the_summary_says_when_the_repository_held_no_release(self) -> None:
        self.assertIn(
            f"Released `{A}`. The release repository held no release, so this image releases as new."
            " `latest` now names it.\n",
            summary_of(latest=None, latest_tag=None, cache=None, **NOT_COMPARED),
        )

    def test_the_summary_names_the_release_an_unchanged_build_matched_by_commit_when_it_has_one(self) -> None:
        self.assertEqual(
            summary_of(unchanged=True),
            "### Image release\n\n"
            f"Unchanged from the latest release, sha-def (`{B}`), apart from build metadata."
            " Nothing new was released.\n",
        )
        self.assertIn(
            f"Unchanged from the latest release `{B}` apart from build metadata. Nothing new was released."
            f" `latest` moved to it from `{C}`.\n",
            summary_of(unchanged=True, latest=Latest("run-6", B, None), latest_tag=C),
        )

    def test_an_empty_revision_label_is_still_named(self) -> None:
        self.assertIn("release, sha- (`", summary_of(unchanged=True, latest=Latest("run-6", B, "")))

    def test_the_summary_says_when_an_earlier_release_stands_or_this_run_finished_it(self) -> None:
        standing = summary_of(tags=tags(("sha-abc", B), ("run-7", None)), **NOT_COMPARED)
        self.assertIn(
            f"This commit's release is `{B}`. An earlier release stands. Nothing was tagged with {A}.\n", standing
        )
        self.assertIn("| r.example/release:sha-abc |\n", standing)
        self.assertNotIn("| r.example/release:run-7 |", standing)
        self.assertIn(
            f"This commit's release is `{C}`. An earlier release of this commit was cut short before its run tag,"
            f" and this run finished it. Nothing was tagged with {A}. `latest` moved to it from `{B}`.\n",
            summary_of(tags=tags(("sha-abc", C), ("run-7", None)), **NOT_COMPARED),
        )

    def test_the_summary_lists_the_tags_on_the_release_once_the_plan_is_made(self) -> None:
        def table(s: str) -> list[str]:
            return [line.removeprefix("| r.example/release:").removesuffix(" |") for line in s.splitlines()[6:]]

        self.assertEqual(
            table(summary_of(tags=tags(("sha-abc", C), ("run-7", None)), **NOT_COMPARED)), ["sha-abc", "run-7"]
        )
        self.assertEqual(
            table(summary_of(tags=tags(("sha-abc", B), ("run-7", None), ("v1", None)), **NOT_COMPARED)),
            ["sha-abc", "v1"],
        )
        self.assertNotIn("| Tag |", summary_of(unchanged=True, tags=(*FACTS.tags, Tag("v1", B), Tag("v2", C))))

    def test_the_summary_of_a_run_no_longer_the_head_names_the_head_that_releases(self) -> None:
        self.assertEqual(
            summary_of(head=False),
            "### Image release\n\n"
            "The branch has moved on to abc, whose run releases its changes. This run released nothing.\n",
        )


if __name__ == "__main__":
    unittest.main()
