#!/usr/bin/env python3
"""Build, sign, notarize, and publish eucaly from the maintainer's Mac."""
import argparse
import fcntl
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
PROJECT = "eucaly.xcodeproj"
APP_NAME = "eucaly"
RELEASE_BRANCH = "main"
KEY_ACCOUNT = "com.suku.eucaly"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
# Last release of the custom updater, before any Sparkle clients existed.
# A missing feed is allowed only for this known migration boundary.
LEGACY_RELEASE_TAG = "v1.32"
LEGACY_RELEASE_ID = 383478874


class ReleaseError(Exception):
    pass


def run(*args, capture=False, output=None, include_stderr=False):
    if output is not None:
        # Keep Apple's response even if the process is interrupted before the
        # caller can checkpoint its submission ID.
        with Path(output).open("w") as destination:
            result = subprocess.run([str(arg) for arg in args], cwd=ROOT, text=True,
                                    stdout=destination)
            destination.flush()
            os.fsync(destination.fileno())
        result.check_returncode()
        return
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, text=True,
                            check=True, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT if include_stderr else None)
    return result.stdout.strip() if capture else None


def github(repo, path, optional=False, expected_type=dict):
    """Only a confirmed HTTP 404 means absent; network/auth failures must stop."""
    result = subprocess.run(["gh", "api", "--include", f"repos/{repo}/{path}"],
                            cwd=ROOT, text=True, capture_output=True)
    status = re.match(r"HTTP/\S+ (\d+)", result.stdout)
    code = int(status[1]) if status else None
    if optional and code == 404:
        return None
    if result.returncode or code != 200:
        raise ReleaseError(f"GitHub request failed for {path} (HTTP {code or 'unavailable'}). "
                           "Check gh authentication and network access, then retry.")
    try:
        body = re.split(r"\r?\n\r?\n", result.stdout, maxsplit=1)[1]
        data = json.loads(body)
        if not isinstance(data, expected_type):
            raise ValueError("unexpected response type")
    except (IndexError, TypeError, ValueError) as error:
        raise ReleaseError(f"GitHub returned a malformed response for {path}. "
                           "Retry the same command; completed work is retained.") from error
    return data


def github_pages(repo, path):
    page = 1
    while True:
        items = github(repo, f"{path}?per_page=100&page={page}", expected_type=list)
        if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
            raise ReleaseError(f"GitHub returned an invalid list for {path}.")
        yield from items
        if len(items) < 100:
            return
        page += 1


def find_release(repo, tag):
    # The published-release endpoint alone cannot reliably find drafts.
    return next((item for item in github_pages(repo, "releases") if item["tag_name"] == tag), None)


def atomic_write(path, text):
    temporary = path.with_name("." + path.name + ".tmp")
    with temporary.open("w") as destination:
        destination.write(text)
        destination.flush()
        os.fsync(destination.fileno())
    temporary.replace(path)


def checkpoint(directory, state, **changes):
    state.update(changes)
    atomic_write(directory / "state.json", json.dumps(state, indent=2, sort_keys=True) + "\n")


def load_state(directory, identity):
    path = directory / "state.json"
    if not path.exists():
        return None
    try:
        state = json.loads(path.read_text())
        if (not isinstance(state, dict) or state.get("schema") != 1
                or any(state.get(key) != value for key, value in identity.items())
                or "previous_tag" not in state
                or not re.fullmatch(r"[0-9a-f]{32}", state.get("release_token", ""))):
            raise ValueError("source, repository, or format differs")
    except (ValueError, TypeError) as error:
        raise ReleaseError(f"Cannot reuse {path}: {error}. Restore the original checkout or move "
                           "this release directory aside before preparing again.") from error
    return state


