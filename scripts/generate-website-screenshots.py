#!/usr/bin/env python3
"""Generate optimized screenshots for the Remote Buddy website."""
import os
from pathlib import Path
import subprocess
import tempfile
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
APP_PATH = ROOT / "dist/website-screenshots/Remote Buddy.app/Contents/MacOS/RemoteBuddy"
OUTPUT_DIR = ROOT / "pages/assets/screenshots"

SETTINGS_SECTIONS = [
    ("general", "general-1020x772.png", "general"),
    ("permissions", "permissions-1020x772.png", "permissions"),
    ("connection", "connection-1020x772.png", "connection"),
    ("mapping", "mapping-1020x772.png", "mapping"),
    ("commonPhrases", "commonPhrases-1020x772.png", "phrases"),
    ("integration", "integration-1020x772.png", "integration"),
    ("applicationIntegration", "applicationIntegration-1020x772.png", "application-integration"),
    ("about", "about-1020x772.png", "about"),
]

ONBOARDING_STEPS = [
    ("01-permissions.png", "wizard-permissions"),
    ("02-control-source.png", "wizard-source"),
    ("03-remote.png", "wizard-remote"),
    ("04-controls.png", "wizard-controls"),
    ("05-voice-trigger.png", "wizard-driver"),
    ("06-voice-tool.png", "wizard-tool"),
    ("07-voice-test.png", "wizard-test"),
]

def ensure_binary() -> Path:
    print("Building current sources with CONFIGURATION=debug...")
    env = os.environ.copy()
    env["CONFIGURATION"] = "debug"
    env["APP_BUNDLE_DESTINATION"] = str(APP_PATH.parents[2])
    if "DEVELOPER_DIR" not in env and Path("/Applications/Xcode.app/Contents/Developer").exists():
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    subprocess.run(["scripts/build-app.sh"], cwd=ROOT, env=env, check=True)
    return APP_PATH

def render_settings(bin_path: Path, language: str, output_tmp: Path, extra_env=None):
    env = os.environ.copy()
    env["REMOTE_BUDDY_SETTINGS_SCREENSHOT_DIR"] = str(output_tmp)
    env["REMOTE_BUDDY_SETTINGS_SCREENSHOT_REMOTE_CARDS"] = "1"
    env["REMOTE_BUDDY_SETTINGS_SCREENSHOT_CHROMECAST"] = "1"
    env["REMOTE_BUDDY_SETTINGS_SCREENSHOT_UP_TO_DATE"] = "1"
    env["REMOTE_BUDDY_SETTINGS_SCREENSHOT_LANGUAGE"] = language
    env["REMOTE_BUDDY_SETTINGS_SCREENSHOT_APPEARANCE"] = "light"
    env.update(extra_env or {})
    subprocess.run([str(bin_path)], cwd=ROOT, env=env, check=True)

def render_onboarding(bin_path: Path, language: str, output_tmp: Path):
    env = os.environ.copy()
    env["REMOTE_BUDDY_ONBOARDING_SCREENSHOT_DIR"] = str(output_tmp)
    env["REMOTE_BUDDY_ONBOARDING_SCREENSHOT_LANGUAGE"] = language
    env["REMOTE_BUDDY_ONBOARDING_SCREENSHOT_APPEARANCE"] = "light"
    env["REMOTE_BUDDY_ONBOARDING_SCREENSHOT_CONTROL_SOURCE"] = "chromecast_remote"
    env["REMOTE_BUDDY_ONBOARDING_SCREENSHOT_DEVICE"] = "chromecastG9N9N"
    subprocess.run([str(bin_path)], cwd=ROOT, env=env, check=True)

def optimize_png(src: Path, dst: Path):
    with Image.open(src) as img:
        img.save(dst, format="PNG", optimize=True)

def integration_variants():
    section = {"REMOTE_BUDDY_SETTINGS_SCREENSHOT_SECTION": "applicationIntegration"}
    return [
        ("permission-missing", dict(section, REMOTE_BUDDY_SETTINGS_SCREENSHOT_PERMISSIONS="missing")),
        ("preparing", dict(section, REMOTE_BUDDY_SETTINGS_SCREENSHOT_INTEGRATION_STATUS="preparing")),
        ("preserved", dict(section, REMOTE_BUDDY_SETTINGS_SCREENSHOT_INTEGRATION_STATUS="preserved")),
    ]

def main():
    bin_path = ensure_binary()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for lang_code, lang_suffix in [("zh-Hans", "zh"), ("en", "en")]:
        with tempfile.TemporaryDirectory() as tmp_settings_dir, \
             tempfile.TemporaryDirectory() as tmp_onboarding_dir:
            print(f"Rendering {lang_code} settings screenshots...")
            render_settings(bin_path, lang_code, Path(tmp_settings_dir))
            for _, raw_filename, target_id in SETTINGS_SECTIONS:
                source_file = Path(tmp_settings_dir) / raw_filename
                target_file = OUTPUT_DIR / f"{target_id}-{lang_suffix}.png"
                print(f"Optimizing {target_file.name}...")
                optimize_png(source_file, target_file)

            # Include all G9N9N media buttons and both connection cards in full.
            for section, height, cards in [("mapping", 980, "0"), ("connection", 860, "1")]:
                render_settings(bin_path, lang_code, Path(tmp_settings_dir), {
                    "REMOTE_BUDDY_SETTINGS_SCREENSHOT_SECTION": section,
                    "REMOTE_BUDDY_SETTINGS_SCREENSHOT_REMOTE_CARDS": cards,
                    "REMOTE_BUDDY_SETTINGS_SCREENSHOT_SIZE": f"1020x{height}",
                })
                optimize_png(Path(tmp_settings_dir) / f"{section}-1020x{height}.png",
                             OUTPUT_DIR / f"{section}-{lang_suffix}.png")

            for variant, overrides in integration_variants():
                render_settings(bin_path, lang_code, Path(tmp_settings_dir), overrides)
                optimize_png(Path(tmp_settings_dir) / "applicationIntegration-1020x772.png",
                             OUTPUT_DIR / f"application-integration-{variant}-{lang_suffix}.png")

            print(f"Rendering {lang_code} onboarding screenshots...")
            render_onboarding(bin_path, lang_code, Path(tmp_onboarding_dir))
            for raw_filename, target_id in ONBOARDING_STEPS:
                source_file = Path(tmp_onboarding_dir) / raw_filename
                target_file = OUTPUT_DIR / f"{target_id}-{lang_suffix}.png"
                print(f"Optimizing {target_file.name}...")
                optimize_png(source_file, target_file)

    print("Screenshots generation complete!")

if __name__ == "__main__":
    main()
