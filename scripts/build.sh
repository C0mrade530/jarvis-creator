#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
creator_root="$PWD"
creator_version="1.3.0"
creator_bundle="$creator_root/build/Jarvis Creator.app"
creator_zip="$creator_root/dist/Jarvis-Creator-$creator_version-macOS-universal.zip"
mkdir -p "$creator_root/build" "$creator_root/dist"
creator_stage=$(mktemp -d "$creator_root/build/.stage.XXXXXX")
trap 'rm -rf "$creator_stage"' EXIT
creator_app="$creator_stage/Jarvis Creator.app"
mkdir -p "$creator_app/Contents/MacOS" "$creator_app/Contents/Resources"

python3 - "$creator_root" "$creator_app" "$creator_version" <<'PY'
import pathlib, plistlib, shutil, sys

project, bundle = map(pathlib.Path, sys.argv[1:3])
resources = bundle / 'Contents' / 'Resources'
required = [
    'web/index.html', 'web/app.js', 'web/style.css', 'web/core-animation.js',
    'scripts/creator.py', 'scripts/agent_stream.py', 'scripts/cached_stats.py',
    'scripts/threads_integration.py', 'scripts/voice.py', 'jarvis', 'skills/jarvis-threads/SKILL.md',
]
optional = [
    'web/scene-data.js', 'web/scene.json', 'web/scripts.json',
    'web/creator.js', 'web/creator.css',
    'web/assets/narration.wav', 'web/assets/timing.json', 'web/assets/music.wav', 'web/assets/wake.wav',
    'web/assets/exo2.ttf', 'web/assets/FONT-LICENSE.txt',
]
for category in ('covers', 'icons'):
    folder = project / 'web' / 'assets' / category
    if folder.is_dir():
        optional.extend(str(file.relative_to(project)) for file in sorted(folder.iterdir())
                        if file.suffix.lower() in {'.svg', '.png', '.jpg', '.jpeg', '.webp'} or file.name == 'LICENSE.md')
for relative in required + optional:
    source = project / relative
    if not source.is_file():
        if relative in required:
            raise SystemExit(f'Missing required bundle file: {relative}')
        continue
    if source.is_symlink() or not source.resolve().is_relative_to(project):
        raise SystemExit(f'Bundle resources must be regular project files: {relative}')
    destination = resources / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)

info = {
    'CFBundleExecutable': 'JarvisCreator', 'CFBundleIdentifier': 'com.jarviscreator.local',
    'CFBundleName': 'Jarvis Creator', 'CFBundleDisplayName': 'Jarvis Creator', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': sys.argv[3], 'CFBundleVersion': '5', 'LSMinimumSystemVersion': '14.0',
    'CFBundleDevelopmentRegion': 'ru', 'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
    'NSMicrophoneUsageDescription': 'Jarvis Creator распознаёт хлопки и голосовые вопросы. В обычном разговоре звук обрабатывается на Mac, в режиме GPT-Live передаётся в OpenAI.',
    'NSSpeechRecognitionUsageDescription': 'Jarvis Creator распознаёт ваши голосовые вопросы на Mac. Текст вопроса передаётся ассистенту после окончания записи.',
}
with (bundle / 'Contents' / 'Info.plist').open('wb') as file:
    plistlib.dump(info, file)
(bundle / 'Contents' / 'PkgInfo').write_text('APPL????')
PY

for creator_arch in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -target "$creator_arch-apple-macosx14.0" native/*.swift \
        -framework AppKit -framework WebKit -framework AVFoundation -framework CoreGraphics \
        -framework CoreAudio -framework AudioToolbox -framework Security -framework Speech \
        -o "$creator_stage/JarvisCreator-$creator_arch"
done
xcrun lipo -create "$creator_stage/JarvisCreator-arm64" "$creator_stage/JarvisCreator-x86_64" \
    -output "$creator_app/Contents/MacOS/JarvisCreator"
xcrun lipo "$creator_app/Contents/MacOS/JarvisCreator" -verify_arch arm64 x86_64

if [[ -n "${JARVIS_CREATOR_DEVELOPER_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements native/entitlements.plist \
        --sign "$JARVIS_CREATOR_DEVELOPER_ID" "$creator_app"
else
    codesign --force --sign - "$creator_app"
fi
codesign --verify --deep --strict "$creator_app"
"$creator_app/Contents/MacOS/JarvisCreator" --self-test
ditto -c -k --keepParent "$creator_app" "$creator_stage/creator.zip"

if [[ -e "$creator_bundle" ]]; then mv "$creator_bundle" "$creator_stage/previous.app"; fi
mv "$creator_app" "$creator_bundle"
mv -f "$creator_stage/creator.zip" "$creator_zip"
printf 'App: %s\nZIP: %s\n' "$creator_bundle" "$creator_zip"