@contextmanager
def release_lock():
    # Linked worktrees share this directory. Keep the lock outside build/ so
    # cleanup cannot unlink it while another process still holds the old inode.
    directory = Path(run("git", "rev-parse", "--git-common-dir", capture=True))
    if not directory.is_absolute():
        directory = ROOT / directory
    with (directory / "eucaly-release.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ReleaseError("Another local release or cleanup command is running for this repository.") from error
        yield


def clean_build():
    with release_lock():
        build = ROOT / "build"
        if build.is_symlink():
            raise ReleaseError("Refusing to clean a build directory that is a symlink.")
        if build.exists():
            for path in build.iterdir():
                if path.name == "release":
                    continue
                if path.is_symlink() or not path.is_dir():
                    path.unlink()
                else:
                    shutil.rmtree(path)
        print("Build caches removed; saved release artifacts were preserved.", flush=True)


def digest(path):
    if path.is_symlink():
        raise ReleaseError(f"Saved artifact must not be a symlink: {path}")
    if path.is_file():
        result = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                result.update(block)
        return result.hexdigest()
    if path.is_dir():
        # Include names, symlink targets, and modes, but not changing timestamps.
        entries = []
        for child in sorted(path.rglob("*")):
            mode = child.lstat().st_mode
            value = ("link", os.readlink(child)) if stat.S_ISLNK(mode) else (
                ("file", digest(child)) if stat.S_ISREG(mode) else ("directory", ""))
            entries.append((str(child.relative_to(path)), stat.S_IMODE(mode), value))
        return hashlib.sha256(json.dumps(entries).encode()).hexdigest()
    raise ReleaseError(f"Saved artifact is missing: {path}. Restore it or move this release directory aside.")


def preserved(directory, state, key, path):
    if key not in state:
        return False
    if digest(path) != state[key]:
        raise ReleaseError(f"Saved artifact changed: {path}. Refusing to reuse it; "
                           f"restore it or move {directory} aside before preparing again.")
    return True


def artifact_paths(directory, version):
    archive = directory / f"{APP_NAME}-{version}-notarized.zip"
    return [archive, archive.with_suffix(".zip.sha256"), archive.with_suffix(".zip.source.txt"),
            directory / "appcast.xml"]


def verify_artifacts(directory, state):
    artifacts = artifact_paths(directory, state["version"])
    recorded = state.get("artifacts")
    if not isinstance(recorded, dict) or set(recorded) != {path.name for path in artifacts}:
        raise ReleaseError("No complete prepared release. Run make release-notarize or make release first.")
    for path in artifacts:
        if digest(path) != recorded[path.name]:
            raise ReleaseError(f"Prepared release file changed: {path}. Refusing to publish it.")
    return artifacts


def release_marker(state):
    return f"<!-- eucaly release {state['release_token']} {state['commit']} -->"


def verify_owned_release(existing, state):
    # target_commitish is a creation hint and may be a branch name. The actual
    # source is checked by resolving the remote tag in verify_destination.
    if (not state or not state.get("artifacts")
            or existing.get("tag_name") != state["tag"]
            or release_marker(state) not in (existing.get("body") or "")
            or existing.get("prerelease") is not False
            or (state.get("release_id") is not None and existing["id"] != state["release_id"])):
        raise ReleaseError("A release or draft already exists for this version and does not belong to "
                           "these prepared artifacts. Inspect it on GitHub; published releases are never overwritten.")


def source_commit(expected=None):
    if run("git", "status", "--porcelain", "--untracked-files=normal", capture=True):
        raise ReleaseError("Release requires a clean working tree, including untracked files.")
    try:
        commit = run("git", "rev-parse", "--verify", "HEAD^{commit}", capture=True)
    except subprocess.CalledProcessError as error:
        raise ReleaseError("Commit the release source before building.") from error
    if expected is not None and commit != expected:
        raise ReleaseError("HEAD changed during the release. Retry from the intended commit.")
    return commit


def release_repository():
    # Push to the exact URL we checked, including repositories using a pushurl.
    origin = run("git", "remote", "get-url", "--push", "--all", "origin", capture=True)
    match = re.fullmatch(r"https://github\.com/"
                         r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", origin)
    if not match:
        raise ReleaseError("origin must have one HTTPS GitHub push URL: https://github.com/OWNER/REPO.git")
    return match[1], origin


def read_release_notes(path):
    if path is None:
        return None
    path = path.expanduser().resolve()
    if path.is_relative_to(ROOT.resolve()):
        raise ReleaseError("Keep release notes outside the checkout. Use NOTES_FILE=/tmp/eucaly-notes.md "
                           "(or --notes with that path) so the release source stays clean.")
    if not path.is_file():
        raise ReleaseError(f"Release notes file does not exist: {path}")
    return path.read_text()


def verify_ci(repo, commit):
    """Require the newest Validate push run on main for this exact source commit."""
    if github(repo, f"commits/{commit}", optional=True) is None:
        raise ReleaseError(f"Commit and merge or push this source to {RELEASE_BRANCH} before running make release.")
    fields = "databaseId,headSha,headBranch,event,status,conclusion,url"
    expected_source = {"headSha": commit, "headBranch": RELEASE_BRANCH, "event": "push"}
    for attempt in range(13):
        runs = json.loads(run("gh", "run", "list", "--repo", repo, "--workflow", "validate.yml",
                              "--commit", commit, "--branch", RELEASE_BRANCH, "--event", "push", "--limit", "1",
                              "--json", fields, capture=True))
        if runs:
            break
        if attempt == 12:
            raise ReleaseError(f"No Validate push run on {RELEASE_BRANCH} was found for this commit. "
                               f"Merge or push the release changes to {RELEASE_BRANCH}, update your local checkout, and retry.")
        if attempt == 0:
            print("Waiting for GitHub to start Validate for this commit…", flush=True)
        time.sleep(5)
    result = runs[0]
    if any(result.get(key) != value for key, value in expected_source.items()):
        raise ReleaseError(f"Releases require a {RELEASE_BRANCH} push run for this exact source commit.")
    print(f"Validation: {result['url']}", flush=True)
    if result["status"] != "completed":
        # Poll through gh so classic and fine-grained credentials both work.
        deadline = time.monotonic() + 3600
        print("Waiting for Validate to finish…", flush=True)
        while result["status"] != "completed":
            if time.monotonic() >= deadline:
                raise ReleaseError("Validate has not completed after one hour. Retry once it finishes.")
            time.sleep(10)
            result = json.loads(run("gh", "run", "view", str(result["databaseId"]), "--repo", repo,
                                    "--json", fields, capture=True))
    if any(result.get(key) != value for key, value in expected_source.items()) or result["conclusion"] != "success":
        raise ReleaseError(f"Validate did not pass for this commit ({result['conclusion']}). "
                           f"Fix the failure before releasing: {result['url']}")


def remote_tag_commit(repo, tag):
    # Missing refs return 404 here; the commit endpoint returns 422 instead.
    name = quote(tag, safe="")
    reference = github(repo, f"git/ref/tags/{name}", optional=True)
    if reference is None:
        return None
    # Lightweight refs point directly to commits. Annotated refs point to tag
    # objects (possibly another tag), not commit SHAs or "tags/<name>" commits.
    target = reference["object"]
    seen = set()
    while target["type"] == "tag":
        sha = target["sha"]
        if sha in seen:
            raise ReleaseError(f"Repeated tag object while resolving GitHub tag {tag}.")
        seen.add(sha)
        target = github(repo, f"git/tags/{quote(sha, safe='')}")["object"]
    if target["type"] != "commit":
        raise ReleaseError(f"GitHub tag {tag} does not point to a commit.")
    return target["sha"]


def verify_destination(repo, tag, commit, state=None):
    existing = find_release(repo, tag)
    if existing is not None:
        verify_owned_release(existing, state)
    local = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}"],
                           cwd=ROOT, text=True, capture_output=True)
    if local.returncode == 0 and local.stdout.strip() != commit:
        raise ReleaseError(f"Local tag {tag} points to another commit. Choose a new VERSION.")
    if local.returncode not in (0, 1):
        raise ReleaseError(f"Could not inspect local tag {tag}.")
    remote = remote_tag_commit(repo, tag)
    if remote is not None and remote != commit:
        raise ReleaseError(f"GitHub tag {tag} points to another commit. Choose a new VERSION.")
    if existing is not None and remote is None:
        raise ReleaseError("The existing release's tag is missing on GitHub. Inspect it before retrying.")
    return local.returncode == 0, remote is not None, existing


