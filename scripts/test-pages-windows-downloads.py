#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


def load_module():
    path = Path(__file__).with_name("prepare-pages-windows-downloads.py")
    spec = importlib.util.spec_from_file_location("windows_downloads", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


win = load_module()


class WindowsDownloadsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tag = "v26-11-23.110"
        self.payload = b"windows-portable-zip-bytes"
        self.digest = "sha256:" + hashlib.sha256(self.payload).hexdigest()
        self.release = {
            "tagName": self.tag,
            "assets": [
                {"name": "checksums.txt", "size": 120},
                {
                    "name": f"Remote_Buddy_Windows_{self.tag}_x64.zip",
                    "size": len(self.payload),
                    "digest": self.digest,
                    "url": f"https://github.com/zfdang/remote-buddy-windows/releases/download/{self.tag}/Remote_Buddy_Windows_{self.tag}_x64.zip",
                },
            ],
        }

    def test_select_windows_asset_chooses_exact_tag_match_and_rejects_oversized(self):
        tag, asset = win.select_windows_asset(self.release)
        self.assertEqual(tag, self.tag)
        self.assertEqual(asset["name"], f"Remote_Buddy_Windows_{self.tag}_x64.zip")

        with self.assertRaises(ValueError):
            win.select_windows_asset({"tagName": self.tag, "assets": [{"name": "other.txt", "size": 10}]})

        oversized = {
            "tagName": self.tag,
            "assets": [
                {
                    "name": f"Remote_Buddy_Windows_{self.tag}_x64.zip",
                    "size": win.MAX_WINDOWS_PACKAGE_BYTES + 1,
                }
            ],
        }
        with self.assertRaisesRegex(ValueError, "100 MB limit"):
            win.select_windows_asset(oversized)

    def test_verify_downloaded_asset_checks_size_and_digest(self):
        zip_path = self.root / f"Remote_Buddy_Windows_{self.tag}_x64.zip"
        zip_path.write_bytes(self.payload)
        asset = self.release["assets"][1]

        self.assertEqual(win.verify_downloaded_asset(zip_path, asset), len(self.payload))

        with self.assertRaisesRegex(ValueError, "Size mismatch"):
            win.verify_downloaded_asset(zip_path, {**asset, "size": len(self.payload) + 1})

        bad_digest = "sha256:" + ("0" * 64)
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            win.verify_downloaded_asset(zip_path, {**asset, "digest": bad_digest})

        oversized_path = self.root / "oversized.zip"
        with oversized_path.open("wb") as handle:
            handle.seek(win.MAX_WINDOWS_PACKAGE_BYTES)
            handle.write(b"\0")
        with self.assertRaisesRegex(ValueError, "100 MB limit"):
            win.verify_downloaded_asset(oversized_path, {"name": oversized_path.name})

    def test_publish_to_pages_replaces_stale_windows_zip_and_preserves_drivers_and_macos(self):
        pages_dir = self.root / "pages"
        downloads_dir = pages_dir / "downloads"
        drivers_dir = downloads_dir / "drivers"
        drivers_dir.mkdir(parents=True)

        driver_zip = drivers_dir / "VBCABLE_Driver_Pack46.zip"
        driver_zip.write_bytes(b"vbcable-pack46")
        macos_pkg = downloads_dir / "Remote_Buddy_v26-11-23.960_macOS_arm64.pkg"
        macos_pkg.write_bytes(b"macos-pkg")
        macos_manifest = downloads_dir / "latest.json"
        macos_manifest.write_text('{"tag":"v26-11-23.960"}\n', encoding="utf-8")
        stale_win_zip = downloads_dir / "Remote_Buddy_Windows_v26-11-22.001_x64.zip"
        stale_win_zip.write_bytes(b"stale-zip")

        staged_zip = self.root / f"Remote_Buddy_Windows_{self.tag}_x64.zip"
        staged_zip.write_bytes(self.payload)
        manifest = win.build_manifest(self.tag, staged_zip.name, len(self.payload))

        win.publish_to_pages(pages_dir, manifest, staged_zip)

        self.assertFalse(stale_win_zip.exists())
        self.assertEqual((downloads_dir / staged_zip.name).read_bytes(), self.payload)
        self.assertEqual(driver_zip.read_bytes(), b"vbcable-pack46")
        self.assertEqual(macos_pkg.read_bytes(), b"macos-pkg")
        self.assertTrue(macos_manifest.is_file())

        written = json.loads((downloads_dir / "windows-latest.json").read_text(encoding="utf-8"))
        self.assertEqual(written["tag"], self.tag)
        self.assertEqual(written["packages"]["x64"]["name"], staged_zip.name)
        self.assertEqual(written["packages"]["x64"]["size"], len(self.payload))

    def test_prepare_windows_downloads_fallback_and_strict_modes(self):
        pages_dir = self.root / "pages"
        live_zip = self.root / f"Remote_Buddy_Windows_{self.tag}_x64.zip"
        live_zip.write_bytes(self.payload)
        live_manifest = win.build_manifest(self.tag, live_zip.name, len(self.payload))

        with mock.patch.object(win, "fetch_release_metadata", side_effect=RuntimeError("gh down")), \
             mock.patch.object(win, "stage_from_live_mirror", return_value=(live_manifest, live_zip)):
            ok = win.prepare_windows_downloads(pages_dir, strict=False)
            self.assertTrue(ok)
            self.assertTrue((pages_dir / "downloads" / live_zip.name).is_file())
            self.assertTrue((pages_dir / "downloads" / "windows-latest.json").is_file())

        with mock.patch.object(win, "fetch_release_metadata", side_effect=RuntimeError("gh down")), \
             mock.patch.object(win, "stage_from_live_mirror", side_effect=RuntimeError("live down")):
            self.assertFalse(win.prepare_windows_downloads(self.root / "pages2", strict=False))
            with self.assertRaises(RuntimeError):
                win.prepare_windows_downloads(self.root / "pages3", strict=True)


if __name__ == "__main__":
    unittest.main()
