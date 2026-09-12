#!/usr/bin/env python3
"""Run version and update-feed regressions in temporary directories."""
import importlib.util
import base64
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
update_spec = importlib.util.spec_from_file_location("update_feed", ROOT / "scripts/update-feed.py")
update_feed = importlib.util.module_from_spec(update_spec)
update_spec.loader.exec_module(update_feed)


class VersionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="eucaly version ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.version = self.directory / "VERSION"
        self.version.write_text((ROOT / "VERSION").read_text())
        self.template = self.directory / "Source Info.plist"
        self.template.write_bytes((ROOT / "eucaly/Info.plist").read_bytes())
        self.output = self.directory / "Derived Files/Info.plist"

    def generate(self, override=None):
        command = ["/bin/bash", str(ROOT / "scripts/generate-info-plist.sh"),
                   str(self.version), str(self.template), str(self.output)]
        if override is not None:
            command.append(override)
        return subprocess.run(command, text=True, capture_output=True)

    def test_version_edits_update_plist_and_preserve_source_metadata(self):
        original_template = self.template.read_bytes()
        for version in (self.version.read_text().strip(), "1.33", "9.8.7"):
            with self.subTest(version=version):
                self.version.write_text(version + "\n")
                result = self.generate()
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = plistlib.loads(original_template)
                expected["CFBundleShortVersionString"] = version
                self.assertEqual(plistlib.loads(self.output.read_bytes()), expected)
                self.assertEqual(self.version.read_text(), version + "\n")
                self.assertEqual(self.template.read_bytes(), original_template)

    def test_version_override_is_rejected(self):
        original_version = self.version.read_bytes()
        result = self.generate("9.8.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.version.read_bytes(), original_version)

    def test_invalid_versions_fail_without_changing_generated_plist(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        original_output = self.output.read_bytes()
        for version in ("", "4.0.x", "1.2.3.4", "4.0.0-preview"):
            with self.subTest(version=version):
                self.version.write_text(version)
                result = self.generate()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("VERSION must contain a numeric", result.stderr)
                self.assertEqual(self.output.read_bytes(), original_output)

    def test_set_version_only_requires_the_version_file(self):
        scripts = self.directory / "scripts"
        scripts.mkdir()
        script = scripts / "set-version.sh"
        shutil.copy2(ROOT / "scripts/set-version.sh", script)
        subprocess.run([str(script), "9.8.5"], check=True)
        self.assertEqual(self.version.read_text(), "9.8.5\n")
        self.assertFalse((self.directory / "Config").exists())


class UpdateFeedTests(unittest.TestCase):
    def test_existing_feed_archives_and_os_hardware_eligibility_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "eucaly.zip"
            archive.write_bytes(b"fixture")
            feed = Path(directory) / "appcast.xml"
            previous = Path(directory) / "previous.xml"
            signature = base64.b64encode(b"s" * 64).decode()
            old_signature = base64.b64encode(b"p" * 64).decode()
            url = "https://github.com/sukujgrg/eucaly/releases/download/v4.1.0/eucaly.zip"
            old_url = "https://github.com/sukujgrg/eucaly/releases/download/v4.0.0/eucaly-old.zip"
            old = f'''<item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>4.0.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
                <enclosure url="{old_url}" sparkle:edSignature="{old_signature}" length="9"/></item>'''
            current = f'''<item><sparkle:version>101</sparkle:version><sparkle:shortVersionString>4.1.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
                <enclosure url="{url}" sparkle:edSignature="{signature}" length="7"/></item>'''
            def xml(items):
                return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>{items}</channel></rss>'
            info = {"CFBundleVersion": "101", "CFBundleShortVersionString": "4.1.0", "LSMinimumSystemVersion": "27.0"}
            previous.write_text(xml(old))
            feed.write_text(xml(current + old))
            self.assertEqual(update_feed.verify_feed(feed, info, archive, url, previous), signature)
            broken_history = {
                "new tag prefix": old.replace("download/v4.0.0/", "download/v4.1.0/"),
                "wrong length": old.replace('length="9"', 'length="10"'),
                "wrong signature": old.replace(old_signature, signature),
                "changed minimum OS": old.replace("26.0", "27.0"),
                "changed old hardware eligibility": old.replace("<enclosure", "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements><enclosure"),
                "removed older OS build": "",
                "duplicate build": old + old,
                "unexpected build": old + old.replace(">100<", ">99<"),
            }
            for name, history in broken_history.items():
                with self.subTest(change=name):
                    contents = xml(current + history)
                    feed.write_text(contents)
                    with self.assertRaises(ValueError):
                        update_feed.verify_feed(feed, info, archive, url, previous)
                    self.assertEqual(feed.read_text(), contents)
            # Older Sparkle feeds stored their build in enclosure attributes.
            legacy = old.replace("<sparkle:version>100</sparkle:version>", "").replace("<enclosure ", '<enclosure sparkle:version="100" ')
            previous.write_text(xml(legacy))
            feed.write_text(xml(current + legacy))
            self.assertEqual(update_feed.verify_feed(feed, info, archive, url, previous), signature)

    def test_rejects_older_builds_even_if_marketing_version_is_newer(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
                <channel><item><sparkle:version>20260909010101</sparkle:version>
                <sparkle:shortVersionString>3.0.5</sparkle:shortVersionString></item></channel></rss>''')
            for build in ["3", "20260909010101"]:
                with self.assertRaises(ValueError):
                    update_feed.verify_advancing_version({"CFBundleVersion": build, "CFBundleShortVersionString": "3.1.0"}, feed)
            info = {"CFBundleVersion": "20260910010101", "CFBundleShortVersionString": "3.1.0"}
            update_feed.verify_advancing_version(info, feed)
            info["CFBundleShortVersionString"] = "3.0.4"
            with self.assertRaises(ValueError):
                update_feed.verify_advancing_version(info, feed)

    def test_feed_must_match_signed_archive_version_url_length_os_and_hardware(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "eucaly.zip"
            archive.write_bytes(b"fixture")
            feed = Path(directory) / "appcast.xml"
            signature = base64.b64encode(b"s" * 64).decode()
            url = "https://github.com/sukujgrg/eucaly/releases/download/v3.1.0/eucaly.zip"
            xml = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
                <sparkle:version>20260910</sparkle:version><sparkle:shortVersionString>3.1.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
                <enclosure url="{url}" sparkle:edSignature="{signature}" length="7" type="application/octet-stream"/>
                </item></channel></rss>'''
            info = {"CFBundleVersion": "20260910", "CFBundleShortVersionString": "3.1.0", "LSMinimumSystemVersion": "14.0"}
            feed.write_text(xml)
            self.assertEqual(update_feed.verify_feed(feed, info, archive, url), signature)
            for before, after in [(url, "https://example.invalid/other.zip"), ('length="7"', 'length="8"'),
                                  ("14.0", "15.0"), ("3.1.0</", "3.0.5</"), (signature, ""),
                                  ("<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>", ""),
                                  ("arm64", "x86_64")]:
                with self.subTest(change=(before, after)):
                    feed.write_text(xml.replace(before, after))
                    with self.assertRaises(ValueError):
                        update_feed.verify_feed(feed, info, archive, url)


if __name__ == "__main__":
    unittest.main()