def latest_tag(repo):
    release = github(repo, "releases/latest", optional=True)
    return release["tag_name"] if release else None


def next_build_number(previous):
    build = int(datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))
    if previous:
        for item in ET.parse(previous).findall("./channel/item"):
            enclosure = item.find("enclosure")
            value = item.findtext(SPARKLE + "version")
            if not value and enclosure is not None:
                value = enclosure.get(SPARKLE + "version")
            if not value or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
                raise ReleaseError("The previous appcast contains an invalid build number.")
            build = max(build, int(value.split(".")[0]) + 1)
    return str(build)


def verify_arm64_app(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    framework = app / "Contents/Frameworks/Sparkle.framework"
    binaries = [app / "Contents/MacOS" / info["CFBundleExecutable"]]
    binaries.extend(framework / path for path in (
        "Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
        "XPCServices/Installer.xpc/Contents/MacOS/Installer",
        "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"))
    for binary in binaries:
        if not binary.is_file() or not binary.resolve().is_relative_to(app.resolve()):
            raise ReleaseError(f"Required executable is missing or outside the app: {binary}")
        run("lipo", binary, "-verify_arch", "arm64")
    # Sparkle ships prebuilt universal helpers; require their arm64 slice without
    # rewriting third-party binaries. Our executable must be arm64 only.
    if run("lipo", binaries[0], "-archs", capture=True).split() != ["arm64"]:
        raise ReleaseError("eucaly must be built for arm64 only.")
    return binaries


def release_team(derived):
    settings = json.loads(run("xcodebuild", "-project", PROJECT, "-scheme", APP_NAME,
                              "-configuration", "Release", "-derivedDataPath", derived,
                              "-showBuildSettings", "-json", capture=True))
    targets = [item["buildSettings"] for item in settings if item.get("target") == APP_NAME]
    if len(targets) != 1 or not targets[0].get("DEVELOPMENT_TEAM"):
        raise ReleaseError("The Release target must configure DEVELOPMENT_TEAM.")
    return targets[0]["DEVELOPMENT_TEAM"]


def verify_app(app, state, team):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleShortVersionString": state["version"], "CFBundleVersion": state["build"],
                "EucalySourceCommit": state["commit"], "CFBundleIdentifier": "com.suku.eucaly"}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ReleaseError("The exported app's version/build/source does not match the verified source.")
    # eucaly is unsandboxed. Keep its existing file access and preferences;
    # Sparkle's sandbox escape services and Mach exceptions are unnecessary.
    if info.get("SUEnableInstallerLauncherService") or info.get("SUEnableDownloaderService"):
        raise ReleaseError("The unsandboxed app must not enable Sparkle's sandbox XPC services.")
    binaries = verify_arm64_app(app)
    run("codesign", "--verify", "--deep", "--strict", app)
    for binary in binaries:
        details = run("codesign", "-dv", "--verbose=4", "--arch", "arm64", binary,
                      capture=True, include_stderr=True)
        flags = re.search(r"\bflags=0x([0-9a-fA-F]+)\b", details)
        identity = re.search(r"^TeamIdentifier=(.+)$", details, re.MULTILINE)
        if not flags or not int(flags[1], 16) & 0x10000:
            raise ReleaseError(f"Hardened runtime is missing for {binary} (arm64).")
        if not identity or identity[1] != team:
            raise ReleaseError(f"Signing team differs from DEVELOPMENT_TEAM for {binary} (arm64).")
        xml = run("codesign", "-d", "--arch", "arm64", "--entitlements", "-", "--xml", binary, capture=True)
        entitlements = plistlib.loads(xml.encode()) if xml else {}
        if entitlements.get("com.apple.security.get-task-allow"):
            raise ReleaseError(f"Debugging entitlement is present in {binary} (arm64).")
        if binary == binaries[0] and entitlements.get("com.apple.security.app-sandbox"):
            raise ReleaseError("eucaly must retain its unsandboxed file access (arm64).")


