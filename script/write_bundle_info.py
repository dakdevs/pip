#!/usr/bin/env python3
"""Single source of bundle metadata for development and release packaging."""
import base64
import os
from pathlib import Path
import plistlib
import sys
from release_version import parse_tag


def bundle_info(version, channel, public_key):
    if channel not in {"development", "release"}:
        raise ValueError("PIP_UPDATE_CHANNEL must be development or release")
    if not parse_tag(version) or version.startswith("v"):
        if not (channel == "development" and version == "0.0.0"):
            raise ValueError("Release version must be YYYYMMDD.N")
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError("Sparkle public key must be 32 bytes")
    return {
        "CFBundleExecutable": "Pip", "CFBundleIdentifier": "com.pip.mac",
        "CFBundleName": "Pip", "CFBundleDisplayName": "Pip",
        "CFBundleVersion": version, "CFBundleShortVersionString": version,
        "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "26.0",
        "LSUIElement": True, "NSPrincipalClass": "NSApplication",
        "NSMicrophoneUsageDescription": "Pip uses your microphone while you hold the dictation shortcut.",
        "NSHighResolutionCapable": True, "PipUpdateChannel": channel,
        "SUFeedURL": "https://github.com/dakdevs/pip/releases/latest/download/appcast.xml",
        "SUPublicEDKey": public_key, "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True, "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": True, "SUAllowsAutomaticUpdates": True,
        "SUScheduledCheckInterval": 14400, "SUSendProfileInfo": False,
    }


if __name__ == "__main__":
    key = (Path(__file__).resolve().parent.parent / "config/sparkle-public-key.txt").read_text().strip()
    info = bundle_info(os.environ.get("PIP_VERSION", "0.0.0"), os.environ.get("PIP_UPDATE_CHANNEL", "development"), key)
    Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
