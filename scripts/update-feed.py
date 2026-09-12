#!/usr/bin/env python3
"""Generate a signed Sparkle feed for the notarized GitHub release archive."""
import argparse
import base64
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
KEY_ACCOUNT = "com.suku.eucaly"


def numeric_version(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise ValueError(f"Expected a numeric version, got {value!r}")
    parts = [int(part) for part in value.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def verify_advancing_version(info, previous_feed):
    if previous_feed is None:
        return
    for item in ET.parse(previous_feed).findall("./channel/item"):
        enclosure = item.find("enclosure")
        build = item.findtext(SPARKLE + "version")
        display = item.findtext(SPARKLE + "shortVersionString")
        if enclosure is not None:
            build = build or enclosure.get(SPARKLE + "version")
            display = display or enclosure.get(SPARKLE + "shortVersionString")
        if not build or numeric_version(info["CFBundleVersion"]) <= numeric_version(build):
            raise ValueError("The release build number must be greater than every published update build.")
        if display and numeric_version(info["CFBundleShortVersionString"]) < numeric_version(display):
            raise ValueError("The release version must not be older than a published update.")


def history_metadata(items):
    history = {}
    for item in items:
        enclosure = item.find("enclosure")
        build = item.findtext(SPARKLE + "version")
        if enclosure is not None:
            build = build or enclosure.get(SPARKLE + "version")
        if not build or build in history or enclosure is None:
            raise ValueError("Feed history must have one archive enclosure per build.")
        # Keep the archive URL/signature/length and OS/hardware/channel eligibility bound
        # to the previously signed item, including legacy enclosure attributes.
        history[build] = (dict(enclosure.attrib), tuple(item.findtext(SPARKLE + key) for key in (
            "minimumSystemVersion", "maximumSystemVersion", "hardwareRequirements", "minimumUpdateVersion", "channel")))
    return history


def verify_feed(feed, info, archive, download_url, previous_feed=None):
    items = ET.parse(feed).findall("./channel/item")
    current = [item for item in items if item.findtext(SPARKLE + "version") == info["CFBundleVersion"]]
    if len(current) != 1:
        raise ValueError("The update feed must contain exactly one item for the archived build.")
    item = current[0]
    if item.findtext(SPARKLE + "shortVersionString") != info["CFBundleShortVersionString"]:
        raise ValueError("The update feed version differs from the archived app.")
    if item.findtext(SPARKLE + "minimumSystemVersion") != info["LSMinimumSystemVersion"]:
        raise ValueError("The update feed must preserve the app's minimum macOS version.")
    # Sparkle infers arm64 from the archive; it omits the marker on macOS 27+,
    # where the OS requirement itself already excludes Intel Macs.
    if (numeric_version(info["LSMinimumSystemVersion"]) < (27,)
            and item.findtext(SPARKLE + "hardwareRequirements") != "arm64"):
        raise ValueError("The update feed must require Apple Silicon for this archive.")
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != download_url:
        raise ValueError("The update feed must point at this release's exact archive.")
    if int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise ValueError("The update feed archive length is incorrect.")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("The update archive requires an Ed25519 signature.")
    previous = ET.parse(previous_feed).findall("./channel/item") if previous_feed else []
    retained = [other for other in items if other is not item]
    if history_metadata(retained) != history_metadata(previous):
        raise ValueError("Previously published feed items changed, disappeared, or unexpected builds were added.")
    return signature


def generate(args):
    with (args.app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        raise ValueError("Invalid GitHub repository slug.")
    expected_feed = f"https://github.com/{args.repo}/releases/latest/download/appcast.xml"
    if (info.get("SUFeedURL") != expected_feed or info.get("SURequireSignedFeed") is not True
            or info.get("SUVerifyUpdateBeforeExtraction") is not True):
        raise ValueError("The app must require a signed update feed hosted in the destination repository.")
    if info.get("CFBundleIdentifier") != "com.suku.eucaly":
        raise ValueError("The archive must contain eucaly.")
    numeric_version(info["CFBundleVersion"])
    numeric_version(info["CFBundleShortVersionString"])
    verify_advancing_version(info, args.previous)
    tools = args.sparkle_bin
    public_key = subprocess.check_output(
        [str(tools / "generate_keys"), "--account", KEY_ACCOUNT, "-p"], text=True
    ).strip()
    if public_key != info.get("SUPublicEDKey"):
        raise ValueError("The signing key does not match the public key embedded in the app.")
    if args.previous:
        subprocess.run([str(tools / "sign_update"), "--account", KEY_ACCOUNT, "--verify", str(args.previous)], check=True)
    # The stable feed may retain previous releases for older macOS versions.
    # Isolate generation so unrelated zips and local builds cannot enter the feed.
    with tempfile.TemporaryDirectory(prefix="eucalyFeed-") as directory:
        staging = Path(directory)
        shutil.copy2(args.archive, staging / args.archive.name)
        feed = staging / "appcast.xml"
        if args.previous:
            shutil.copy2(args.previous, feed)
        download_prefix = f"https://github.com/{args.repo}/releases/download/{quote(args.tag, safe='')}/"
        release_url = f"https://github.com/{args.repo}/releases/tag/{quote(args.tag, safe='')}"
        print(f"Signing the Sparkle feed with Keychain account {KEY_ACCOUNT}. "
              "Approve macOS Keychain access for the Sparkle tools if prompted.", flush=True)
        subprocess.run([
            str(tools / "generate_appcast"), "--account", KEY_ACCOUNT,
            "--download-url-prefix", download_prefix, "--link", release_url,
            "--full-release-notes-url", release_url, "--maximum-deltas", "0",
            "--maximum-versions", "0", "-o", str(feed), str(staging)
        ], check=True)
        signature = verify_feed(feed, info, args.archive, download_prefix + quote(args.archive.name, safe=''), args.previous)
        for paths in [[str(args.archive), signature], [str(feed)]]:
            subprocess.run([str(tools / "sign_update"), "--account", KEY_ACCOUNT, "--verify", *paths], check=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(feed, args.output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ["app", "archive", "output", "sparkle-bin"]:
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--previous", type=Path)
    try:
        generate(parser.parse_args())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
        parser.exit(1, f"error: {error}\n")