def notarize(directory, state, args, notary_zip):
    work = directory / "work"
    response_file = work / "notary-submission.json"
    profile = ("--keychain-profile", args.notary_profile)
    supplied = str(uuid.UUID(args.resume_notarization)) if args.resume_notarization else None
    if supplied:
        # An operator can recover an ID lost during submission, but cannot
        # replace a known submission. Apple's log must match the archive hash.
        if not state.get("submission_started") or (state.get("notary_id") not in (None, supplied)):
            raise ReleaseError("--resume-notarization can only recover this archive's interrupted submission.")
    if state.get("notarized"):
        return
    if not supplied and not state.get("notary_id"):
        if not state.get("submission_started"):
            checkpoint(directory, state, submission_started=True)
            print("Submitting to Apple for notarization…", flush=True)
            run("xcrun", "notarytool", "submit", notary_zip, *profile, "--no-wait",
                "--output-format", "json", output=response_file)
        try:
            submission = str(uuid.UUID(json.loads(response_file.read_text())["id"]))
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise ReleaseError("The Apple submission outcome is unknown; it will not be uploaded again "
                               "automatically. Find its ID with xcrun notarytool history and use "
                               "--resume-notarization ID. See docs/releasing.md.") from error
        checkpoint(directory, state, notary_id=submission)
    submission = supplied or state["notary_id"]
    uuid.UUID(submission)
    print(f"Notarization submission: {submission}", flush=True)
    response = json.loads(run("xcrun", "notarytool", "info", submission, *profile,
                              "--output-format", "json", capture=True))
    if response.get("status") == "In Progress":
        try:
            response = json.loads(run("xcrun", "notarytool", "wait", submission, *profile,
                                      "--timeout", "1h", "--output-format", "json", capture=True))
        except subprocess.CalledProcessError:
            # A wait timeout or disconnection does not cancel Apple's work.
            response = json.loads(run("xcrun", "notarytool", "info", submission, *profile,
                                      "--output-format", "json", capture=True))
    if response.get("status") == "In Progress":
        raise ReleaseError(f"Apple is still processing {submission}. Run the same command later to resume.")
    log_path = work / "notary-log.json"
    run("xcrun", "notarytool", "log", submission, *profile, output=log_path)
    log = json.loads(log_path.read_text())
    if (not isinstance(log, dict) or log.get("jobId") != submission
            or not isinstance(log.get("sha256"), str) or log["sha256"].lower() != state["notary_zip_hash"]):
        raise ReleaseError(f"Apple's submission does not match the saved archive. Inspect {log_path}.")
    if response.get("status") != "Accepted" or log.get("status") != "Accepted":
        raise ReleaseError(f"Notarization was not accepted ({response.get('status')}). Inspect {log_path}.")
    checkpoint(directory, state, notary_id=submission, notarized=True)


