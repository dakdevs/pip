import base64
import contextlib
import io
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_release import verify_release, SPARKLE
from write_bundle_info import bundle_info

class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.version = '20260912.1'
        key = (Path(__file__).resolve().parents[2] / 'config/sparkle-public-key.txt').read_text().strip()
        self.info = bundle_info(self.version, 'release', key)
        self.plist = self.root / 'Pip.app/Contents/Info.plist'
        self.plist.parent.mkdir(parents=True)
        self.plist.write_bytes(plistlib.dumps(self.info))
        self.archive = self.root / f'Pip-{self.version}-arm64.zip'
        self.archive.write_bytes(b'archive fixture')
        root = ET.Element('rss'); channel = ET.SubElement(root, 'channel'); self.item = ET.SubElement(channel, 'item')
        ET.SubElement(self.item, SPARKLE + 'version').text = self.version
        ET.SubElement(self.item, SPARKLE + 'minimumSystemVersion').text = '26.0'
        self.enclosure = ET.SubElement(self.item, 'enclosure', {
            'url': f'https://github.com/dakdevs/pip/releases/download/{self.version}/{self.archive.name}',
            'length': str(self.archive.stat().st_size),
            SPARKLE + 'edSignature': base64.b64encode(bytes(64)).decode(),
        })
        self.feed = ET.ElementTree(root)
        self.save_feed()

    def tearDown(self): self.temp.cleanup()
    def save_feed(self): self.feed.write(self.root / 'appcast.xml')
    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()): verify_release(self.root, self.version)

    def test_matching_metadata_passes(self): self.verify()

    def test_off_repository_download_is_rejected(self):
        self.enclosure.set('url', 'https://example.org/Pip.zip'); self.save_feed()
        with self.assertRaises(AssertionError): self.verify()

    def test_changed_archive_size_is_rejected(self):
        self.archive.write_bytes(b'truncated')
        with self.assertRaises(AssertionError): self.verify()

    def test_bundle_version_drift_is_rejected(self):
        self.info['CFBundleVersion'] = '20260912.2'
        self.plist.write_bytes(plistlib.dumps(self.info))
        with self.assertRaises(AssertionError): self.verify()

    def test_missing_archive_signature_is_rejected(self):
        del self.enclosure.attrib[SPARKLE + 'edSignature']; self.save_feed()
        with self.assertRaises(KeyError): self.verify()
