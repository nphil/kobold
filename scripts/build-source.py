#!/usr/bin/env python3
"""Builds an AltStore-compatible source manifest from this repo's GitHub releases.

Feather (like AltStore and SideStore) subscribes to a source: a JSON document
listing available app versions and where to download them. Publishing one means
the phone can be pointed at a single permanent URL once, and every later release
shows up as an update instead of a manual IPA download.

Reads the GitHub releases API payload on stdin, writes the manifest to stdout:

    gh api "repos/$REPO/releases?per_page=100" | scripts/build-source.py > source.json

Only releases carrying an .ipa asset become versions. Until the app target
exists there are none, so the manifest is emitted with an empty app list — a
valid, subscribable source that simply has nothing to install yet. That is
deliberate: the URL is permanent once added to Feather, so it needs to exist and
stay stable from the beginning rather than being minted later.
"""

from __future__ import annotations

import json
import re
import sys

OWNER = "nphil"
REPO = "kobold"
BUNDLE_ID = "com.nphil.kobold"

RAW = f"https://raw.githubusercontent.com/{OWNER}/{REPO}/main"
ICON_URL = f"{RAW}/Design/kobold-icon-512.png"
WEBSITE = f"https://github.com/{OWNER}/{REPO}"

# Cobalt: the accent the icon and design tokens are built around.
TINT = "#3B7DF7"
MIN_OS = "17.0"

SUBTITLE = "A clean, native OBD-II dashboard"
DESCRIPTION = (
    "Kobold reads your car's live telemetry over a Bluetooth OBD-II adapter and "
    "renders it as a clean, fast instrument cluster — gauges, graphs and trip "
    "logging, built natively for iOS.\n\n"
    "Vehicles and adapters are data rather than hard-coded: standard OBD-II works "
    "on any car, with manufacturer-specific sensors added per vehicle profile."
)

SEMVER = re.compile(r"^v?(\d+\.\d+\.\d+)$")


def version_from_tag(tag: str) -> str | None:
    """Extracts a semantic version from a tag, ignoring anything non-conforming."""
    match = SEMVER.match(tag.strip())
    return match.group(1) if match else None


def build_versions(releases: list[dict]) -> list[dict]:
    versions: list[dict] = []

    for release in releases:
        if release.get("draft"):
            continue

        version = version_from_tag(release.get("tag_name", ""))
        if version is None:
            continue

        ipa = next(
            (
                asset
                for asset in release.get("assets", [])
                if asset.get("name", "").lower().endswith(".ipa")
            ),
            None,
        )
        if ipa is None:
            # A release with no IPA is real, but there is nothing to install from
            # it; listing it would show Feather an update it cannot fetch.
            continue

        published = (release.get("published_at") or "")[:10]

        versions.append(
            {
                "version": version,
                "date": published,
                "localizedDescription": (release.get("body") or "").strip(),
                "downloadURL": ipa.get("browser_download_url", ""),
                "size": ipa.get("size", 0),
                "minOSVersion": MIN_OS,
            }
        )

    # Newest first: clients treat the leading entry as the current version.
    versions.sort(key=lambda v: [int(p) for p in v["version"].split(".")], reverse=True)
    return versions


def build_source(releases: list[dict]) -> dict:
    versions = build_versions(releases)

    apps = []
    if versions:
        apps.append(
            {
                "name": "Kobold",
                "bundleIdentifier": BUNDLE_ID,
                "developerName": OWNER,
                "subtitle": SUBTITLE,
                "localizedDescription": DESCRIPTION,
                "iconURL": ICON_URL,
                "tintColor": TINT,
                "category": "utilities",
                "screenshots": [],
                "versions": versions,
            }
        )

    return {
        "name": "Kobold",
        "identifier": BUNDLE_ID,
        "subtitle": SUBTITLE,
        "description": DESCRIPTION,
        "iconURL": ICON_URL,
        "website": WEBSITE,
        "tintColor": TINT,
        "apps": apps,
        "news": [],
    }


def main() -> int:
    try:
        releases = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        print(f"could not parse releases JSON: {error}", file=sys.stderr)
        return 1

    if not isinstance(releases, list):
        print("expected a JSON array of releases", file=sys.stderr)
        return 1

    json.dump(build_source(releases), sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
