#!/usr/bin/env python3
"""Verify Sparkle appcast feeds and mirrored installer packages for Pages."""
import argparse
import base64
import json
import hashlib
import re
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
PAGES_DOWNLOADS_BASE = 'https://remote.zfdang.com/downloads'
GITHUB_RELEASE_BASE = 'https://github.com/zfdang/remote-buddy/releases/download'
MAX_PAGES_FILE_BYTES = 25 * 1024 * 1024


def _release_packages(release):
    tag = release['tagName']
    assets = {asset['name']: asset for asset in release.get('assets', [])}
    uninstaller_name = f'Remote_Buddy_Uninstaller_{tag}_macOS_universal.pkg'
    installers = {
        arch: f'Remote_Buddy_{tag}_macOS_{arch}.pkg'
        for arch in ('arm64', 'intel')
    }
    return tag, assets, installers, (uninstaller_name if uninstaller_name in assets else None)


def write_latest_manifest(directory, release):
    """Write downloads/latest.json from verified release metadata and staged files."""
    tag, assets, installers, uninstaller_name = _release_packages(release)
    downloads_dir = directory / 'downloads'
    downloads_dir.mkdir(parents=True, exist_ok=True)
    packages = {}
    for key, filename in [*installers.items(), *(([('uninstaller', uninstaller_name)]) if uninstaller_name else [])]:
        pkg_path = downloads_dir / filename
        size = pkg_path.stat().st_size if pkg_path.exists() else assets.get(filename, {}).get('size')
        entry = {'name': filename}
        if size is not None:
            entry['size'] = int(size)
        packages[key] = entry
    manifest = {
        'tag': tag,
        'releasesUrl': f'https://github.com/zfdang/remote-buddy/releases/tag/{tag}',
        'packages': packages,
    }
    manifest_path = downloads_dir / 'latest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return manifest_path


def rewrite_github_release_enclosures(directory, release):
    """Migrate a trusted GitHub Release appcast enclosure URL to the Pages mirror."""
    tag, _, installers, _ = _release_packages(release)
    for architecture, package in installers.items():
        path = directory / f'appcast-{architecture}.xml'
        if not path.exists():
            continue
        tree = ET.parse(path)
        enclosure = tree.find('channel/item/enclosure')
        if enclosure is None:
            continue
        github_url = f'{GITHUB_RELEASE_BASE}/{tag}/{package}'
        if enclosure.get('url') == github_url:
            enclosure.set('url', f'{PAGES_DOWNLOADS_BASE}/{package}')
            tree.write(path, encoding='utf-8', xml_declaration=True)


def verify_published_assets(directory, release):
    """Accept only a complete published feed/package set, including the uninstaller."""
    directory = Path(directory)
    tag, assets, installers, _ = _release_packages(release)
    expected = [*installers.values(), f'Remote_Buddy_Uninstaller_{tag}_macOS_universal.pkg',
                'appcast-arm64.xml', 'appcast-intel.xml']
    for filename in expected:
        asset = assets.get(filename)
        if asset is None:
            raise ValueError(f'Incomplete published release: missing {filename}')
        path = directory / filename
        if not path.is_file():
            raise FileNotFoundError(f'Missing downloaded published asset: {filename}')
        if path.stat().st_size != asset.get('size'):
            raise ValueError(f'Published asset size mismatch: {filename}')
        digest = asset.get('digest', '')
        if not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
            raise ValueError(f'Missing SHA-256 digest for published asset: {filename}')
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != 'sha256:' + actual:
            raise ValueError(f'Published asset digest mismatch: {filename}')