def prepare(directory, state, args):
    if state.get("artifacts"):
        if args.resume_notarization:
            raise ReleaseError("This release is already prepared; omit --resume-notarization.")
        print("Reusing verified prepared artifacts…", flush=True)
        return verify_artifacts(directory, state)
    for tool in ("xcodebuild", "xcrun", "ditto", "lipo", "codesign", "security"):
        if not shutil.which(tool):
            raise ReleaseError(f"Missing {tool}. Install/select Xcode on this Mac.")
    if not state.get("export_hash"):
        identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
        if "Developer ID Application:" not in identities:
            raise ReleaseError("No valid Developer ID Application identity is available in this Mac's Keychain.")
    if not state.get("notarized"):
        run("xcrun", "notarytool", "history", "--keychain-profile", args.notary_profile,
            "--output-format", "json", capture=True)
    derived = ROOT / "build/ReleaseDerivedData"
    run("xcodebuild", "-resolvePackageDependencies", "-project", PROJECT,
        "-scheme", APP_NAME, "-derivedDataPath", derived)
    team = release_team(derived)
    sparkle = derived / "SourcePackages/artifacts/sparkle/Sparkle/bin"
    source_info = plistlib.loads((ROOT / "eucaly/Info.plist").read_bytes())
    if run(sparkle / "generate_keys", "--account", KEY_ACCOUNT, "-p", capture=True) != source_info["SUPublicEDKey"]:
        raise ReleaseError("The Keychain signing key differs from Info.plist. See docs/self-updates.md.")
    work = directory / "work"
    work.mkdir(exist_ok=True)
    previous = work / "previous-appcast.xml" if state.get("previous_hash") else None
    if previous:
        preserved(directory, state, "previous_hash", previous)
    if "build" not in state:
        if state["previous_tag"]:
            previous_release = find_release(state["repo"], state["previous_tag"])
            if previous_release is None or previous_release["draft"]:
                raise ReleaseError("The previous published release is no longer available.")
            has_feed = any(asset["name"] == "appcast.xml" for asset in github_pages(
                state["repo"], f"releases/{previous_release['id']}/assets"))
            if has_feed:
                with tempfile.TemporaryDirectory(dir=work) as download:
                    run("gh", "release", "download", state["previous_tag"], "--repo", state["repo"],
                        "--pattern", "appcast.xml", "--dir", download)
                    previous = work / "previous-appcast.xml"
                    (Path(download) / "appcast.xml").replace(previous)
                run(sparkle / "sign_update", "--account", KEY_ACCOUNT, "--verify", previous)
                checkpoint(directory, state, previous_hash=digest(previous))
            elif (state["previous_tag"] == LEGACY_RELEASE_TAG
                  and previous_release["id"] == LEGACY_RELEASE_ID
                  and tuple(map(int, state["version"].split("."))) > (1, 32, 0)):
                print("Starting the first Sparkle feed after legacy eucaly v1.32.", flush=True)
                checkpoint(directory, state, legacy_feed_bootstrap=True)
            else:
                raise ReleaseError(f"The latest release {state['previous_tag']} has no appcast.xml. "
                                   "Only the known legacy v1.32 release can bootstrap a feed.")
        checkpoint(directory, state, build=next_build_number(previous))
    legacy_bootstrap = state.get("legacy_feed_bootstrap") is True and state["previous_tag"] == LEGACY_RELEASE_TAG
    if state["previous_tag"] and previous is None and not legacy_bootstrap:
        raise ReleaseError("Saved preparation is missing its previous signed feed. Restore the saved work before retrying.")
    if previous:
        run(sparkle / "sign_update", "--account", KEY_ACCOUNT, "--verify", previous)
    app = work / "export" / f"{APP_NAME}.app"
    exported = preserved(directory, state, "export_hash", app)
    if not exported:
        archive = work / f"{APP_NAME}.xcarchive"
        if not preserved(directory, state, "archive_hash", archive):
            if archive.exists():
                shutil.rmtree(archive)
            source_commit(state["commit"])
            run("xcodebuild", "-project", PROJECT, "-scheme", APP_NAME, "-configuration", "Release",
                "-derivedDataPath", derived, "-archivePath", archive, "archive",
                "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "SKIP_INSTALL=NO",
                "STRIP_INSTALLED_PRODUCT=YES", "COPY_PHASE_STRIP=YES",
                f"CURRENT_PROJECT_VERSION={state['build']}", f"EUCALY_SOURCE_COMMIT={state['commit']}")
            source_commit(state["commit"])
            checkpoint(directory, state, archive_hash=digest(archive))
        if app.parent.exists():
            shutil.rmtree(app.parent)
        export_options = work / "exportOptions.plist"
        export_options.write_bytes(plistlib.dumps({"method": "developer-id", "signingStyle": "automatic",
                                                   "stripSwiftSymbols": True, "compileBitcode": False}))
        run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", app.parent,
            "-exportOptionsPlist", export_options)
        source_commit(state["commit"])
    verify_app(app, state, team)
    if not exported:
        checkpoint(directory, state, export_hash=digest(app))
    source_commit(state["commit"])
    notary_zip = work / "notarize.zip"
    if not preserved(directory, state, "notary_zip_hash", notary_zip):
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, notary_zip)
        checkpoint(directory, state, notary_zip_hash=digest(notary_zip))
    notarize(directory, state, args, notary_zip)
    final_app = directory / app.name
    if preserved(directory, state, "app_hash", final_app):
        # The ticket can live in extended attributes, outside the file-content
        # checkpoint. Validate it again before packaging a saved app.
        run("xcrun", "stapler", "validate", final_app)
    else:
        # Keep the submitted app unchanged. Staple a copy so an interrupted
        # stapler command can be repeated without invalidating the checkpoint.
        if final_app.exists():
            shutil.rmtree(final_app)
        run("ditto", app, final_app)
        run("xcrun", "stapler", "staple", final_app)
        run("xcrun", "stapler", "validate", final_app)
        verify_app(final_app, state, team)
        checkpoint(directory, state, app_hash=digest(final_app))
    final_zip, checksum, metadata, feed = artifact_paths(directory, state["version"])
    if not preserved(directory, state, "zip_hash", final_zip):
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", final_app, final_zip)
        checkpoint(directory, state, zip_hash=digest(final_zip))
    atomic_write(checksum, f"{state['zip_hash']}  {final_zip.name}\n")
    atomic_write(metadata, f"source_commit={state['commit']}\ntag={state['tag']}\n"
                 f"version={state['version']}\nbuild={state['build']}\n")
    command = [sys.executable, ROOT / "scripts/update-feed.py", "--app", final_app, "--archive", final_zip,
               "--output", feed, "--repo", state["repo"], "--tag", state["tag"], "--sparkle-bin", sparkle]
    if previous:
        command.extend(["--previous", previous])
    run(*command)
    source_commit(state["commit"])
    artifacts = artifact_paths(directory, state["version"])
    checkpoint(directory, state, artifacts={path.name: digest(path) for path in artifacts})
    return artifacts


