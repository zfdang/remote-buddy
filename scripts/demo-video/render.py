"""Render the checked-in storyboard, synchronized captions, and website assets."""
from pathlib import Path
import argparse
import asyncio
import bisect
import hashlib
import html
import importlib.util
import json
import math
import re
import subprocess

import edge_tts
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'dist/videos/source'
OUT = ROOT / 'pages/assets/video'
BASE.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('visual', Path(__file__).with_name('visuals.py'))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
VOICE, RATE, GAP = 'zh-CN-XiaoxiaoNeural', '+0%', 1.2
parser = argparse.ArgumentParser()
parser.add_argument('--prepare-only', action='store_true', help='Synthesize narration and preview frames without encoding video')
args = parser.parse_args()


def probe(path):
    return float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(path)]))


voice_paths = []
for scene in v.SCENES:
    digest = hashlib.sha256(f'{VOICE}|{RATE}|WordBoundary|{scene["narration"]}'.encode()).hexdigest()[:20]
    voice_paths.append(BASE / f'demo-{digest}.mp3')


async def voices():
    for index, (scene, path) in enumerate(zip(v.SCENES, voice_paths)):
        timing_path = path.with_suffix('.json')
        if path.exists() and timing_path.exists():
            continue
        for attempt in range(3):
            try:
                timing = []
                with path.with_suffix('.part').open('wb') as output:
                    async for event in edge_tts.Communicate(scene['narration'], VOICE, rate=RATE, boundary='WordBoundary').stream():
                        if event['type'] == 'audio':
                            output.write(event['data'])
                        elif event['type'] == 'WordBoundary':
                            timing.append({key: event[key] for key in ('offset', 'duration', 'text')})
                if not timing:
                    raise ValueError('TTS returned no word timing')
                path.with_suffix('.part').replace(path)
                timing_path.write_text(json.dumps(timing, ensure_ascii=False))
                print(f'Narration {index+1}/{len(v.SCENES)} generated', flush=True)
                break
            except Exception:
                if attempt == 2:
                    raise
                await asyncio.sleep(attempt+1)


def normalized(value):
    return re.sub(r'\s+', '', html.unescape(value))


def captions(scene, path, duration):
    narrative = normalized(scene['narration'])
    cursor, words = 0, []
    for event in json.loads(path.with_suffix('.json').read_text()):
        token = normalized(event['text'])
        if not token:
            continue
        start = narrative.find(token, cursor)
        if start < 0:
            raise ValueError(f'Cannot align TTS word {token!r} in scene {scene["id"]}')
        end = start+len(token)
        words.append((start, end, event['offset']/10_000_000, (event['offset']+event['duration'])/10_000_000))
        cursor = end
    v.action_times[scene['id']] = {}
    for name, marker in scene.get('actions', {}).items():
        start = narrative.index(normalized(marker))
        end = start+len(normalized(marker))
        matched = [word for word in words if word[0] < end and word[1] > start]
        v.action_times[scene['id']][name] = matched[0][2]
    result, cursor = [], 0
    for chunk in v.subtitle_chunks(scene['narration']):
        token = normalized(chunk)
        start = narrative.index(token, cursor)
        end = start+len(token)
        overlapping = [word for word in words if word[0] < end and word[1] > start]
        if not overlapping:
            raise ValueError(f'No timing for caption: {chunk}')
        result.append((overlapping[0][2], min(duration, overlapping[-1][3]), chunk))
        cursor = end
    # Hold each cue through natural pauses rather than flashing an empty caption
    # between phrases; the next cue still starts on its real spoken boundary.
    return [(start, result[index+1][0] if index+1 < len(result) else duration, text)
            for index, (start, _, text) in enumerate(result)]


asyncio.run(voices())
durations = [probe(path) for path in voice_paths]
lengths = [value+GAP for value in durations]
boundaries = [0]
for value in lengths:
    boundaries.append(boundaries[-1]+value)
