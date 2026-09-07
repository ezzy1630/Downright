"""Exercise the public release gate without contacting a release server."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FEED = '''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item>
<sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
<sparkle:version>1</sparkle:version>
<enclosure url="https://github.com/ezzy1630/Downright/releases/download/auto-test/update.zip" length="1"
 sparkle:edSignature="enclosure-signature"/>
</item></channel></rss>
'''
SIGNATURE = '<!-- sparkle-signatures: edSignature: YWJjZA== -->\n'

# Mock only HTTP; the production script still runs Bash, xmllint, grep and
# Python. The request log proves failed prerequisites never reach the asset.
CURL = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

args = sys.argv[1:]
destination = args[args.index("-o") + 1]
with open(os.environ["REQUEST_LOG"], "a") as log:
    log.write("asset\\n" if destination == "/dev/null" else "feed\\n")
if destination == "/dev/null":
    sys.exit(int(os.environ.get("ASSET_STATUS", "0")))
Path(destination).write_bytes(Path(os.environ["FIXTURE"]).read_bytes())
sys.exit(int(os.environ.get("FEED_STATUS", "0")))
'''


class PublicUpdateVerifierTests(unittest.TestCase):
    def verify(self, feed, *, feed_status=0, asset_status=0, attempts=1):
        with tempfile.TemporaryDirectory(prefix="downright-verifier-test-") as directory:
            root = Path(directory)
            fixture = root / "fixture.xml"
            fixture.write_text(feed)
            curl = root / "curl"
            curl.write_text(CURL)
            curl.chmod(0o755)
            request_log = root / "requests"
            environment = dict(
                os.environ,
                PATH=f"{root}{os.pathsep}{os.environ['PATH']}",
                FIXTURE=str(fixture),
                REQUEST_LOG=str(request_log),
                FEED_STATUS=str(feed_status),
                ASSET_STATUS=str(asset_status),
                VERIFY_PUBLIC_UPDATE_ATTEMPTS=str(attempts),
                VERIFY_PUBLIC_UPDATE_DELAY_SECONDS="0",
            )
            result = subprocess.run(
                ["bash", str(ROOT / "Scripts/verify-public-update.sh"),
                 "https://example.com/appcast.xml", "1.0.0", "1", "auto-test"],
                env=environment, capture_output=True, text=True, timeout=15,
            )
            requests = request_log.read_text().splitlines() if request_log.exists() else []
            return result, requests

    def assert_rejected_before_asset(self, feed, **kwargs):
        result, requests = self.verify(feed, **kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("public feed is current", result.stdout)
        self.assertNotIn("asset", requests)
        return requests

    def test_current_feed_and_reachable_asset_pass(self):
        result, requests = self.verify(FEED + SIGNATURE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ["feed", "asset"])

    def test_missing_feed_signature_is_rejected(self):
        self.assert_rejected_before_asset(FEED)

    def test_missing_signature_value_is_rejected(self):
        self.assert_rejected_before_asset(FEED + '<!-- sparkle-signatures: -->')

    def test_failed_fetch_cannot_validate_usable_response_body(self):
        self.assert_rejected_before_asset(FEED + SIGNATURE, feed_status=22)

    def test_failed_prerequisite_is_retried_and_remains_failure(self):
        requests = self.assert_rejected_before_asset(FEED, attempts=2)
        self.assertEqual(requests, ["feed", "feed"])

    def test_malformed_xml_is_rejected(self):
        self.assert_rejected_before_asset(FEED.replace('</rss>', '') + SIGNATURE)

    def test_stale_metadata_is_rejected(self):
        self.assert_rejected_before_asset(FEED.replace('>1</sparkle:version>', '>0</sparkle:version>') + SIGNATURE)

    def test_unreachable_asset_is_rejected(self):
        result, requests = self.verify(FEED + SIGNATURE, asset_status=22)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, ["feed", "asset"])

    def test_enclosure_must_target_exact_repository_and_release(self):
        expected = "https://github.com/ezzy1630/Downright/releases/download/auto-test/update.zip"
        invalid_urls = [
            expected.replace("github.com", "example.com"),
            expected.replace("ezzy1630/Downright", "other/Downright"),
            expected.replace("auto-test/", "auto-test-old/"),
            expected.replace("auto-test/", "old/") + "?tag=auto-test",
            expected + "?redirect=elsewhere",
            expected + "#auto-test",
            expected.replace("github.com", "user@github.com"),
            expected.replace("github.com", "github.com:443"),
            expected.replace("https://", "http://"),
            expected.replace("update.zip", ""),
            expected.replace("update.zip", "nested/update.zip"),
            expected.replace("update.zip", "%2e%2e"),
        ]
        for url in invalid_urls:
            with self.subTest(url=url):
                self.assert_rejected_before_asset(FEED.replace(expected, url) + SIGNATURE)


if __name__ == "__main__":
    unittest.main()