def verify_uploaded(repo, tag, path, asset, expected):
    if asset.get("state") != "uploaded" or asset.get("size") != path.stat().st_size:
        raise ReleaseError(f"GitHub asset is incomplete or differs from the prepared file: {path.name}")
    remote_digest = asset.get("digest")
    if remote_digest is None:
        # Older assets/API versions may omit digest. Compare the actual bytes.
        with tempfile.TemporaryDirectory(prefix="eucalyAsset-") as download:
            run("gh", "release", "download", tag, "--repo", repo, "--pattern", path.name, "--dir", download)
            remote_digest = "sha256:" + digest(Path(download) / path.name)
    if remote_digest != "sha256:" + expected:
        raise ReleaseError(f"GitHub asset differs from the prepared file: {path.name}. It was not overwritten.")


def verify_remote_artifacts(directory, state, existing, complete=False):
    assets = {}
    for asset in github_pages(state["repo"], f"releases/{existing['id']}/assets"):
        name = asset["name"]
        if name not in state["artifacts"] or name in assets:
            raise ReleaseError(f"Unexpected or duplicate asset on the release: {name}. Inspect the draft on GitHub.")
        assets[name] = asset
        if not complete and existing["draft"] and asset.get("state") == "starter" and asset.get("size") == 0:
            continue
        verify_uploaded(state["repo"], state["tag"], directory / name, asset, state["artifacts"][name])
    if complete and set(assets) != set(state["artifacts"]):
        raise ReleaseError("GitHub release is missing prepared artifacts. Retry publication to finish the draft.")
    return assets


