#!/usr/bin/env python3
"""Exercise release orchestration with real temporary Git repos and offline tool doubles."""
import argparse
import copy
import importlib.util
import io
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseFlowTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="eucaly release ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "eucaly").mkdir()
        shutil.copy2(ROOT / "eucaly/Info.plist", self.root / "eucaly/Info.plist")
        (self.root / "VERSION").write_text("4.0.1\n")
        (self.root / ".gitignore").write_text("build/\n")
        self.git("init", "--quiet")
        self.git("config", "user.name", "Release Regression")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "tag.gpgsign", "false")
        self.git("remote", "add", "origin", "https://github.com/sukujgrg/eucaly.git")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD")
        self.calls = []
        self.failures = {}
        self.hooks = {}
        self.assets = {}
        self.use_asset_digests = True
        self.submissions = {}
        self.finished_submissions = set()
        self.notary_hash_transform = lambda value: value
        self.previous_release = None
        self.previous_feed = None
        self.signing_team = "TEAM"
        self.signature_overrides = {}
        self.missing_arm_binary = None
        self.main_architectures = "arm64"
        self.missing_binary = None
        self.remote_tag = None
        self.existing_release = False
        self.hidden_draft_reads = 0
        self.conclusions = ["success"]
        self.ci_sha = self.commit
        self.ci_branch = "main"
        self.ci_event = "push"
        self.ci_status = "completed"
        self.missing_runs = 0
        self.pushed = True
        self.notary_status = "Accepted"
        self.fail_feed = False
        self.after_archive = lambda: None
        self.latest = None
        self.latest_reads = 0
        self.latest_changed = False
        self.actual_run = release.run
        self.addCleanup(patch.stopall)
        patch.object(release, "ROOT", self.root).start()
        patch.object(release, "run", side_effect=self.tool).start()
        patch.object(release, "github", side_effect=self.api).start()
        patch.object(release.platform, "system", return_value="Darwin").start()
        patch.object(release.shutil, "which", side_effect=lambda value: "/usr/bin/" + value).start()
        patch.object(release.time, "sleep").start()
        patch.dict(os.environ, {"CI": "false", "GITHUB_ACTIONS": "false"}).start()
        self.output = io.StringIO()
        self.stdout_context = redirect_stdout(self.output)
        self.stdout_context.__enter__()
        self.addCleanup(self.stdout_context.__exit__, None, None, None)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    @property
    def existing_release(self):
        return self.remote_release is not None

    @existing_release.setter
    def existing_release(self, value):
        self.remote_release = ({"id": 42, "tag_name": "v4.0.1", "draft": False,
                                "target_commitish": self.commit, "prerelease": False,
                                "body": "Unrelated release"} if value else None)

    @property
    def directory(self):
        return self.root / "build/release/v4.0.1"

    @property
    def state(self):
        return json.loads((self.directory / "state.json").read_text())

    def api(self, repo, path, optional=False, expected_type=dict):
        self.assertEqual(repo, "sukujgrg/eucaly")
        if path == "releases?per_page=100&page=1":
            if self.remote_release and self.remote_release["draft"] and self.hidden_draft_reads:
                self.hidden_draft_reads -= 1
                return copy.deepcopy([self.previous_release] if self.previous_release else [])
            return copy.deepcopy([item for item in (self.remote_release, self.previous_release) if item])
        if path == "releases/42":
            return copy.deepcopy(self.remote_release)
        if path == "releases/42/assets?per_page=100&page=1":
            return [{key: value for key, value in item.items() if key != "data"} for item in self.assets.values()]
        if self.previous_release and path == f"releases/{self.previous_release['id']}/assets?per_page=100&page=1":
            return [{"name": "appcast.xml"}] if self.previous_feed is not None else []
        if path.startswith("git/ref/tags/"):
            # make release pushes an annotated tag: the ref points to a tag
            # object, whose target must be read through the Git tags API.
            return {"object": {"type": "tag", "sha": "release-tag-sha"}} if self.remote_tag else None
        if path == "git/tags/release-tag-sha":
            return {"object": {"type": "commit", "sha": self.remote_tag}}
        if path.startswith("commits/tags/"):
            raise release.ReleaseError("GitHub cannot resolve tags/v4.0.1 as a commit name (HTTP 422).")
        if path == "commits/" + self.commit:
            return {"sha": self.commit} if self.pushed else None
        if path == "releases/latest":
            self.latest_reads += 1
            if self.latest_changed and self.latest_reads > 1:
                return {"tag_name": "v4.0.2"}
            return {"tag_name": self.latest} if self.latest else None
        self.fail(f"Unexpected GitHub request: {path}")

    def hit(self, stage, phase):
        hook = self.hooks.get((stage, phase))
        if hook:
            hook()
        key = (stage, phase)
        if key in self.failures:
            self.failures[key] -= 1
            if self.failures[key] == 0:
                del self.failures[key]
                raise subprocess.CalledProcessError(1, [stage, phase])

    def tool(self, *args, capture=False, output=None, include_stderr=False):
        args = tuple(str(arg) for arg in args)
        self.calls.append(args)
        if args[:2] == ("codesign", "-dv"):
            self.assertTrue(capture and include_stderr)
        if args[0] == "xcodebuild":
            stage = "archive" if "archive" in args else "export" if "-exportArchive" in args else "resolve"
        elif args[0] in ("gh", "xcrun") and len(args) > 2:
            stage = args[2]
        elif len(args) > 1 and args[1].endswith("update-feed.py"):
            stage = "feed"
        else:
            stage = args[0]
        self.hit(stage, "before")
        result = self.fake_command(args, capture)
        if output is not None:
            Path(output).write_text(result or "")
        self.hit(stage, "after")
        return result

    def fake_command(self, args, capture):
        if args[:3] in (("gh", "run", "list"), ("gh", "run", "view")):
            self.assertIn("--repo", args)
            if args[2] == "list":
                self.assertEqual(args[args.index("--commit") + 1], self.commit)
                self.assertEqual(args[args.index("--workflow") + 1], "validate.yml")
                self.assertEqual(args[args.index("--branch") + 1], "main")
                self.assertEqual(args[args.index("--event") + 1], "push")
                if self.missing_runs:
                    self.missing_runs -= 1
                    return "[]"
            conclusion = self.conclusions.pop(0) if len(self.conclusions) > 1 else self.conclusions[0]
            result = {"databaseId": 123, "headSha": self.ci_sha, "status": self.ci_status,
                      "headBranch": self.ci_branch, "event": self.ci_event,
                      "conclusion": conclusion, "url": "https://github.com/sukujgrg/eucaly/actions/runs/123"}
            self.ci_status = "completed"
            return json.dumps([result] if args[2] == "list" else result)
        if args[:2] == ("git", "push"):
            self.remote_tag = self.git("rev-parse", "refs/tags/v4.0.1^{commit}")
            return
        if args[:3] == ("gh", "release", "create"):
            self.assertIn("--draft", args)
            self.assertIn("--verify-tag", args)
            self.assertEqual(self.remote_tag, self.commit)
            self.assertIsNone(self.remote_release)
            self.remote_release = {"id": 42, "tag_name": "v4.0.1", "draft": True, "prerelease": False,
                                   "target_commitish": args[args.index("--target") + 1],
                                   "body": Path(args[args.index("--notes-file") + 1]).read_text()}
            return
        if args[:3] == ("gh", "release", "upload"):
            self.assertTrue(self.remote_release["draft"])
            self.assertNotIn("--clobber", args)
            path = Path(args[4])
            self.assertNotIn(path.name, self.assets)
            self.assets[path.name] = {"name": path.name, "id": len(self.assets) + 1, "state": "uploaded",
                                      "size": path.stat().st_size, "data": path.read_bytes(),
                                      "digest": "sha256:" + release.digest(path) if self.use_asset_digests else None}
            return
        if args[:3] == ("gh", "release", "edit"):
            self.assertTrue(self.remote_release["draft"])
            self.assertIn("--draft=false", args)
            self.assertIn("--latest", args)
            self.assertIn("--verify-tag", args)
            self.assertEqual(set(self.assets), {path.name for path in release.artifact_paths(self.directory, "4.0.1")})
            self.remote_release["draft"] = False
            self.latest = "v4.0.1"
            return
        if args[:4] == ("gh", "api", "--method", "DELETE"):
            self.assertTrue(self.remote_release["draft"])
            identifier = int(args[-1].rsplit("/", 1)[1])
            name = next(name for name, asset in self.assets.items() if asset["id"] == identifier)
            self.assertEqual(self.assets[name]["state"], "starter")
            del self.assets[name]
            return
        if args[:3] == ("gh", "release", "download"):
            name = args[args.index("--pattern") + 1]
            destination = Path(args[args.index("--dir") + 1]) / name
            data = self.previous_feed if args[3] == "v4.0.0" else self.assets[name]["data"]
            destination.write_bytes(data)
            return
        if args[0] == "git":
            return self.actual_run(*args, capture=capture)
        if args[0] == "security":
            return '1) fixture "Developer ID Application: Fixture (TEAM)"\n1 valid identities found'
        if args[0] == "codesign":
            binary = Path(args[-1])
            if "--verify" in args:
                self.assertTrue(binary.is_dir())
                return
            self.assertTrue(binary.is_file())
            arch = args[args.index("--arch") + 1]
            override = self.signature_overrides.get((binary.name, arch), {})
            if "-dv" in args:
                flags = "0x10000(runtime)" if override.get("runtime", True) else "0x0(none)"
                return f"CodeDirectory v=20500 flags={flags}\nTeamIdentifier={override.get('team', self.signing_team)}"
            self.assertIn("--xml", args)
            entitlements = {}
            entitlements = override.get("entitlements", entitlements)
            return plistlib.dumps(entitlements).decode() if entitlements else ""
        if args[0] == "xcodebuild":
            if "-showBuildSettings" in args:
                self.assertEqual(args[args.index("-configuration") + 1], "Release")
                return json.dumps([{"target": "eucaly", "buildSettings": {"DEVELOPMENT_TEAM": self.signing_team}}])
            if "archive" in args:
                self.assertIn("ARCHS=arm64", args)
                self.assertIn("ONLY_ACTIVE_ARCH=NO", args)
                self.assertNotIn("CODE_SIGNING_ALLOWED=NO", args)
                self.assertFalse(any(arg.startswith("MARKETING_VERSION=") for arg in args))
                build = next(arg.split("=", 1)[1] for arg in args if arg.startswith("CURRENT_PROJECT_VERSION="))
                archive = Path(args[args.index("-archivePath") + 1])
                archive.mkdir(parents=True)
                (archive / "build-number").write_text(build)
                self.after_archive()
            elif "-exportArchive" in args:
                archive = Path(args[args.index("-archivePath") + 1])
                info = plistlib.loads((self.root / "eucaly/Info.plist").read_bytes())
                info.update(CFBundleShortVersionString="4.0.1", CFBundleVersion=(archive / "build-number").read_text(),
                            EucalySourceCommit=self.commit, CFBundleExecutable="eucaly",
                            CFBundleIdentifier="com.suku.eucaly")
                app = Path(args[args.index("-exportPath") + 1]) / "eucaly.app/Contents"
                app.mkdir(parents=True)
                (app / "Info.plist").write_bytes(plistlib.dumps(info))
                (app / "MacOS").mkdir()
                (app / "MacOS/eucaly").write_bytes(b"fixture executable")
                framework = app / "Frameworks/Sparkle.framework"
                for name in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
                             "XPCServices/Installer.xpc/Contents/MacOS/Installer",
                             "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"):
                    binary = framework / name
                    if binary.name != self.missing_binary:
                        binary.parent.mkdir(parents=True, exist_ok=True)
                        binary.write_bytes(b"fixture Sparkle executable")
                options = plistlib.loads(Path(args[args.index("-exportOptionsPlist") + 1]).read_bytes())
                self.assertEqual(options["method"], "developer-id")
            return
        if args[0].endswith("generate_keys"):
            return plistlib.loads((self.root / "eucaly/Info.plist").read_bytes())["SUPublicEDKey"]
        if args[0].endswith("sign_update"):
            return
        if args[0] == "lipo":
            if args[-1] == "-archs":
                self.assertEqual(Path(args[1]).name, "eucaly")
                return self.main_architectures
            self.assertEqual(args[-2:], ("-verify_arch", "arm64"))
            if Path(args[1]).name == self.missing_arm_binary:
                raise subprocess.CalledProcessError(1, args)
            return
        if args[0] == "ditto":
            if "-k" in args:
                Path(args[-1]).write_bytes(release.digest(Path(args[-2])).encode())
            else:
                shutil.copytree(args[-2], args[-1])
            return
        if args[:2] == ("xcrun", "notarytool"):
            self.assertEqual(args[args.index("--keychain-profile") + 1], "eucalyNotary")
            if args[2] == "history":
                return '{"history": []}'
            if args[2] == "submit":
                self.assertNotIn("--wait", args)
                self.assertIn("--no-wait", args)
                identifier = str(uuid.UUID(int=len(self.submissions) + 1))
                self.submissions[identifier] = release.digest(Path(args[3]))
                return json.dumps({"id": identifier})
            identifier = args[3]
            if args[2] == "wait":
                self.assertIn(identifier, self.submissions)
                self.finished_submissions.add(identifier)
                return json.dumps({"id": identifier, "status": self.notary_status})
            if args[2] == "info":
                self.assertIn(identifier, self.submissions)
                status = self.notary_status if identifier in self.finished_submissions else "In Progress"
                return json.dumps({"id": identifier, "status": status})
            if args[2] == "log":
                return json.dumps({"jobId": identifier, "status": self.notary_status,
                                   "sha256": self.notary_hash_transform(self.submissions[identifier])})
            self.fail(f"Unexpected notarization command: {args}")
        if args[:2] == ("xcrun", "stapler"):
            if args[2] == "staple":
                (Path(args[3]) / "Contents/ticket").write_text("fixture ticket")
            else:
                self.assertTrue((Path(args[3]) / "Contents/ticket").is_file())
            return
        if len(args) > 1 and args[1].endswith("update-feed.py"):
            if self.fail_feed:
                raise subprocess.CalledProcessError(1, args)
            Path(args[args.index("--output") + 1]).write_text("signed fixture feed")
            return
        self.fail(f"Unexpected command: {args}")

    def invoke(self, **options):
        args = dict(notary_profile="eucalyNotary", notes=None, check=False, no_publish=False,
                    publish_only=False, resume_notarization=None)
        args.update(options)
        release.release(argparse.Namespace(**args))

    def assert_not_published(self):
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertIsNone(self.remote_tag)
        self.assertFalse(self.existing_release)

    def test_source_checks_reject_dirty_untracked_and_changed_commits_without_requiring_a_tag(self):
        self.assertEqual(release.source_commit(), self.commit)
        self.assertEqual(release.source_commit(self.commit), self.commit)
        path = self.root / "VERSION"
        path.write_text("4.0.2\n")
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke(check=True)
        path.write_text("4.0.1\n")
        stray = self.root / "untracked.txt"
        stray.write_text("untracked")
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke(check=True)
        stray.unlink()
        path.write_text("4.0.2\n")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "newer")
        with self.assertRaisesRegex(release.ReleaseError, "HEAD changed"):
            release.source_commit(self.commit)
        self.assertFalse(any(call[0] in ("gh", "xcodebuild") for call in self.calls))
        self.assert_not_published()

    def test_release_preflight_accepts_eucaly_two_part_versions(self):
        (self.root / "VERSION").write_text("1.33\n")
        self.git("add", "VERSION")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "version")
        self.commit = self.git("rev-parse", "HEAD")
        self.ci_sha = self.commit
        self.invoke(check=True)
        self.assertIn("Release source ready: v1.33", self.output.getvalue())
        self.assertEqual(self.archive_count(), 0)
        self.assert_not_published()

    def test_complete_flow_validates_then_builds_locally_then_tags_and_publishes(self):
        self.invoke()
        positions = {}
        for index, call in enumerate(self.calls):
            if call[:3] == ("gh", "run", "list"):
                positions.setdefault("ci", index)
            if call[0] == "xcodebuild" and "archive" in call:
                positions["archive"] = index
            for label, prefix in (("notary", ("xcrun", "notarytool", "submit")),
                                  ("staple", ("xcrun", "stapler", "validate")),
                                  ("tag", ("git", "tag")), ("push", ("git", "push")),
                                  ("draft", ("gh", "release", "create")),
                                  ("publish", ("gh", "release", "edit"))):
                if call[:len(prefix)] == prefix:
                    positions[label] = index
            if len(call) > 1 and call[1].endswith("update-feed.py"):
                positions["feed"] = index
        self.assertEqual(list(positions), ["ci", "archive", "notary", "staple", "feed", "tag", "push", "draft", "publish"])
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual((self.root / "VERSION").read_text(), "4.0.1\n")
        self.assertEqual(self.git("rev-parse", "v4.0.1^{commit}"), self.commit)

    def test_failed_ci_never_starts_signing_or_creates_a_tag(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped", "neutral", None):
            with self.subTest(conclusion=conclusion):
                self.conclusions = [conclusion]
                with self.assertRaises(release.ReleaseError):
                    self.invoke()
                self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))
                self.assert_not_published()

    def test_unpushed_missing_and_wrong_commit_validation_are_rejected(self):
        for kind in ("unpushed", "missing_run", "wrong_commit"):
            with self.subTest(kind=kind):
                self.pushed = kind != "unpushed"
                self.missing_runs = 13 if kind == "missing_run" else 0
                self.ci_sha = "0" * 40 if kind == "wrong_commit" else self.commit
                with self.assertRaises(release.ReleaseError):
                    self.invoke()
                self.assert_not_published()

    def test_newly_pushed_and_running_validation_is_awaited(self):
        self.missing_runs = 1
        self.ci_status = "in_progress"
        self.invoke(check=True)
        self.assertTrue(any(call[:3] == ("gh", "run", "view") for call in self.calls))
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))
        self.assert_not_published()

    def test_pr_feature_branch_and_tag_runs_cannot_authorize_release(self):
        for event, branch in (("pull_request", "feature"), ("push", "feature"), ("push", "v4.0.1")):
            with self.subTest(event=event, branch=branch):
                self.ci_event, self.ci_branch = event, branch
                with self.assertRaisesRegex(release.ReleaseError, "main push run"):
                    self.invoke()
                self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))
                self.assert_not_published()

    def test_ci_failure_on_final_recheck_preserves_artifacts_and_does_not_tag(self):
        self.conclusions = ["success", "failure"]
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assertTrue((self.root / "build/release/v4.0.1/appcast.xml").exists())
        self.assert_not_published()

    def test_notary_failure_does_not_tag_or_publish(self):
        self.notary_status = "Invalid"
        with self.assertRaisesRegex(release.ReleaseError, "not accepted"):
            self.invoke()
        self.assertTrue((self.directory / "work/notary-log.json").is_file())
        self.assert_not_published()

    def test_feed_failure_does_not_tag_or_publish(self):
        self.fail_feed = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assert_not_published()

    def test_source_edit_during_build_does_not_notarize_or_tag(self):
        self.after_archive = lambda: (self.root / "VERSION").write_text("4.0.2\n")
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke()
        self.assertFalse(any(call[:3] == ("xcrun", "notarytool", "submit") for call in self.calls))
        self.assert_not_published()

    def test_existing_release_and_moved_remote_tag_are_rejected_before_build(self):
        self.existing_release = True
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.existing_release = False
        self.remote_tag = "0" * 40
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))

    def test_existing_matching_tags_are_reused_without_pushing(self):
        self.git("tag", "v4.0.1")
        self.remote_tag = self.commit
        self.invoke()
        self.assertFalse(any(call[:2] in (("git", "tag"), ("git", "push")) for call in self.calls))
        self.assertTrue(self.existing_release)

    def test_tag_lookup_failure_after_push_resumes_prepared_release(self):
        def request(repo, path, optional=False, expected_type=dict):
            if path == "git/tags/release-tag-sha":
                raise release.ReleaseError("GitHub request failed after the tag was pushed (HTTP 503).")
            return self.api(repo, path, optional=optional, expected_type=expected_type)

        with patch.object(release, "github", side_effect=request):
            with self.assertRaisesRegex(release.ReleaseError, "after the tag was pushed"):
                self.invoke()
        self.assertEqual(self.remote_tag, self.commit)
        self.assertIsNone(self.remote_release)
        prepared = self.state["artifacts"]
        submission = self.state["notary_id"]
        self.calls.clear()
        self.invoke(publish_only=True)
        self.assertEqual(self.state["artifacts"], prepared)
        self.assertEqual(self.state["notary_id"], submission)
        self.assertFalse(self.remote_release["draft"])
        self.assertFalse(any(call[0] in ("xcodebuild", "xcrun", "codesign", "security", "ditto") for call in self.calls))
        self.assertFalse(any(call[:2] in (("git", "tag"), ("git", "push")) for call in self.calls))

    def test_new_draft_visibility_delay_does_not_repeat_creation(self):
        self.hidden_draft_reads = 3
        self.invoke()
        self.assertEqual(self.count("gh", "release", "create"), 1)
        self.assertEqual(self.hidden_draft_reads, 0)
        self.assertFalse(self.remote_release["draft"])

    def test_draft_visibility_timeout_preserves_work_for_retry(self):
        self.hidden_draft_reads = 5
        with self.assertRaisesRegex(release.ReleaseError, "not visible yet"):
            self.invoke()
        self.assertTrue(self.remote_release["draft"])
        self.assertEqual(self.count("gh", "release", "upload"), 0)
        prepared = self.state["artifacts"]
        self.invoke(publish_only=True)
        self.assertEqual(self.count("gh", "release", "create"), 1)
        self.assertEqual(self.state["artifacts"], prepared)
        self.assertFalse(self.remote_release["draft"])

    def test_changed_latest_release_stops_before_tagging(self):
        self.latest_changed = True
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assert_not_published()

    def test_local_artifact_mode_does_not_tag_or_publish(self):
        self.invoke(no_publish=True)
        self.assertTrue((self.root / "build/release/v4.0.1/appcast.xml").exists())
        self.assert_not_published()

    def test_release_cannot_run_in_ci(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            with self.assertRaisesRegex(release.ReleaseError, "on your Mac"):
                self.invoke()
        self.assertEqual(self.calls, [])

    def test_unsupported_push_destinations_are_rejected(self):
        for origin in ("https://example.invalid/repo.git", "https://github.com/elsewhere/app.git",
                       "git@github.com:sukujgrg/eucaly.git", "ssh://git@github.com/sukujgrg/eucaly.git",
                       "http://github.com/sukujgrg/eucaly.git"):
            self.git("remote", "set-url", "origin", origin)
            with self.assertRaises(release.ReleaseError):
                self.invoke()
        self.assert_not_published()

    def test_https_remotes_with_or_without_git_suffix_are_supported(self):
        for origin in ("https://github.com/sukujgrg/eucaly", "https://github.com/sukujgrg/eucaly.git"):
            with self.subTest(origin=origin):
                self.git("remote", "set-url", "origin", origin)
                self.invoke(check=True)
                self.assertEqual(release.release_repository(), ("sukujgrg/eucaly", origin))
        self.assertEqual(self.archive_count(), 0)

    def test_push_url_must_be_one_https_url_even_when_fetch_url_is_valid(self):
        self.git("config", "remote.origin.pushurl", "git@github.com:sukujgrg/eucaly.git")
        with self.assertRaisesRegex(release.ReleaseError, "one HTTPS GitHub push URL"):
            self.invoke(check=True)
        self.git("config", "remote.origin.pushurl", "https://github.com/sukujgrg/eucaly.git")
        self.git("config", "--add", "remote.origin.pushurl", "https://github.com/sukujgrg/eucaly")
        with self.assertRaisesRegex(release.ReleaseError, "one HTTPS GitHub push URL"):
            self.invoke(check=True)
        self.assertEqual(self.archive_count(), 0)

    def test_resume_keeps_the_exact_https_push_url(self):
        self.invoke(no_publish=True)
        original = self.state
        self.git("remote", "set-url", "origin", "https://github.com/sukujgrg/eucaly")
        with self.assertRaisesRegex(release.ReleaseError, "Cannot reuse"):
            self.invoke(publish_only=True)
        self.assertEqual(self.state, original)
        self.assert_not_published()
        self.git("remote", "set-url", "origin", original["origin"])
        self.invoke(publish_only=True)
        self.assertEqual(self.archive_count(), 1)

    def count(self, *prefix):
        return sum(call[:len(prefix)] == prefix for call in self.calls)

    def archive_count(self):
        return sum(call[0] == "xcodebuild" and "archive" in call for call in self.calls)

    def fail_once(self, stage, phase="before", occurrence=1):
        self.failures[(stage, phase)] = occurrence

    def test_export_failure_reuses_the_completed_archive(self):
        self.fail_once("export")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        build = self.state["build"]
        self.invoke()
        self.assertEqual(self.archive_count(), 1)
        self.assertEqual(self.state["build"], build)
        self.assertFalse(self.remote_release["draft"])

    def test_notarization_wait_failure_resumes_the_same_submission_and_app(self):
        self.fail_once("wait")
        with self.assertRaisesRegex(release.ReleaseError, "still processing"):
            self.invoke()
        identifier = self.state["notary_id"]
        archive_hash = self.state["notary_zip_hash"]
        self.invoke()
        self.assertEqual(self.state["notary_id"], identifier)
        self.assertEqual(self.state["notary_zip_hash"], archive_hash)
        self.assertEqual(self.archive_count(), 1)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)

    def test_lost_submission_acknowledgement_recovers_id_from_saved_stdout(self):
        self.fail_once("submit", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertNotIn("notary_id", self.state)
        self.invoke()
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assertEqual(self.archive_count(), 1)

    def test_unknown_submission_outcome_stops_instead_of_uploading_again(self):
        self.fail_once("submit", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        (self.directory / "work/notary-submission.json").write_text("incomplete response")
        with self.assertRaisesRegex(release.ReleaseError, "outcome is unknown"):
            self.invoke()
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assert_not_published()
        self.invoke(resume_notarization=next(iter(self.submissions)))
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)

    def test_manual_submission_recovery_checks_apple_archive_hash_before_adopting_id(self):
        self.fail_once("submit", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        (self.directory / "work/notary-submission.json").unlink()
        correct_id = next(iter(self.submissions))
        wrong_id = str(uuid.UUID(int=999))
        self.submissions[wrong_id] = "different archive"
        with self.assertRaisesRegex(release.ReleaseError, "does not match the saved archive"):
            self.invoke(resume_notarization=wrong_id)
        self.assertNotIn("notary_id", self.state)
        self.assertEqual(self.count("xcrun", "stapler", "staple"), 0)
        self.assert_not_published()
        self.invoke(resume_notarization=correct_id)
        self.assertEqual(self.state["notary_id"], correct_id)

    def test_manual_submission_recovery_accepts_uppercase_sha256(self):
        self.fail_once("submit", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        (self.directory / "work/notary-submission.json").unlink()
        self.notary_hash_transform = str.upper
        identifier = next(iter(self.submissions))
        self.invoke(resume_notarization=identifier)
        self.assertEqual(self.state["notary_id"], identifier)
        self.assertTrue(self.state["notarized"])
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)

    def test_missing_malformed_and_different_apple_hashes_still_reject_recovery(self):
        for value in (None, [], 42, "", "0" * 64, "A" * 63 + "G"):
            with self.subTest(hash=value):
                self.notary_hash_transform = lambda recorded: value
                with self.assertRaisesRegex(release.ReleaseError, "does not match the saved archive"):
                    self.invoke(no_publish=True)
        self.assertEqual(self.count("xcrun", "stapler", "staple"), 0)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assert_not_published()

    def test_git_tag_signing_failure_preserves_prepared_artifacts_and_the_signing_preference(self):
        self.git("config", "tag.gpgsign", "true")
        self.git("config", "gpg.format", "openpgp")
        self.git("config", "gpg.program", "/usr/bin/false")
        self.git("config", "user.signingkey", "fixture-unavailable-key")
        for options in ({}, {"publish_only": True}):
            with self.assertRaises(subprocess.CalledProcessError):
                self.invoke(**options)
            release.verify_artifacts(self.directory, self.state)
            self.assertEqual(self.git("config", "--bool", "tag.gpgsign"), "true")
            self.assert_not_published()
        self.assertEqual(self.archive_count(), 1)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)

    def test_stapler_failure_preserves_original_app_and_does_not_resubmit(self):
        self.fail_once("staple", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        original = self.directory / "work/export/eucaly.app"
        self.assertEqual(release.digest(original), self.state["export_hash"])
        self.invoke()
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assertEqual(self.count("xcrun", "notarytool", "wait"), 1)
        self.assertEqual(self.archive_count(), 1)

    def test_feed_failure_reuses_signed_app_and_zip(self):
        self.fail_once("feed")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        saved_zip = self.state["zip_hash"]
        self.invoke()
        self.assertEqual(self.state["zip_hash"], saved_zip)
        self.assertEqual(self.archive_count(), 1)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assertEqual(self.count("xcrun", "stapler", "staple"), 1)

    def test_upload_failure_resumes_only_missing_assets_without_rebuilding(self):
        self.fail_once("upload", occurrence=2)
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertTrue(self.remote_release["draft"])
        self.assertIsNone(self.latest)
        saved = dict(self.state["artifacts"])
        self.invoke()
        self.assertEqual(self.state["artifacts"], saved)
        self.assertEqual(self.archive_count(), 1)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assertEqual(self.count("gh", "release", "create"), 1)
        self.assertEqual(self.count("gh", "release", "upload"), 5)  # 4 successes + 1 failed attempt
        self.assertFalse(self.remote_release["draft"])

    def test_lost_draft_creation_acknowledgement_reuses_our_draft(self):
        self.fail_once("create", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertNotIn("release_id", self.state)
        self.assertTrue(self.remote_release["draft"])
        self.invoke(publish_only=True)
        self.assertEqual(self.count("gh", "release", "create"), 1)

    def test_draft_source_is_checked_using_the_tag_not_target_commitish_hint(self):
        self.fail_once("create", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.remote_release["target_commitish"] = "main"
        self.invoke(publish_only=True)
        self.assertEqual(self.remote_tag, self.commit)
        self.assertFalse(self.remote_release["draft"])

    def test_lost_upload_acknowledgement_does_not_upload_the_asset_twice(self):
        self.fail_once("upload", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.invoke(publish_only=True)
        self.assertEqual(self.count("gh", "release", "upload"), 4)

    def test_empty_starter_asset_is_recovered_only_on_our_draft(self):
        self.fail_once("upload")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        name = release.artifact_paths(self.directory, "4.0.1")[0].name
        self.assets[name] = {"name": name, "id": 100, "state": "starter", "size": 0, "digest": None}
        self.invoke(publish_only=True)
        self.assertEqual(self.count("gh", "api", "--method", "DELETE"), 1)
        self.assertFalse(self.remote_release["draft"])

    def test_conflicting_uploaded_asset_is_never_clobbered(self):
        self.fail_once("upload", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        asset = next(iter(self.assets.values()))
        asset["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(release.ReleaseError, "differs from the prepared file"):
            self.invoke(publish_only=True)
        self.assertEqual(self.count("gh", "api", "--method", "DELETE"), 0)
        self.assertEqual(self.count("gh", "release", "edit"), 0)
        self.assertTrue(self.remote_release["draft"])

    def test_missing_remote_digest_falls_back_to_comparing_downloaded_bytes(self):
        self.use_asset_digests = False
        self.fail_once("upload", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.invoke(publish_only=True)
        self.assertGreater(self.count("gh", "release", "download"), 0)
        self.assertEqual(self.count("gh", "release", "upload"), 4)

    def test_lost_publication_acknowledgement_recognizes_completed_release_without_writes(self):
        self.fail_once("edit", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertFalse(self.remote_release["draft"])
        # A newer release may have appeared since ours finished. Recognizing
        # completion must not promote this older release back to latest.
        self.latest = "v4.0.2"
        self.invoke()
        self.assertEqual(self.count("gh", "release", "edit"), 1)
        self.assertEqual(self.count("gh", "release", "create"), 1)
        self.assertEqual(self.archive_count(), 1)
        self.assertEqual(self.latest, "v4.0.2")

    def test_published_release_with_missing_assets_is_not_repaired_or_overwritten(self):
        self.invoke()
        del self.assets["appcast.xml"]
        with self.assertRaisesRegex(release.ReleaseError, "missing prepared artifacts"):
            self.invoke(publish_only=True)
        self.assertEqual(self.count("gh", "release", "upload"), 4)
        self.assertEqual(self.count("gh", "release", "edit"), 1)

    def test_publish_only_has_no_build_signing_or_apple_calls(self):
        self.invoke(no_publish=True)
        # Once preparation finishes only the state and final files are needed.
        shutil.rmtree(self.directory / "work")
        self.calls.clear()
        self.invoke(publish_only=True)
        self.assertFalse(any(call[0] in ("xcodebuild", "codesign", "security", "ditto", "xcrun") for call in self.calls))
        self.assertFalse(self.remote_release["draft"])

    def test_publish_only_requires_a_complete_saved_preparation(self):
        with self.assertRaisesRegex(release.ReleaseError, "No saved preparation"):
            self.invoke(publish_only=True)
        self.fail_once("wait")
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        with self.assertRaisesRegex(release.ReleaseError, "No complete prepared release"):
            self.invoke(publish_only=True)
        self.assert_not_published()

    def test_modified_prepared_file_stops_before_tagging_or_uploading(self):
        self.invoke(no_publish=True)
        (self.directory / "appcast.xml").write_text("modified feed")
        with self.assertRaisesRegex(release.ReleaseError, "Prepared release file changed"):
            self.invoke()
        self.assert_not_published()

    def test_modified_exported_app_cannot_resume_notarization(self):
        self.fail_once("wait")
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        binary = self.directory / "work/export/eucaly.app/Contents/MacOS/eucaly"
        binary.write_text("different executable")
        with self.assertRaisesRegex(release.ReleaseError, "Saved artifact changed"):
            self.invoke()
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assert_not_published()

    def test_new_commit_with_same_version_requires_fresh_preparation(self):
        self.invoke(no_publish=True)
        original_commit = self.commit
        self.git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "--quiet", "-m", "new source")
        self.commit = self.git("rev-parse", "HEAD")
        self.ci_sha = self.commit
        with self.assertRaisesRegex(release.ReleaseError, "Cannot reuse.*source"):
            self.invoke()
        self.assertEqual(self.archive_count(), 1)
        self.assert_not_published()
        # Returning to the recorded source can still finish the pending release.
        self.git("checkout", "--quiet", original_commit)
        self.commit = self.ci_sha = original_commit
        self.invoke(publish_only=True)
        self.assertFalse(self.remote_release["draft"])

    def test_new_source_can_keep_unreleased_version_after_old_preparation_is_moved_aside(self):
        self.invoke(no_publish=True)
        original = self.state
        self.git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "--quiet", "-m", "new source")
        self.commit = self.ci_sha = self.git("rev-parse", "HEAD")
        backup = self.directory.with_name("v4.0.1-unfinished")
        self.directory.rename(backup)
        self.invoke()
        self.assertEqual(self.state["commit"], self.commit)
        self.assertNotEqual(self.state["commit"], original["commit"])
        self.assertEqual(self.state["version"], original["version"])
        self.assertTrue((backup / "state.json").exists())
        self.assertEqual(self.archive_count(), 2)

    def external_notes(self):
        directory = tempfile.TemporaryDirectory(prefix="eucaly notes ")
        self.addCleanup(directory.cleanup)
        notes = Path(directory.name) / "release notes.md"
        notes.write_text("Release notes with `code` and $literal text.\n")
        return notes

    def test_snapshot_of_release_notes_survives_retry_without_notes_argument(self):
        notes = self.external_notes()
        self.fail_once("create", "after")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke(notes=notes)
        saved = self.remote_release["body"]
        notes.write_text("Changed notes")
        with self.assertRaisesRegex(release.ReleaseError, "notes differ"):
            self.invoke(publish_only=True, notes=notes)
        self.invoke(publish_only=True)
        self.assertEqual(self.remote_release["body"], saved)

    def test_external_notes_are_read_before_preparation(self):
        notes = self.external_notes()
        text = notes.read_text()
        self.after_archive = notes.unlink
        self.invoke(notes=notes)
        self.assertEqual(self.state["notes"], text)
        self.assertTrue(self.remote_release["body"].startswith(text))

    def test_notes_inside_checkout_are_rejected_before_the_dirty_check_or_build(self):
        for notes in (self.root / "release-notes.md", self.root / "build/notes.md", self.root / "VERSION"):
            with self.subTest(notes=notes):
                notes.parent.mkdir(parents=True, exist_ok=True)
                if not notes.exists():
                    notes.write_text("Local notes")
                with self.assertRaisesRegex(release.ReleaseError, "Keep release notes outside the checkout"):
                    self.invoke(notes=notes)
        self.assertEqual(self.calls, [])
        self.assert_not_published()

    def test_external_symlink_cannot_point_to_notes_inside_checkout(self):
        notes = self.external_notes()
        notes.unlink()
        notes.symlink_to(self.root / "VERSION")
        with self.assertRaisesRegex(release.ReleaseError, "outside the checkout"):
            self.invoke(notes=notes)
        self.assertEqual(self.calls, [])

    def test_missing_external_notes_are_rejected_before_build_work(self):
        notes = self.external_notes()
        notes.unlink()
        with self.assertRaisesRegex(release.ReleaseError, "Release notes file does not exist"):
            self.invoke(notes=notes)
        self.assertEqual(self.calls, [])

    def test_finder_metadata_outside_saved_packages_does_not_invalidate_recovery(self):
        self.fail_once("wait")
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        for directory in (self.root / "build/release", self.directory, self.directory / "work"):
            (directory / ".DS_Store").write_bytes(b"Finder folder view")
        self.invoke()
        self.assertEqual(self.archive_count(), 1)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)

    def test_finder_metadata_inside_saved_app_is_still_a_checkpoint_change(self):
        self.fail_once("wait")
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        app = self.directory / "work/export/eucaly.app"
        (app / "Contents/.DS_Store").write_bytes(b"Finder package view")
        with self.assertRaisesRegex(release.ReleaseError, "Saved artifact changed"):
            self.invoke()
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assert_not_published()

    def test_read_only_check_does_not_create_recovery_files_or_access_apple(self):
        self.invoke(check=True)
        self.assertFalse((self.root / "build").exists())
        self.assertFalse(any(call[0] in ("xcodebuild", "codesign", "security", "xcrun") for call in self.calls))

    def test_source_edit_during_upload_leaves_draft_unpublished(self):
        self.hooks[("upload", "after")] = lambda: (self.root / "VERSION").write_text("4.0.2\n")
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke()
        self.assertTrue(self.remote_release["draft"])
        self.assertEqual(self.count("gh", "release", "edit"), 0)

    def test_latest_release_change_during_upload_leaves_draft_unpublished(self):
        self.hooks[("upload", "after")] = lambda: setattr(self, "latest", "v4.0.2")
        with self.assertRaisesRegex(release.ReleaseError, "latest release changed"):
            self.invoke()
        self.assertTrue(self.remote_release["draft"])
        self.assertEqual(self.count("gh", "release", "edit"), 0)

    def test_ci_failure_after_upload_leaves_draft_unpublished(self):
        self.conclusions = ["success", "success", "failure"]
        with self.assertRaisesRegex(release.ReleaseError, "Validate did not pass"):
            self.invoke()
        self.assertTrue(self.remote_release["draft"])
        self.assertEqual(self.count("gh", "release", "edit"), 0)

    def test_source_changed_during_final_ci_check_leaves_draft_unpublished(self):
        def edit_after_final_ci():
            if self.count("gh", "run", "list") == 3:
                (self.root / "VERSION").write_text("4.0.2\n")
        self.hooks[("list", "after")] = edit_after_final_ci
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke()
        self.assertTrue(self.remote_release["draft"])
        self.assertEqual(self.count("gh", "release", "edit"), 0)

    def test_source_changed_during_publication_preflight_does_not_create_tag(self):
        def edit_after_publication_ci():
            if self.count("gh", "run", "list") == 2:
                (self.root / "VERSION").write_text("4.0.2\n")
        self.hooks[("list", "after")] = edit_after_publication_ci
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke()
        self.assert_not_published()

    def test_artifact_changed_during_final_ci_check_leaves_draft_unpublished(self):
        def edit_after_final_ci():
            if self.count("gh", "run", "list") == 3:
                (self.directory / "appcast.xml").write_text("changed feed")
        self.hooks[("list", "after")] = edit_after_final_ci
        with self.assertRaisesRegex(release.ReleaseError, "differs from the prepared file|Prepared release file changed"):
            self.invoke()
        self.assertTrue(self.remote_release["draft"])
        self.assertEqual(self.count("gh", "release", "edit"), 0)

    def test_moved_remote_tag_after_upload_is_not_repaired(self):
        self.hooks[("upload", "after")] = lambda: setattr(self, "remote_tag", "0" * 40)
        with self.assertRaisesRegex(release.ReleaseError, "points to another commit"):
            self.invoke()
        self.assertTrue(self.remote_release["draft"])
        self.assertEqual(self.count("gh", "release", "edit"), 0)

    def test_unrelated_draft_is_rejected_even_with_prepared_local_artifacts(self):
        self.invoke(no_publish=True)
        self.existing_release = True
        self.remote_release["draft"] = True
        with self.assertRaisesRegex(release.ReleaseError, "does not belong"):
            self.invoke()
        self.assertEqual(self.count("gh", "release", "upload"), 0)
        self.assertEqual(self.count("git", "tag"), 0)

    def test_unrecorded_artifacts_are_preserved(self):
        self.directory.mkdir(parents=True)
        previous = self.directory / "eucaly-4.0.1-notarized.zip"
        previous.write_bytes(b"legacy artifact")
        with self.assertRaisesRegex(release.ReleaseError, "Unrecorded artifacts"):
            self.invoke()
        self.assertEqual(previous.read_bytes(), b"legacy artifact")
        self.assertEqual(self.archive_count(), 0)

    def test_invalid_state_is_preserved_and_not_silently_restarted(self):
        self.invoke(no_publish=True)
        state = self.directory / "state.json"
        state.write_text("broken JSON")
        with self.assertRaisesRegex(release.ReleaseError, "Cannot reuse"):
            self.invoke()
        self.assertEqual(state.read_text(), "broken JSON")
        self.assertEqual(self.archive_count(), 1)

    def test_concurrent_release_command_is_rejected(self):
        with release.release_lock():
            with self.assertRaisesRegex(release.ReleaseError, "Another local release"):
                self.invoke()
        self.assertEqual(self.archive_count(), 0)
        self.assert_not_published()

    def test_bad_notary_profile_is_detected_before_archiving(self):
        self.fail_once("history")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertEqual(self.archive_count(), 0)
        self.assert_not_published()

    def test_signing_team_must_be_configured_before_archiving(self):
        self.signing_team = ""
        with self.assertRaisesRegex(release.ReleaseError, "DEVELOPMENT_TEAM"):
            self.invoke(no_publish=True)
        self.assertEqual(self.archive_count(), 0)

    def test_every_shipped_binary_must_support_arm64(self):
        for name in ("eucaly", "Sparkle", "Autoupdate", "Updater", "Installer", "Downloader"):
            with self.subTest(binary=name):
                self.missing_arm_binary = name
                with self.assertRaises(subprocess.CalledProcessError):
                    self.invoke(no_publish=True)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 0)
        self.assert_not_published()

    def test_main_executable_must_be_arm64_only(self):
        for architectures in ("x86_64", "x86_64 arm64"):
            with self.subTest(architectures=architectures):
                self.main_architectures = architectures
                with self.assertRaisesRegex(release.ReleaseError, "arm64 only"):
                    self.invoke(no_publish=True)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 0)
        self.assert_not_published()

    def test_missing_sparkle_binaries_are_rejected_before_notarization(self):
        for name in ("Sparkle", "Autoupdate", "Updater", "Installer", "Downloader"):
            with self.subTest(binary=name):
                self.missing_binary = name
                with self.assertRaisesRegex(release.ReleaseError, "Required executable is missing"):
                    self.invoke(no_publish=True)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 0)

    def test_wrong_team_in_helper_is_rejected(self):
        self.signature_overrides[("Installer", "arm64")] = {"team": "OTHERTEAM"}
        with self.assertRaisesRegex(release.ReleaseError, "Signing team differs"):
            self.invoke(no_publish=True)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 0)

    def test_missing_hardened_runtime_in_helper_is_rejected(self):
        self.signature_overrides[("Autoupdate", "arm64")] = {"runtime": False}
        with self.assertRaisesRegex(release.ReleaseError, "Hardened runtime is missing"):
            self.invoke(no_publish=True)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 0)

    def test_debuggable_helper_is_rejected(self):
        self.signature_overrides[("Updater", "arm64")] = {"entitlements": {"com.apple.security.get-task-allow": True}}
        with self.assertRaisesRegex(release.ReleaseError, "Debugging entitlement"):
            self.invoke(no_publish=True)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 0)

    def test_sandbox_must_not_be_enabled(self):
        self.signature_overrides[("eucaly", "arm64")] = {
            "entitlements": {"com.apple.security.app-sandbox": True}}
        with self.assertRaisesRegex(release.ReleaseError, "unsandboxed file access"):
            self.invoke(no_publish=True)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 0)

    def make_clean(self):
        scripts = self.root / "scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copy2(ROOT / "scripts/release.py", scripts / "release.py")
        shutil.copy2(ROOT / "Makefile", self.root / "Makefile")
        return subprocess.run(["make", "clean"], cwd=self.root, text=True, capture_output=True)

    def test_make_clean_preserves_saved_releases_and_does_not_follow_cache_symlinks(self):
        self.directory.mkdir(parents=True)
        saved = self.directory / "state.json"
        saved.write_bytes(b"saved recovery record")
        for name in ("DerivedData", "ReleaseDerivedData", "SwiftPM"):
            cache = self.root / "build" / name
            cache.mkdir()
            (cache / "artifact").write_bytes(b"disposable cache")
        external = self.root / "external"
        external.mkdir()
        (external / "keep").write_bytes(b"outside build")
        (self.root / "build/linked-cache").symlink_to(external, target_is_directory=True)
        result = self.make_clean()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(saved.read_bytes(), b"saved recovery record")
        self.assertEqual([p.name for p in (self.root / "build").iterdir()], ["release"])
        self.assertEqual((external / "keep").read_bytes(), b"outside build")

    def test_make_clean_refuses_while_another_process_holds_the_release_lock(self):
        cache = self.root / "build/keep"
        cache.parent.mkdir()
        cache.write_bytes(b"active build")
        with release.release_lock():
            result = self.make_clean()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another local release or cleanup", result.stderr)
        self.assertEqual(cache.read_bytes(), b"active build")

    def test_release_lock_survives_removal_of_build_directory(self):
        build = self.root / "build"
        build.mkdir()
        with release.release_lock():
            shutil.rmtree(build)
            build.mkdir()
            with self.assertRaisesRegex(release.ReleaseError, "Another local release"):
                with release.release_lock():
                    self.fail("The held lock must survive deletion of build/")

    def test_linked_worktrees_share_the_release_and_cleanup_lock(self):
        with tempfile.TemporaryDirectory(prefix="eucaly worktree ") as directory:
            worktree = Path(directory) / "checkout"
            self.git("worktree", "add", "--quiet", "--detach", str(worktree), self.commit)
            cache = worktree / "build/keep"
            cache.parent.mkdir()
            cache.write_bytes(b"active worktree build")
            with release.release_lock():
                with patch.object(release, "ROOT", worktree):
                    with self.assertRaisesRegex(release.ReleaseError, "Another local release"):
                        release.clean_build()
            self.assertEqual(cache.read_bytes(), b"active worktree build")

    def test_clean_refuses_a_symlink_as_the_build_directory(self):
        external = self.root / "external"
        external.mkdir()
        marker = external / "keep"
        marker.write_bytes(b"external files")
        (self.root / "build").symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(release.ReleaseError, "build directory that is a symlink"):
            release.clean_build()
        self.assertEqual(marker.read_bytes(), b"external files")

    def test_previous_release_without_appcast_stops_before_archiving(self):
        self.latest = "v4.0.0"
        self.previous_release = {"id": 10, "tag_name": "v4.0.0", "draft": False}
        with self.assertRaisesRegex(release.ReleaseError, "has no appcast.xml"):
            self.invoke(no_publish=True)
        self.assertNotIn("build", self.state)
        self.assertEqual(self.archive_count(), 0)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 0)
        self.assert_not_published()

    def test_known_legacy_release_bootstraps_first_feed_and_resumes(self):
        self.latest = release.LEGACY_RELEASE_TAG
        self.previous_release = {"id": release.LEGACY_RELEASE_ID, "tag_name": self.latest, "draft": False}
        self.fail_feed = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke(no_publish=True)
        self.assertTrue(self.state["legacy_feed_bootstrap"])
        self.assertNotIn("previous_hash", self.state)
        self.fail_feed = False
        self.invoke(no_publish=True)
        self.assertEqual(self.archive_count(), 1)
        self.assertEqual(self.count("xcrun", "notarytool", "submit"), 1)
        self.assertTrue((self.directory / "appcast.xml").exists())
        self.assert_not_published()

    def test_legacy_tag_with_different_release_identity_cannot_bootstrap(self):
        self.latest = release.LEGACY_RELEASE_TAG
        self.previous_release = {"id": 10, "tag_name": self.latest, "draft": False}
        with self.assertRaisesRegex(release.ReleaseError, "has no appcast.xml"):
            self.invoke(no_publish=True)
        self.assertEqual(self.archive_count(), 0)

    def test_previous_feed_is_verified_and_build_number_advances(self):
        self.latest = "v4.0.0"
        self.previous_release = {"id": 10, "tag_name": "v4.0.0", "draft": False}
        self.previous_feed = b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>99991231235960.2</sparkle:version></item></channel></rss>'
        self.invoke(no_publish=True)
        self.assertEqual(self.state["build"], "99991231235961")
        self.assertTrue(any(call[0].endswith("sign_update") and "--verify" in call for call in self.calls))



