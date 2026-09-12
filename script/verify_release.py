#!/usr/bin/env python3
"""Reject mismatched bundle/feed/archive metadata before publishing."""
import base64
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def verify_release(directory, version):
    directory = Path(directory)
    bundle = plistlib.loads((directory / "Pip.app/Contents/Info.plist").read_bytes())
    assert bundle["CFBundleVersion"] == version
    assert bundle["CFBundleShortVersionString"] == version
    assert bundle["PipUpdateChannel"] == "release"
    assert bundle["SURequireSignedFeed"] and bundle["SUVerifyUpdateBeforeExtraction"]
    expected_key = (Path(__file__).resolve().parent.parent / "config/sparkle-public-key.txt").read_text().strip()
    assert bundle["SUPublicEDKey"] == expected_key
    item = ET.parse(directory / "appcast.xml").getroot().find("channel/item")
    assert item is not None, "Missing appcast item"
    assert item.findtext(SPARKLE + "version") == version
    enclosure = item.find("enclosure")
    assert enclosure is not None
    archive = directory / f"Pip-{version}-arm64.zip"
    assert enclosure.attrib["url"] == f"https://github.com/dakdevs/pip/releases/download/{version}/{archive.name}"
    assert int(enclosure.attrib["length"]) == archive.stat().st_size
    assert len(base64.b64decode(enclosure.attrib[SPARKLE + "edSignature"], validate=True)) == 64
    assert item.findtext(SPARKLE + "minimumSystemVersion") == "26.0"
    print("Release bundle, feed, signature metadata, and archive match.")


if __name__ == "__main__":
    verify_release(sys.argv[1], sys.argv[2])
