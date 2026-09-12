import base64
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from write_bundle_info import bundle_info

class BundleInfoTests(unittest.TestCase):
    key = base64.b64encode(bytes(32)).decode()

    def test_release_uses_same_date_version_and_requires_signed_archives_and_feeds(self):
        info = bundle_info('20260912.10', 'release', self.key)
        self.assertEqual(info['CFBundleVersion'], '20260912.10')
        self.assertEqual(info['CFBundleShortVersionString'], '20260912.10')
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertEqual(info['SUFeedURL'], 'https://github.com/dakdevs/pip/releases/latest/download/appcast.xml')

    def test_invalid_release_metadata_is_rejected(self):
        for version in ['0.0.0', '20260912.0', '20260230.1', 'v20260912.1']:
            with self.assertRaises(ValueError): bundle_info(version, 'release', self.key)
        with self.assertRaises(ValueError): bundle_info('20260912.1', 'nightly', self.key)
        with self.assertRaises(ValueError): bundle_info('20260912.1', 'release', 'wrong-key')

    def test_development_build_is_identified_separately(self):
        self.assertEqual(bundle_info('0.0.0', 'development', self.key)['PipUpdateChannel'], 'development')