def current_release(state):
    existing = github(state["repo"], f"releases/{state['release_id']}")
    verify_owned_release(existing, state)
    return existing


def verify_latest(state):
    if latest_tag(state["repo"]) != state["previous_tag"]:
        raise ReleaseError("The latest release changed since preparation. Saved artifacts were preserved; "
                           "prepare a new version from the intended source and current update feed.")


def publish(directory, state, supplied_notes):
    repo, origin, version, tag, commit = (state[key] for key in ("repo", "origin", "version", "tag", "commit"))
    artifacts = verify_artifacts(directory, state)
    source_commit(commit)
    verify_ci(repo, commit)
    source_commit(commit)
    local_exists, remote_exists, existing = verify_destination(repo, tag, commit, state)
    if existing is not None and not existing["draft"]:
        verify_remote_artifacts(directory, state, existing, complete=True)
        print("This exact release is already published; no changes were made.", flush=True)
        return
    verify_latest(state)
    if "release_body" not in state:
        text = supplied_notes if supplied_notes is not None else f"Notarized release {version} from source commit {commit}"
        checkpoint(directory, state, notes=text, release_body=text + "\n\n" + release_marker(state))
    elif supplied_notes is not None and supplied_notes != state["notes"]:
        raise ReleaseError("Release notes differ from the saved draft. Retry with the original notes or omit --notes.")
    if remote_exists:
        if not local_exists:
            run("git", "fetch", "--no-tags", origin, f"refs/tags/{tag}:refs/tags/{tag}")
    else:
        if not local_exists:
            run("git", "tag", "-a", tag, commit, "-m", f"{APP_NAME} {version}")
        run("git", "push", origin, f"refs/tags/{tag}:refs/tags/{tag}")
    if remote_tag_commit(repo, tag) != commit:
        raise ReleaseError("The GitHub tag changed before publication.")
    source_commit(commit)
    if existing is None:
        notes_file = directory / "work/release-notes.md"
        notes_file.parent.mkdir(exist_ok=True)
        atomic_write(notes_file, state["release_body"])
        run("gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--target", commit,
            "--draft", "--title", f"{APP_NAME} {version}", "--notes-file", notes_file)
        # The release list can lag behind a successful creation. Retry only
        # reads; never repeat the create request to handle a visibility delay.
        for delay in (0, 1, 2, 4, 8):
            if delay:
                time.sleep(delay)
            existing = find_release(repo, tag)
            if existing is not None:
                break
        if existing is None:
            raise ReleaseError("The draft creation result is not visible yet. Retry the same command.")
        verify_owned_release(existing, state)
    checkpoint(directory, state, release_id=existing["id"])
    for path in artifacts:
        existing = current_release(state)
        if not existing["draft"]:
            verify_remote_artifacts(directory, state, existing, complete=True)
            return
        assets = verify_remote_artifacts(directory, state, existing)
        asset = assets.get(path.name)
        if asset is not None and asset["state"] == "uploaded":
            continue
        if asset is not None:
            # GitHub can leave an empty 'starter' asset after an interrupted
            # upload. Only remove that placeholder on our own unpublished draft.
            run("gh", "api", "--method", "DELETE", f"repos/{repo}/releases/assets/{asset['id']}")
        print(f"Uploading {path.name}…", flush=True)
        run("gh", "release", "upload", tag, path, "--repo", repo)
    # Check again after uploads, before the single operation that exposes the
    # release and its Sparkle feed to users.
    verify_ci(repo, commit)
    _, _, existing = verify_destination(repo, tag, commit, state)
    if existing is None:
        raise ReleaseError("The draft disappeared during publication.")
    verify_remote_artifacts(directory, state, existing, complete=True)
    if existing["draft"]:
        verify_latest(state)
        verify_artifacts(directory, state)
        source_commit(commit)
        run("gh", "release", "edit", tag, "--repo", repo, "--verify-tag", "--draft=false", "--latest")
    existing = current_release(state)
    if existing["draft"]:
        raise ReleaseError("GitHub still reports a draft. Retry publication; saved artifacts will be reused.")
    verify_remote_artifacts(directory, state, existing, complete=True)


