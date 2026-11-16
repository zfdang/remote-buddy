#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/candidate"
gh release view --json tagName,assets > "$work/release.json"
tag="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["tagName"])' "$work/release.json")"
uninstaller_asset="$(python3 -c '
import json, sys
rel = json.load(open(sys.argv[1]))
tag = rel["tagName"]
name = f"Remote_Buddy_Uninstaller_{tag}_macOS_universal.pkg"
print(name if any(a["name"] == name for a in rel.get("assets", [])) else "")
' "$work/release.json")"

finalize_candidate() {
    mkdir -p "$work/candidate/downloads"
    shopt -s nullglob
    for pkg in "$work/candidate"/*.pkg; do
        mv -f "$pkg" "$work/candidate/downloads/"
    done
    shopt -u nullglob
    python3 "$root/scripts/verify-pages-update-feeds.py" \
        --write-manifest "$work/candidate" "$work/release.json" >/dev/null
    python3 "$root/scripts/verify-pages-update-feeds.py" \
        --require-packages "$work/candidate" "$work/release.json"
}

valid_candidate=false

# 1. Try current workflow run artifact first (used when triggered via workflow_run).
if [[ -n "${PAGES_UPDATE_RUN_ID:-}" ]]; then
    if gh run download "$PAGES_UPDATE_RUN_ID" --name website-update-feeds --dir "$work/candidate" >/dev/null 2>"$work/error.log"; then
        if finalize_candidate 2>>"$work/error.log"; then
            valid_candidate=true
        else
            echo "Warning: Pages update artifact failed validation, trying fallback sources." >&2
            cat "$work/error.log" >&2 || true
        fi
    else
        echo "Warning: Failed to download website-update-feeds artifact for run $PAGES_UPDATE_RUN_ID, trying fallback sources." >&2
    fi
fi

# 2. Try release assets directly when triggered standalone or artifact failed.
if [[ "$valid_candidate" == false ]]; then
    rm -rf "$work/candidate" && mkdir -p "$work/candidate/downloads"
    if gh release download "$tag" --pattern "appcast-*.xml" --dir "$work/candidate" >/dev/null 2>"$work/error.log" && \
       gh release download "$tag" --pattern "*.pkg" --dir "$work/candidate/downloads" >/dev/null 2>>"$work/error.log"; then
        python3 "$root/scripts/verify-pages-update-feeds.py" \
            --rewrite-github-enclosures "$work/candidate" "$work/release.json" --write-manifest 2>>"$work/error.log" || true
        if finalize_candidate 2>>"$work/error.log"; then
            valid_candidate=true
        else
            echo "Warning: Release asset candidate failed validation, trying fallback sources." >&2
        fi
    fi
fi

# 3. Try recent successful release workflow runs.
if [[ "$valid_candidate" == false ]]; then
    recent_runs=$(gh run list --workflow release.yml --status success --branch main --limit 3 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)
    for candidate_run in $recent_runs; do
        [[ "$candidate_run" == "${PAGES_UPDATE_RUN_ID:-}" ]] && continue
        rm -rf "$work/candidate" && mkdir -p "$work/candidate"
        if gh run download "$candidate_run" --name website-update-feeds --dir "$work/candidate" >/dev/null 2>"$work/error.log"; then
            if finalize_candidate 2>>"$work/error.log"; then
                echo "Recovered update feeds and packages from recent workflow run $candidate_run." >&2
                valid_candidate=true
                break
            fi
        fi
    done
fi

# 4. Try prebuilt local feeds & packages if already prepared in pages/.
if [[ "$valid_candidate" == false && -f "$root/pages/appcast-arm64.xml" && -f "$root/pages/appcast-intel.xml" ]]; then
    rm -rf "$work/candidate" && mkdir -p "$work/candidate/downloads"
    cp "$root/pages/appcast-"*.xml "$work/candidate/" 2>/dev/null || true
    cp "$root/pages/downloads/"*.pkg "$work/candidate/downloads/" 2>/dev/null || true
    if finalize_candidate 2>>"$work/error.log"; then
        echo "Using validated prebuilt update feeds and packages from pages/." >&2
        valid_candidate=true
    fi
fi

# 5. Final fallback to currently deployed live feeds & packages on remote.zfdang.com.
if [[ "$valid_candidate" == false ]]; then
    rm -rf "$work/candidate" && mkdir -p "$work/candidate/downloads"
    for arch in arm64 intel; do
        curl -fsSL "https://remote.zfdang.com/appcast-$arch.xml" -o "$work/candidate/appcast-$arch.xml"
        pkg_name="Remote_Buddy_${tag}_macOS_${arch}.pkg"
        curl -fsSL "https://remote.zfdang.com/downloads/$pkg_name" -o "$work/candidate/downloads/$pkg_name"
    done
    if [[ -n "$uninstaller_asset" ]]; then
        curl -fsSL "https://remote.zfdang.com/downloads/$uninstaller_asset" -o "$work/candidate/downloads/$uninstaller_asset"
    fi
    finalize_candidate
fi

mkdir -p "$root/pages/downloads"
rm -f "$root/pages/downloads/"*.pkg "$root/pages/downloads/latest.json"
cp "$work/candidate/"appcast-*.xml "$root/pages/"
cp "$work/candidate/downloads/"*.pkg "$root/pages/downloads/"
cp "$work/candidate/downloads/latest.json" "$root/pages/downloads/latest.json"