def verify(directory, release, *, require_packages=False):
    directory = Path(directory)
    tag, assets, installers, uninstaller_name = _release_packages(release)
    downloads_dir = directory / 'downloads'
    check_packages = require_packages or downloads_dir.exists()
    enclosure_lengths = {}

    for architecture, package in installers.items():
        path = directory / f'appcast-{architecture}.xml'
        tree = ET.parse(path)
        item = tree.find('channel/item')
        if item is None:
            raise ValueError(f'Missing channel/item in {path.name}')
        short_version = item.findtext(f'{{{SPARKLE}}}shortVersionString')
        if short_version != tag:
            raise ValueError(f'{path.name} shortVersionString {short_version!r} does not match release {tag!r}')
        version = item.findtext(f'{{{SPARKLE}}}version', '')
        tag_suffix = tag.rsplit('.', 1)[-1]
        if (
            not version.isdigit()
            or int(version) <= 0
            or not tag_suffix.isdigit()
            or int(version) % 1000 != int(tag_suffix)
        ):
            raise ValueError('Mismatched build version')
        if architecture == 'arm64' and item.findtext(f'{{{SPARKLE}}}hardwareRequirements') != 'arm64':
            raise ValueError('Missing Apple Silicon requirement')
        enclosure = item.find('enclosure')
        expected_url = f'{PAGES_DOWNLOADS_BASE}/{package}'
        if enclosure is None or enclosure.get('url') != expected_url:
            raise ValueError(f'{path.name} enclosure URL must match {expected_url}')
        if package not in assets:
            raise ValueError(f'Release metadata is missing expected asset {package}')
        asset = assets[package]
        if 'size' in asset:
            if int(asset['size']) > MAX_PAGES_FILE_BYTES:
                raise ValueError(
                    f'Mirrored package {package} exceeds GitHub Pages 25 MB limit ({asset["size"]} bytes)'
                )
            expected_length = str(asset['size'])
            if enclosure.get('length') != expected_length:
                raise ValueError(
                    f"Enclosure length mismatch: feed has {enclosure.get('length')}, release asset has {expected_length}"
                )
        enclosure_lengths[package] = enclosure.get('length')
        if len(base64.b64decode(enclosure.get(f'{{{SPARKLE}}}edSignature', ''), validate=True)) != 64:
            raise ValueError(f'{path.name} is missing a valid 64-byte Ed25519 signature')

    if check_packages:
        if not downloads_dir.is_dir():
            raise FileNotFoundError(f'Missing Pages downloads directory: {downloads_dir}')
        expected_files = list(installers.values())
        if uninstaller_name:
            expected_files.append(uninstaller_name)
        for filename in expected_files:
            pkg_path = downloads_dir / filename
            if not pkg_path.is_file():
                raise FileNotFoundError(f'Missing mirrored package in Pages downloads: {pkg_path.name}')
            actual_size = pkg_path.stat().st_size
            if actual_size > MAX_PAGES_FILE_BYTES:
                raise ValueError(
                    f'Mirrored package {filename} exceeds GitHub Pages 25 MB limit ({actual_size} bytes)'
                )
            asset = assets.get(filename, {})
            if 'size' in asset and actual_size != asset['size']:
                raise ValueError(
                    f'Mirrored package size mismatch for {filename}: got {actual_size}, release has {asset["size"]}'
                )
            if filename in enclosure_lengths and enclosure_lengths[filename] != str(actual_size):
                raise ValueError(
                    f'Mirrored package size mismatch vs appcast for {filename}: got {actual_size}, feed has {enclosure_lengths[filename]}'
                )
        manifest_path = downloads_dir / 'latest.json'
        if not manifest_path.is_file():
            raise FileNotFoundError('Missing downloads/latest.json manifest')
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        if manifest.get('tag') != tag:
            raise ValueError(f'Manifest tag {manifest.get("tag")!r} does not match release {tag!r}')
        manifest_packages = manifest.get('packages') or {}
        for key, filename in [*installers.items(), *(([('uninstaller', uninstaller_name)]) if uninstaller_name else [])]:
            entry = manifest_packages.get(key) or {}
            if entry.get('name') != filename:
                raise ValueError(f'Manifest package {key!r} mismatch: expected {filename!r}, got {entry.get("name")!r}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('release_json', type=Path)
    parser.add_argument('--require-packages', action='store_true')
    parser.add_argument('--published-assets', action='store_true')
    parser.add_argument('--write-manifest', action='store_true')
    parser.add_argument('--rewrite-github-enclosures', action='store_true')
    args = parser.parse_args()
    release = json.loads(args.release_json.read_text(encoding='utf-8'))
    if args.rewrite_github_enclosures:
        rewrite_github_release_enclosures(args.directory, release)
    if args.write_manifest:
        write_latest_manifest(args.directory, release)
        return
    if args.published_assets:
        verify_published_assets(args.directory, release)
    verify(args.directory, release, require_packages=args.require_packages)


if __name__ == '__main__':
    main()
