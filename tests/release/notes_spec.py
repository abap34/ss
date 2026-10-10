#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "release" / "tools"))
import release_notes as notes

spec = importlib.util.spec_from_file_location("prepare_release", ROOT / "release/tools/prepare-release.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def pull(number, author="alice", sha=None, kind="User"):
    return {
        "number": number, "title": f"Improve feature {number}",
        "user": {"login": author, "type": kind},
        "html_url": f"https://github.com/example/ss/pull/{number}",
        "merged_at": "2026-10-01T00:00:00Z", "merge_commit_sha": sha or str(number),
    }


class ReleaseNotesTests(unittest.TestCase):
    def test_curated_notes_preserve_prose_and_credit_each_contribution(self):
        body = ("### Added\n\n- Added a CLI presenter.\n"
                "- Added fullscreen mode\n  with shared controls (#16).\n"
                "\n### Changed\n\n- Updated languages (#15, #17).")
        prs = [pull(16), pull(15, "automation[bot]", kind="Bot"), pull(17, "automation[bot]", kind="Bot")]
        output = notes.credit_notes(body, prs)
        self.assertIn("- Added a CLI presenter.\n", output)
        self.assertIn("- Added fullscreen mode\n  with shared controls", output)
        self.assertIn("[#16](https://github.com/example/ss/pull/16)", output)
        self.assertIn("Contributed by @alice.", output)
        self.assertIn("[#15](https://github.com/example/ss/pull/15)", output)
        self.assertNotIn("@automation", output)
        self.assertEqual(output.count("### Thanks"), 1)
        self.assertEqual(notes.credit_notes(output, prs), output)

    def test_all_human_authors_are_thanked_once_including_returning_authors(self):
        prs = [pull(1), pull(2), pull(3, "bob")]
        output = notes.credit_notes("### Fixed\n\n- Fixed one (#1, #2).\n- Fixed two (#3).", prs)
        self.assertIn("Contributed by @alice.", output)
        self.assertIn("Contributed by @bob.", output)
        self.assertIn("Thanks to @alice, @bob for contributing", output)

    def test_existing_credits_and_thanks_are_preserved(self):
        body = "### Added\n\n- Added mode ([#16](https://github.com/example/ss/pull/16)), by @alice.\n\n### Thanks\n\nThanks to @alice for testing!"
        self.assertEqual(notes.credit_notes(body, [pull(16)]), body)

    def test_code_and_unrelated_links_do_not_credit_a_pr(self):
        for body in (
            "### Changed\n\n- Documented `#16`.\n\n```md\n- Example (#16).\n```",
            "### Changed\n\n- Documented [#16](https://github.com/other/project/pull/16).",
            "### Changed\n\n- Documented https://github.com/example/ss/pull/160.",
        ):
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "#16 by @alice"):
                notes.credit_notes(body, [pull(16)])

    def test_missing_human_pr_is_reported_instead_of_guessed(self):
        with self.assertRaisesRegex(ValueError, "#16 by @alice"):
            notes.credit_notes("### Added\n\n- Added presentation controls.", [pull(16)])

    def test_drafts_use_pr_titles_and_keep_direct_commits(self):
        prs = [pull(16, sha="merge")]
        output = notes.draft_notes([("direct", "Add a CLI presenter"), ("merge", "Merge pull request #16 from example/branch")], prs)
        self.assertIn("- Add a CLI presenter.", output)
        self.assertIn("- Improve feature 16", output)
        self.assertNotIn("Merge pull request", output)
        self.assertIn("@alice", output)

    def test_collection_is_paginated_get_and_filters_by_included_commits(self):
        old, included, future, closed = pull(1), pull(2), pull(3), pull(4)
        closed["merged_at"] = None
        with patch.object(notes, "command", return_value=json.dumps([[old, included], [future, closed]])) as call:
            prs = notes.collect_pull_requests(ROOT, [("2", "Included"), ("4", "Closed")])
        self.assertEqual([pr["number"] for pr in prs], [2])
        args = call.call_args.args[1]
        self.assertEqual(args[:4], ["gh", "api", "--method", "GET"])
        self.assertIn("--paginate", args)
        self.assertIn("--slurp", args)

    def test_network_failure_is_reported_and_empty_range_needs_no_network(self):
        with patch.object(notes, "command", side_effect=ValueError("Authentication failed")):
            with self.assertRaisesRegex(ValueError, "Authentication failed"):
                notes.collect_pull_requests(ROOT, [("2", "Included")])
            self.assertEqual(notes.collect_pull_requests(ROOT, []), [])

    def test_snapshot_and_unreleased_integration(self):
        cache = ROOT / ".ss-cache"
        cache.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=cache) as tmp:
            root = pathlib.Path(tmp)
            (root / "release").mkdir()
            changelog = root / "release/CHANGELOG.md"
            changelog.write_text("# Changelog\n\n## [Unreleased]\n\n### Added\n\n- Added mode (#16).\n\n## [0.8.2] - 2026-09-17\n\nOld notes.\n")
            snapshot = root / "prs.json"
            snapshot.write_text(json.dumps([pull(16)]))
            with patch.object(notes, "command", side_effect=AssertionError("Unexpected network access")):
                prs = notes.collect_pull_requests(root, [("16", "Included")], snapshot)
            prepare.update_changelog(root, "0.8.3", "2026-10-06", "Unused draft", prs)
            text = changelog.read_text()
            self.assertIn("## [Unreleased]\n\n## [0.8.3] - 2026-10-06", text)
            self.assertIn("Contributed by @alice.", text)
            self.assertTrue(text.endswith("## [0.8.2] - 2026-09-17\n\nOld notes.\n"))

            before = changelog.read_text()
            with self.assertRaisesRegex(ValueError, "#16 by @alice"):
                prepare.update_changelog(root, "0.8.4", "2026-10-07", "### Added\n\n- Missing reference.", prs)
            self.assertEqual(changelog.read_text(), before)

    def test_patch_notes_credit_only_selected_backports(self):
        with patch.object(prepare, "git", side_effect=["Improve mode", "abc1234", "16"]):
            output = prepare.generated_patch_changelog(ROOT, "v0.8.2", ["16"], [pull(16)])
        self.assertIn("Backported Improve feature 16", output)
        self.assertIn("(abc1234)", output)
        self.assertIn("Contributed by @alice.", output)

    def test_range_excludes_previous_tag_and_later_commits(self):
        cache = ROOT / ".ss-cache"
        cache.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=cache) as tmp:
            root = pathlib.Path(tmp)

            def git(*args):
                return subprocess.run(["git", *args], cwd=root, text=True, capture_output=True, check=True, timeout=10).stdout.strip()

            git("init", "-q")
            git("config", "user.name", "Test Author")
            git("config", "user.email", "author@example.com")
            git("commit", "-q", "--allow-empty", "-m", "Previous release")
            git("tag", "v0.8.2")
            git("commit", "-q", "--allow-empty", "-m", "Included change")
            base = git("rev-parse", "HEAD")
            git("commit", "-q", "--allow-empty", "-m", "Later change")
            self.assertEqual(notes.release_commits(root, "v0.8.2", base), [(base, "Included change")])

            snapshot = root / "prs.json"
            snapshot.write_text(json.dumps([pull(16, sha=base)]))
            body = root / "body.md"
            body.write_text("### Added\n\n- Added fullscreen mode (#16).")
            output = subprocess.run([
                sys.executable, str(ROOT / "release/tools/release_notes.py"),
                "--previous-tag", "v0.8.2", "--base", base,
                "--pull-requests", str(snapshot), "--body", str(body),
            ], cwd=root, text=True, capture_output=True, check=True, timeout=10).stdout
            self.assertIn("Contributed by @alice.", output)
            self.assertNotIn("Later change", output)
            self.assertEqual(git("tag"), "v0.8.2")


if __name__ == "__main__":
    unittest.main()
