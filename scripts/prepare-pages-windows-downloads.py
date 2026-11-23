#!/usr/bin/env python3
"""Mirror the latest Remote Buddy for Windows release zip into pages/downloads/."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

DEFAULT_WINDOWS_REPO = "zfdang/remote-buddy-windows"
DEFAULT_LIVE_BASE_URL = "https://remote.zfdang.com/downloads"
MAX_WINDOWS_PACKAGE_BYTES = 100 * 1024 * 1024
ASSET_NAME_RE = re.compile(r"^Remote_Buddy_Windows_.*_x64\.zip$")
SHA256_DIGEST_RE = re.compile(r"^sha256:([0-9a-fA-F]{64})$")


def _validate_safe_basename(name: str) -> None:
    if (
        not name
        or name in (".", "..")
        or "/" in name
        or "\\" in name
        or Path(name).name != name
    ):
        raise ValueError(f"Unsafe asset filename: {name!r}")


def select_windows_asset(release: dict) -> tuple[str, dict]:
    """Select the Windows x64 zip asset from release metadata."""
    tag = (release.get("tagName") or "").strip()
    if not tag or "/" in tag or "\\" in tag or tag in (".", ".."):
        raise ValueError(f"Invalid or missing release tagName: {tag!r}")

    raw_assets = release.get("assets") or []
    assets = [
        asset
        for asset in raw_assets
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    ]

    exact_name = f"Remote_Buddy_Windows_{tag}_x64.zip"
    selected = next((a for a in assets if a["name"] == exact_name), None)
    if selected is None:
        selected = next((a for a in assets if ASSET_NAME_RE.match(a["name"])), None)
    if selected is None:
        raise ValueError(f"Release {tag} has no matching Windows x64 zip asset")

    _validate_safe_basename(selected["name"])
    if selected.get("size") is not None:
        size = int(selected["size"])
        if size <= 0 or size > MAX_WINDOWS_PACKAGE_BYTES:
            raise ValueError(
                f"Windows asset {selected['name']} size {size} exceeds 100 MB limit"
            )

    return tag, selected


def verify_downloaded_asset(path: Path, asset: dict) -> int:
    """Verify file existence, size limits, expected size, and optional SHA-256 digest."""
    if not path.is_file():
        raise FileNotFoundError(f"Missing downloaded Windows package: {path}")

    actual_size = path.stat().st_size
    if actual_size <= 0 or actual_size > MAX_WINDOWS_PACKAGE_BYTES:
        raise ValueError(
            f"Windows package {path.name} size {actual_size} exceeds 100 MB limit"
        )

    if asset.get("size") is not None:
        expected_size = int(asset["size"])
        if actual_size != expected_size:
            raise ValueError(
                f"Size mismatch for {path.name}: got {actual_size}, expected {expected_size}"
            )

    digest = asset.get("digest")
    if digest:
        if not isinstance(digest, str):
            raise ValueError(f"Invalid digest type for {path.name}: {digest!r}")
        match = SHA256_DIGEST_RE.fullmatch(digest.strip())
        if not match:
            raise ValueError(f"Unsupported digest format for {path.name}: {digest!r}")
        expected_hex = match.group(1).lower()
        hasher = hashlib.sha256()
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(65536)
                if not chunk:
                    break
                hasher.update(chunk)
        actual_hex = hasher.hexdigest()
        if actual_hex != expected_hex:
            raise ValueError(
                f"SHA-256 mismatch for {path.name}: got {actual_hex}, expected {expected_hex}"
            )

    return actual_size


def build_manifest(
    tag: str,
    asset_name: str,
    size: int,
    repo: str = DEFAULT_WINDOWS_REPO,
) -> dict:
    """Build pages/downloads/windows-latest.json manifest payload."""
    _validate_safe_basename(asset_name)
    return {
        "tag": tag,
        "releasesUrl": f"https://github.com/{repo}/releases/tag/{tag}",
        "packages": {
            "x64": {
                "name": asset_name,
                "size": int(size),
            }
        },
    }


def fetch_release_metadata(repo: str) -> dict:
    """Fetch latest release metadata using gh CLI with GitHub REST API fallback."""
    try:
        proc = subprocess.run(
            ["gh", "release", "view", "--repo", repo, "--json", "tagName,assets"],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )
        return json.loads(proc.stdout)
    except (FileNotFoundError, subprocess.SubprocessError, json.JSONDecodeError) as gh_err:
        api_url = f"https://api.github.com/repos/{repo}/releases/latest"
        headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "remote-buddy-pages",
        }
        token = os.environ.get("GH_TOKEN", "").strip()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(api_url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, json.JSONDecodeError, OSError) as api_err:
            raise RuntimeError(
                f"Failed to fetch release metadata for {repo}: gh={gh_err}; api={api_err}"
            ) from api_err

        normalized_assets = []
        for item in raw.get("assets") or []:
            if not isinstance(item, dict):
                continue
            entry = {
                "name": item.get("name"),
                "size": item.get("size"),
                "url": item.get("browser_download_url") or item.get("url"),
            }
            if item.get("digest"):
                entry["digest"] = item["digest"]
            normalized_assets.append(entry)

        return {
            "tagName": raw.get("tag_name") or raw.get("tagName"),
            "assets": normalized_assets,
        }


def download_url_to_file(
    url: str,
    dest_path: Path,
    max_bytes: int = MAX_WINDOWS_PACKAGE_BYTES,
    token: str | None = None,
) -> None:
    """Stream a URL to dest_path while enforcing max_bytes."""
    headers = {"User-Agent": "remote-buddy-pages"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    try:
        with urllib.request.urlopen(req, timeout=180) as resp, dest_path.open("wb") as out:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > max_bytes:
                    raise ValueError(
                        f"Download from {url} exceeded {max_bytes} bytes limit"
                    )
                out.write(chunk)
    except Exception:
        if dest_path.exists():
            dest_path.unlink()
        raise


def download_release_asset(repo: str, tag: str, asset: dict, dest_dir: Path) -> Path:
    """Download a GitHub Release asset via gh CLI with HTTPS fallback."""
    name = asset["name"]
    _validate_safe_basename(name)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest_path = dest_dir / name

    try:
        subprocess.run(
            [
                "gh",
                "release",
                "download",
                tag,
                "--repo",
                repo,
                "--pattern",
                name,
                "--dir",
                str(dest_dir),
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=180,
        )
        if dest_path.is_file():
            return dest_path
    except (FileNotFoundError, subprocess.SubprocessError):
        if dest_path.exists():
            dest_path.unlink()

    url = asset.get("url") or f"https://github.com/{repo}/releases/download/{tag}/{name}"
    download_url_to_file(url, dest_path, max_bytes=MAX_WINDOWS_PACKAGE_BYTES)
    return dest_path


def stage_from_live_mirror(
    live_base_url: str,
    dest_dir: Path,
    repo: str = DEFAULT_WINDOWS_REPO,
) -> tuple[dict, Path]:
    """Download and verify existing Windows release files from the live Pages mirror."""
    base = live_base_url.rstrip("/")
    dest_dir.mkdir(parents=True, exist_ok=True)
    manifest_tmp = dest_dir / "windows-latest.json"
    download_url_to_file(f"{base}/windows-latest.json", manifest_tmp, max_bytes=1024 * 1024)

    manifest = json.loads(manifest_tmp.read_text(encoding="utf-8"))
    tag = (manifest.get("tag") or "").strip()
    if not tag:
        raise ValueError("Live Windows manifest is missing tag")

    pkg = (manifest.get("packages") or {}).get("x64") or {}
    name = pkg.get("name") or ""
    _validate_safe_basename(name)
    if not ASSET_NAME_RE.match(name):
        raise ValueError(f"Unexpected Windows zip name in live manifest: {name!r}")

    if pkg.get("size") is not None:
        size = int(pkg["size"])
        if size <= 0 or size > MAX_WINDOWS_PACKAGE_BYTES:
            raise ValueError(f"Live manifest Windows asset size {size} exceeds 100 MB limit")

    zip_path = dest_dir / name
    download_url_to_file(f"{base}/{name}", zip_path, max_bytes=MAX_WINDOWS_PACKAGE_BYTES)
    actual_size = verify_downloaded_asset(zip_path, pkg)
    normalized = build_manifest(tag, name, actual_size, repo=repo)
    return normalized, zip_path


def publish_to_pages(pages_dir: Path, manifest: dict, zip_path: Path) -> None:
    """Publish Windows zip and windows-latest.json without touching macOS or driver files."""
    downloads_dir = pages_dir / "downloads"
    downloads_dir.mkdir(parents=True, exist_ok=True)

    asset_name = manifest["packages"]["x64"]["name"]
    _validate_safe_basename(asset_name)
    if not ASSET_NAME_RE.match(asset_name):
        raise ValueError(f"Refusing to publish unexpected filename: {asset_name!r}")

    for existing in list(downloads_dir.iterdir()):
        if not existing.is_file():
            continue
        if existing.name == "windows-latest.json" or ASSET_NAME_RE.match(existing.name):
            existing.unlink()

    shutil.copy2(zip_path, downloads_dir / asset_name)
    manifest_path = downloads_dir / "windows-latest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def prepare_windows_downloads(
    pages_dir: Path,
    repo: str = DEFAULT_WINDOWS_REPO,
    live_base_url: str = DEFAULT_LIVE_BASE_URL,
    strict: bool = False,
) -> bool:
    """Mirror latest Windows release into pages/downloads/, falling back gracefully."""
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        try:
            release = fetch_release_metadata(repo)
            tag, asset = select_windows_asset(release)
            zip_path = download_release_asset(repo, tag, asset, work / "github")
            actual_size = verify_downloaded_asset(zip_path, asset)
            manifest = build_manifest(tag, asset["name"], actual_size, repo=repo)
            publish_to_pages(pages_dir, manifest, zip_path)
            print(
                f"Mirrored Windows release {tag} ({asset['name']}, {actual_size} bytes) into {pages_dir / 'downloads'}."
            )
            return True
        except Exception as github_err:
            print(
                f"Warning: Could not mirror Windows release from GitHub ({github_err}); trying live fallback.",
                file=sys.stderr,
            )

        try:
            manifest, zip_path = stage_from_live_mirror(live_base_url, work / "live", repo=repo)
            publish_to_pages(pages_dir, manifest, zip_path)
            print(
                f"Recovered Windows release {manifest['tag']} from live Pages mirror.",
                file=sys.stderr,
            )
            return True
        except Exception as live_err:
            if strict:
                raise
            print(
                f"Warning: Windows release mirror skipped (no valid GitHub or live mirror source: {live_err}).",
                file=sys.stderr,
            )
            return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--pages-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "pages",
    )
    parser.add_argument("--repo", default=DEFAULT_WINDOWS_REPO)
    parser.add_argument("--live-base-url", default=DEFAULT_LIVE_BASE_URL)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    prepare_windows_downloads(
        args.pages_dir,
        repo=args.repo,
        live_base_url=args.live_base_url,
        strict=args.strict,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