total = boundaries[-1]
v.scene_lengths = lengths
scene_captions = [captions(scene, path, duration) for scene, path, duration in zip(v.SCENES, voice_paths, durations)]
manifest = {'voice': VOICE, 'rate': RATE, 'duration': total, 'scenes': [
    {**scene, 'start': boundaries[index], 'speech_duration': durations[index], 'duration': lengths[index],
     'captions': scene_captions[index]} for index, scene in enumerate(v.SCENES)
]}
(BASE / 'demo-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
print(f'{len(v.SCENES)} scenes; total {total:.3f} seconds', flush=True)

# These are the exact frames used by the renderer, with the same subtitle timing.
preview_paths = []
for index, length in enumerate(lengths):
    local = length*0.5
    subtitle = next((text for start, end, text in scene_captions[index] if start <= local < end), '')
    path = BASE / f'preview-{index+1:02}.png'
    v.frame(index, .5, boundaries[index]+local, total, subtitle).save(path)
    preview_paths.append(path)
rows = math.ceil(len(preview_paths) / 3)
contact = Image.new('RGB', (1920, rows * 360), '#FFFFFF')
for index, path in enumerate(preview_paths):
    thumb = Image.open(path).resize((640, 360))
    # Three columns across dynamic rows, each preview retaining its 16:9 proportions.
    contact.paste(thumb, ((index % 3)*640, (index//3)*360))
contact.save(BASE / 'contact-sheet.jpg', quality=92)
if args.prepare_only:
    raise SystemExit(0)

vtt = ['WEBVTT', '']
for index, chunks in enumerate(scene_captions):
    for start, end, text in chunks:
        vtt.extend([f'{v.stamp(boundaries[index]+start)} --> {v.stamp(boundaries[index]+end)}', text, ''])
(OUT / 'demo.zh-CN.vtt').write_text('\n'.join(vtt))

for index, path in enumerate(voice_paths):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(path), '-af', 'apad', '-t', str(lengths[index]),
                    '-ar', '48000', '-ac', '1', str(BASE / f'demo-scene-{index}.wav')], check=True)
(BASE / 'demo-concat.txt').write_text(''.join(f"file '{BASE / f'demo-scene-{index}.wav'}'\n" for index in range(len(v.SCENES))))
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(BASE / 'demo-concat.txt'),
                '-c:a', 'pcm_s16le', str(BASE / 'demo-narration.wav')], check=True)
video = OUT / 'Remote_Buddy_Demo_Natural_zh-CN.mp4'
command = ['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{v.W}x{v.H}',
           '-r', str(v.FPS), '-i', '-', '-i', str(BASE / 'demo-narration.wav'), '-r', '24', '-c:v', 'libx264',
           '-preset', 'fast', '-crf', '23', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k',
           '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11', '-t', str(total), '-movflags', '+faststart', str(video)]
with subprocess.Popen(command, stdin=subprocess.PIPE) as process:
    previous = -1
    try:
        for number in range(math.ceil(total*v.FPS)):
            time = number/v.FPS
            index = min(len(v.SCENES)-1, bisect.bisect_right(boundaries, time)-1)
            local = time-boundaries[index]
            subtitle = next((text for start, end, text in scene_captions[index] if start <= local < end), '')
            process.stdin.write(v.frame(index, local/lengths[index], time, total, subtitle).tobytes())
            if index != previous:
                print(f'Rendering scene {index+1}/{len(v.SCENES)}: {v.SCENES[index]["id"]}', flush=True)
                previous = index
        process.stdin.close()
        if process.wait() != 0:
            raise RuntimeError('Video encoding failed')
    except BaseException:
        process.terminate()
        raise
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', '6', '-i', str(video), '-frames:v', '1', str(OUT / 'demo-poster.jpg')], check=True)
print(f'Completed: {video} ({probe(video):.3f}s, {video.stat().st_size/1024/1024:.2f} MiB)', flush=True)