class GitHubTransportTests(unittest.TestCase):
    def test_malformed_success_responses_stop_with_a_recoverable_error(self):
        outputs = ["HTTP/2.0 200 OK\ncontent-type: application/json", "HTTP/2.0 200 OK\n\n"]
        outputs += ["HTTP/2.0 200 OK\n\n" + body for body in ("{", "not JSON", "null", "42", '"string"', "[]")]
        for output in outputs:
            with self.subTest(output=output):
                response = subprocess.CompletedProcess([], 0, output, "")
                with patch.object(release.subprocess, "run", return_value=response):
                    with self.assertRaisesRegex(release.ReleaseError, "malformed response.*completed work is retained"):
                        release.github("owner/repo", "releases/latest", optional=True)

    def test_crlf_headers_and_list_responses_are_supported(self):
        output = 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n[{"tag_name":"v4.0.1"}]'
        response = subprocess.CompletedProcess([], 0, output, "")
        with patch.object(release.subprocess, "run", return_value=response):
            self.assertEqual(list(release.github_pages("owner/repo", "releases")), [{"tag_name": "v4.0.1"}])

    def test_malformed_list_contents_are_rejected(self):
        for body in ("{}", "[null]", "[42]", '["v4.0.1"]'):
            with self.subTest(body=body):
                response = subprocess.CompletedProcess([], 0, "HTTP/2.0 200 OK\n\n" + body, "")
                with patch.object(release.subprocess, "run", return_value=response):
                    with self.assertRaises(release.ReleaseError):
                        list(release.github_pages("owner/repo", "releases"))

    def test_only_confirmed_404_is_treated_as_absent(self):
        for status, body, exit_code in ((200, '{"sha":"fixture"}', 0), (404, '{}', 1),
                                        (403, '{}', 1), (422, '{}', 1), (500, '{}', 1), (None, '', 1)):
            with self.subTest(status=status):
                output = f"HTTP/2.0 {status} status\ncontent-type: application/json\n\n{body}" if status else ""
                response = subprocess.CompletedProcess([], exit_code, output, "failure" if exit_code else "")
                with patch.object(release.subprocess, "run", return_value=response):
                    if status == 200:
                        self.assertEqual(release.github("owner/repo", "commits/main", optional=True), {"sha": "fixture"})
                    elif status == 404:
                        self.assertIsNone(release.github("owner/repo", "commits/main", optional=True))
                        with self.assertRaises(release.ReleaseError):
                            release.github("owner/repo", "commits/main")
                    else:
                        with self.assertRaises(release.ReleaseError):
                            release.github("owner/repo", "commits/main", optional=True)

    def test_missing_tag_uses_ref_lookup_without_resolving_a_commit(self):
        def request(args, **kwargs):
            path = args[-1]
            if path == "repos/owner/repo/git/ref/tags/v4.0.1":
                return subprocess.CompletedProcess(args, 1, 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}', "")
            self.fail(f"A missing tag must not reach the commit endpoint, which returns 422: {path}")

        with patch.object(release.subprocess, "run", side_effect=request) as transport:
            self.assertIsNone(release.remote_tag_commit("owner/repo", "v4.0.1"))
            self.assertEqual(transport.call_count, 1)

    def test_existing_lightweight_and_annotated_tags_resolve_to_the_commit(self):
        for kind, object_sha in (("commit", "commit-sha"), ("tag", "annotated-tag-sha")):
            with self.subTest(kind=kind):
                def request(args, **kwargs):
                    path = args[-1]
                    if path == "repos/owner/repo/git/ref/tags/v4.0.1":
                        data = {"object": {"type": kind, "sha": object_sha}}
                    elif path == "repos/owner/repo/git/tags/annotated-tag-sha":
                        self.assertEqual(kind, "tag")
                        data = {"object": {"type": "commit", "sha": "commit-sha"}}
                    elif path == "repos/owner/repo/commits/tags/v4.0.1":
                        return subprocess.CompletedProcess(args, 1,
                            'HTTP/2.0 422 Unprocessable Entity\n\n{"message":"No commit found for SHA: tags/v4.0.1"}', "")
                    else:
                        self.fail(f"Unexpected tag request: {path}")
                    return subprocess.CompletedProcess(args, 0, "HTTP/2.0 200 OK\n\n" + json.dumps(data), "")

                with patch.object(release.subprocess, "run", side_effect=request) as transport:
                    self.assertEqual(release.remote_tag_commit("owner/repo", "v4.0.1"), "commit-sha")
                    self.assertEqual(transport.call_count, 1 if kind == "commit" else 2)

    def test_nested_annotated_tags_resolve_to_the_commit(self):
        objects = {
            "git/ref/tags/v4.0.1": {"type": "tag", "sha": "outer-tag-sha"},
            "git/tags/outer-tag-sha": {"type": "tag", "sha": "inner-tag-sha"},
            "git/tags/inner-tag-sha": {"type": "commit", "sha": "commit-sha"},
        }
        with patch.object(release, "github", side_effect=lambda repo, path, **kw: {"object": objects[path]}):
            self.assertEqual(release.remote_tag_commit("owner/repo", "v4.0.1"), "commit-sha")

    def test_tags_pointing_to_non_commit_objects_are_rejected(self):
        for kind in ("tree", "blob"):
            with self.subTest(kind=kind):
                with patch.object(release, "github", return_value={"object": {"type": kind, "sha": "object-sha"}}):
                    with self.assertRaisesRegex(release.ReleaseError, "does not point to a commit"):
                        release.remote_tag_commit("owner/repo", "v4.0.1")

    def test_repeated_tag_object_is_rejected(self):
        with patch.object(release, "github", return_value={"object": {"type": "tag", "sha": "tag-sha"}}):
            with self.assertRaisesRegex(release.ReleaseError, "Repeated tag object"):
                release.remote_tag_commit("owner/repo", "v4.0.1")

    def test_tag_lookup_errors_and_disappearance_abort(self):
        cases = [(code, resolving) for code in (403, 422, 500) for resolving in (False, True)]
        for code, during_resolution in cases + [(404, True)]:
            with self.subTest(code=code, during_resolution=during_resolution):
                def request(args, **kwargs):
                    if during_resolution and "/git/ref/" in args[-1]:
                        body = json.dumps({"object": {"type": "tag", "sha": "tag-sha"}})
                        return subprocess.CompletedProcess(args, 0, "HTTP/2.0 200 OK\n\n" + body, "")
                    return subprocess.CompletedProcess(args, 1, f'HTTP/2.0 {code} Error\n\n{{"message":"Failed"}}', "")

                with patch.object(release.subprocess, "run", side_effect=request):
                    with self.assertRaises(release.ReleaseError):
                        release.remote_tag_commit("owner/repo", "v4.0.1")

    def test_release_lookup_includes_drafts_and_later_pages(self):
        draft = {"id": 101, "tag_name": "v4.0.1", "draft": True}
        def request(repo, path, expected_type=dict):
            self.assertIs(expected_type, list)
            if path == "releases?per_page=100&page=1":
                return [{"id": index, "tag_name": f"v0.0.{index}", "draft": False} for index in range(100)]
            self.assertEqual(path, "releases?per_page=100&page=2")
            return [draft]
        with patch.object(release, "github", side_effect=request):
            self.assertEqual(release.find_release("owner/repo", "v4.0.1"), draft)

    def test_automatic_build_number_advances_past_future_published_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
                <item><sparkle:version>99991231235959</sparkle:version></item>
                <item><enclosure sparkle:version="99991231235960.2"/></item></channel></rss>''')
            self.assertEqual(release.next_build_number(feed), "99991231235961")


if __name__ == "__main__":
    unittest.main()
