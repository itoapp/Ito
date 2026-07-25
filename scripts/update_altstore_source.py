#!/usr/bin/env python3
"""Create or update an AltStore/SideStore source for one Ito release channel."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

DEFAULT_BUNDLE_ID = "moe.itoapp.ito"

CHANNEL_METADATA = {
    "stable": {
        "source_name": "Ito",
        "source_identifier": "moe.itoapp.source",
        "source_subtitle": "Stable unsigned releases of Ito",
        "app_name": "Ito",
        "app_subtitle": "Stable release channel",
    },
    "beta": {
        "source_name": "Ito Beta",
        "source_identifier": "moe.itoapp.source.beta",
        "source_subtitle": "Beta and release-candidate builds of Ito",
        "app_name": "Ito Beta",
        "app_subtitle": "Beta and release-candidate channel",
    },
    "nightly": {
        "source_name": "Ito Nightly",
        "source_identifier": "moe.itoapp.source.nightly",
        "source_subtitle": "Automated nightly builds from main",
        "app_name": "Ito Nightly",
        "app_subtitle": "Unstable nightly channel",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--channel", required=True, choices=tuple(CHANNEL_METADATA))
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--size", required=True, type=int)
    parser.add_argument("--release-notes", default="")
    parser.add_argument("--max-versions", type=int, default=50)
    return parser.parse_args()


def default_source(source_url: str, source_filename: str, channel: str) -> dict[str, Any]:
    metadata = CHANNEL_METADATA[channel]
    return {
        "name": metadata["source_name"],
        "identifier": metadata["source_identifier"],
        "subtitle": metadata["source_subtitle"],
        "description": (
            "Ito IPAs built without an App Store signing identity. "
            "AltStore and SideStore re-sign downloads with the user's Apple account."
        ),
        "website": "https://github.com/itoapp/Ito",
        "sourceURL": f"{source_url}/{source_filename}",
        "iconURL": f"{source_url}/icon.png",
        "tintColor": "6C5CE7",
        "apps": [],
        "news": [],
    }


def main() -> int:
    args = parse_args()
    if args.max_versions < 1:
        raise SystemExit("--max-versions must be at least 1")

    args.file.parent.mkdir(parents=True, exist_ok=True)
    source_url = args.source_url.rstrip("/")
    source_filename = args.file.name
    metadata = CHANNEL_METADATA[args.channel]

    if args.file.exists():
        try:
            source: dict[str, Any] = json.loads(args.file.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Existing source is invalid JSON: {exc}") from exc
    else:
        source = default_source(source_url, source_filename, args.channel)

    icon_url = f"{source_url}/icon.png"
    source.update(
        {
            "name": metadata["source_name"],
            "identifier": metadata["source_identifier"],
            "subtitle": metadata["source_subtitle"],
            "sourceURL": f"{source_url}/{source_filename}",
            "iconURL": icon_url,
        }
    )
    apps = source.setdefault("apps", [])

    app = next(
        (candidate for candidate in apps if candidate.get("bundleIdentifier") == args.bundle_id),
        None,
    )
    if app is None:
        app = {
            "name": metadata["app_name"],
            "bundleIdentifier": args.bundle_id,
            "developerName": "Ito contributors",
            "subtitle": metadata["app_subtitle"],
            "localizedDescription": (
                "An unsigned Ito build for installation through AltStore, SideStore, "
                "TrollStore-compatible setups, or jailbreak tooling."
            ),
            "iconURL": icon_url,
            "tintColor": "6C5CE7",
            "category": "entertainment",
            "appPermissions": {"entitlements": [], "privacy": {}},
            "versions": [],
        }
        apps.append(app)

    app["name"] = metadata["app_name"]
    app["subtitle"] = metadata["app_subtitle"]
    app["iconURL"] = icon_url

    version_entry = {
        "version": args.version,
        "buildVersion": str(args.build_version),
        "date": args.date,
        "downloadURL": args.download_url,
        "size": args.size,
        "localizedDescription": args.release_notes,
        "minOSVersion": "15.4",
    }

    versions = [
        item
        for item in app.setdefault("versions", [])
        if not (
            str(item.get("version")) == args.version
            and str(item.get("buildVersion")) == str(args.build_version)
        )
    ]
    versions.insert(0, version_entry)
    app["versions"] = versions[: args.max_versions]

    latest = app["versions"][0]
    for key in ("version", "buildVersion", "date", "downloadURL", "size", "minOSVersion"):
        app[key] = latest[key]
    app["versionDescription"] = latest.get("localizedDescription", "")

    args.file.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