def release(args):
    if platform.system() != "Darwin" or any(os.environ.get(key, "").lower() in ("true", "1", "yes")
                                            for key in ("CI", "GITHUB_ACTIONS")):
        raise ReleaseError("Run releases on your Mac, outside CI. Signing credentials stay in your local Keychain.")
    for tool in ("git", "gh"):
        if not shutil.which(tool):
            raise ReleaseError(f"Install {tool} before releasing.")
    supplied_notes = read_release_notes(args.notes)
    commit = source_commit()
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+(\.[0-9]+)?", version):
        raise ReleaseError("VERSION must contain one numeric X.Y or X.Y.Z version.")
    tag = f"v{version}"
    repo, origin = release_repository()
    info = plistlib.loads((ROOT / "eucaly/Info.plist").read_bytes())
    if info["SUFeedURL"] != f"https://github.com/{repo}/releases/latest/download/appcast.xml":
        raise ReleaseError("origin's push repository differs from the app's update feed.")
    if args.resume_notarization and (args.check or args.publish_only):
        raise ReleaseError("--resume-notarization requires artifact preparation.")
    identity = dict(repo=repo, origin=origin, commit=commit, version=version, tag=tag)
    directory = ROOT / "build/release" / tag
    if args.check:
        state = load_state(directory, identity)
        verify_destination(repo, tag, commit, state)
        verify_ci(repo, commit)
        source_commit(commit)
        print(f"Release source ready: {tag} at {commit}", flush=True)
        return
    with release_lock():
        state = load_state(directory, identity)
        _, _, existing = verify_destination(repo, tag, commit, state)
        verify_ci(repo, commit)
        source_commit(commit)
        if state is None:
            if args.publish_only or args.resume_notarization:
                raise ReleaseError("No saved preparation exists. Run make release-notarize or make release first.")
            if directory.exists() and any(directory.iterdir()):
                raise ReleaseError(f"Unrecorded artifacts exist in {directory}. Move that directory aside before preparing again.")
            directory.mkdir(parents=True, exist_ok=True)
            state = dict(schema=1, **identity, previous_tag=latest_tag(repo), release_token=uuid.uuid4().hex)
            checkpoint(directory, state)
        print(f"Release source: {tag} at {commit}\nSaved work: {directory}", flush=True)
        if existing is None or existing["draft"]:
            verify_latest(state)
        if args.publish_only:
            verify_artifacts(directory, state)
        else:
            prepare(directory, state, args)
        source_commit(commit)
        print(f"Signed artifacts: {directory}", flush=True)
        if not args.no_publish:
            publish(directory, state, supplied_notes)
            print(f"Release complete: https://github.com/{repo}/releases/tag/{tag}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notary-profile", default="eucalyNotary", help="local Keychain profile (default: eucalyNotary)")
    parser.add_argument("--notes", type=Path, help="optional release notes file outside the checkout")
    parser.add_argument("--resume-notarization", help="recover a lost Apple submission ID for the saved archive")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--clean", action="store_true", help="remove build caches while preserving saved releases; refuse during a release")
    modes.add_argument("--check", action="store_true", help="only verify source, destination, and CI; do not build or publish")
    modes.add_argument("--no-publish", action="store_true", help="create signed artifacts locally without tagging or publishing")
    modes.add_argument("--publish-only", action="store_true", help="publish already prepared artifacts without building or notarizing")
    try:
        args = parser.parse_args()
        if args.clean:
            if args.notes or args.resume_notarization:
                raise ReleaseError("--clean cannot be combined with release notes or notarization recovery.")
            clean_build()
        else:
            release(args)
    except (ReleaseError, OSError, ValueError, KeyError, TypeError, IndexError, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")
    except KeyboardInterrupt:
        parser.exit(130, "Release interrupted. Saved work is retained; rerun the same command to resume.\n")
