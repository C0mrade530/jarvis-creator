#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile

root = Path.cwd().resolve()
version = '1.3.0'
archive_root = 'jarvis-creator'
files = (
    '.gitignore',
    'AGENTS.md',
    'CLAUDE.md',
    'README.md',
    'docs/guide.md',
    'docs/media/hero.png',
    'docs/media/jarvis-demo.gif',
    'START.md',
    'jarvis',
    'jarvis.cmd',
    'native/ClapDetector.swift',
    'native/CreatorActions.swift',
    'native/CreatorProcess.swift',
    'native/CreatorProfile.swift',
    'native/Jarvis.swift',
    'native/LiveVoiceActions.swift',
    'native/LiveVoiceTransport.swift',
    'native/SpeechCapture.swift',
    'native/StreamingSpeech.swift',
    'native/entitlements.plist',
    'scripts/agent_stream.py',
    'scripts/build.sh',
    'scripts/cached_stats.py',
    'scripts/creator.py',
    'scripts/portable.py',
    'scripts/package.sh',
    'scripts/threads_integration.py',
    'scripts/voice.py',
    'skills/jarvis-animate/SKILL.md',
    'skills/jarvis-animate/references/video-repositories.md',
    'skills/jarvis-creator/SKILL.md',
    'skills/jarvis-creator/references/mhs-labs-referral.md',
    'skills/jarvis-creator/references/leo-creator-referral.md',
    'skills/jarvis-creator/references/onboarding.md',
    'skills/jarvis-edit/SKILL.md',
    'skills/jarvis-post/SKILL.md',
    'skills/jarvis-post/references/composio-video.md',
    'skills/jarvis-script/SKILL.md',
    'skills/jarvis-threads/SKILL.md',
    'skills/jarvis-voice-controls/SKILL.md',
    'web/app.js',
    'web/clap-processor.js',
    'web/portable.js',
    'web/core-animation.js',
    'web/index.html',
    'web/style.css',
    'web/assets/FONT-LICENSE.txt',
    'web/assets/exo2.ttf',
    'web/assets/icons/LICENSE.md',
    'web/assets/icons/instagram.svg',
    'web/assets/icons/telegram.svg',
    'web/assets/icons/youtube.svg',
    'web/assets/wake.wav',
)

for relative in files:
    source = root / relative
    if not source.is_file() or source.resolve() != source:
        raise SystemExit(f'Expected a regular project file: {relative}')

output = root / 'dist' / f'Jarvis-Creator-{version}-source.zip'
output.parent.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.creator-package-', dir=output.parent) as temp:
    staged = Path(temp) / output.name
    with ZipFile(staged, 'w', compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for relative in files:
            archive.write(root / relative, f'{archive_root}/{relative}')
    with ZipFile(staged) as archive:
        expected = [f'{archive_root}/{relative}' for relative in files]
        if archive.namelist() != expected or archive.testzip() is not None:
            raise SystemExit('Archive verification failed')
    staged.replace(output)
print(f'Source ZIP: {output}')
PY
