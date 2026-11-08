#!/usr/bin/env python3
"""Render a Jarvis Creator briefing to a local WAV. Python 3.9+ on macOS.

    python3 voice.py --output /absolute/path/briefing.wav < request.json

UTF-8 stdin: name, stats (list of platform/connected/state/period/views_period/views/
subscribers/published/subscribers_delta rows), scripts_count, optional reply,
and optional voice: {provider, voice_id, api_key}. VoiceStudio uses an installed
local Supertonic-3 model and a preset M1–M5/F1–F5 (default M1). Pass an ElevenLabs
secret via the JSON stream or ELEVENLABS_API_KEY. Use period="24h" or
"overnight" only for metrics measured over that period. Absolute subscriber
counts are always current. Omit absent metrics. "reply" synthesizes just the
reply. Success stdout is JSON with the local audio path and cue in seconds.
"""
from __future__ import annotations

import argparse
import base64
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import wave


ONES = ("", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять")
TEENS = ("десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать", "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать")
TENS = ("", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто")
HUNDREDS = ("", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот")
SCALES = (
    ("", "", ""),
    ("тысяча", "тысячи", "тысяч"),
    ("миллион", "миллиона", "миллионов"),
    ("миллиард", "миллиарда", "миллиардов"),
    ("триллион", "триллиона", "триллионов"),
)
VIEWS = ("просмотр", "просмотра", "просмотров")
VIDEOS = ("ролик", "ролика", "роликов")
NEW_VIDEOS = ("новый ролик", "новых ролика", "новых роликов")
SUBSCRIBERS = ("подписчик", "подписчика", "подписчиков")
SCRIPTS = ("сценарий", "сценария", "сценариев")
PLACES = {"youtube": "на Ютубе", "instagram": "в Инстаграме", "telegram": "в Телеграме"}
PERIODS = {"overnight": "За ночь", "24h": "За последние сутки", "7d": "За семь дней", "lifetime": "Всего"}
SAMPLE_RATE = 22050
MAX_COUNT = 999_999_999_999_999
SYSTEM_BRIEFING_HINT = "Сейчас я говорю системным голосом. В настройках можно выбрать VoiceStudio или подключить ElevenLabs."


class VoiceUnavailable(Exception):
    pass


def plural(value: int, forms: tuple[str, str, str]) -> str:
    if 11 <= value % 100 <= 14:
        return forms[2]
    last = value % 10
    return forms[0] if last == 1 else forms[1] if 2 <= last <= 4 else forms[2]


def number_words(value: int) -> str:
    if value == 0:
        return "ноль"
    groups = []
    for scale in SCALES:
        if value == 0:
            break
        value, triplet = divmod(value, 1000)
        if not triplet:
            continue
        hundreds, rest = divmod(triplet, 100)
        tens, ones = divmod(rest, 10)
        one_word = ONES[ones]
        if scale == SCALES[1] and ones in (1, 2):
            one_word = ("одна", "две")[ones - 1]
        lower_words = [TEENS[ones]] if tens == 1 else [TENS[tens], one_word]
        group = [HUNDREDS[hundreds], *lower_words, plural(triplet, scale)]
        groups.append(" ".join(word for word in group if word))
    return " ".join(reversed(groups))


def count(value, *, signed: bool = False) -> int | None:
    if isinstance(value, str) and re.fullmatch(r"-?[0-9]{1,15}", value.strip()):
        value = int(value)
    if type(value) is int and (-MAX_COUNT if signed else 0) <= value <= MAX_COUNT:
        return value
    return None


def quantity(value: int, forms: tuple[str, str, str]) -> str:
    return f"{number_words(value)} {plural(value, forms)}"


def safe_name(value) -> str:
    if not isinstance(value, str):
        return ""
    allowed = (character for character in value[:60] if character.isalpha() or character in " -’'")
    return " ".join("".join(allowed).split())


def connected(row: dict) -> bool:
    return row["state"] == "connected" if "state" in row else row.get("connected") is True


def stats_sentences(row: dict) -> list[str]:
    platform = row.get("platform")
    if not isinstance(platform, str) or platform.lower() not in PLACES or not connected(row):
        return []
    place = PLACES[platform.lower()]
    period = row.get("period")
    if period not in ("overnight", "24h", "lifetime", "current"):
        period = "lifetime"
    views_period = row.get("views_period")
    if views_period not in ("overnight", "24h", "7d", "lifetime", "current"):
        views_period = period
    published = count(row.get("published"))
    views = count(row.get("views"))
    subscribers = count(row.get("subscribers"))
    delta = count(row.get("subscribers_delta"), signed=True)
    metrics_by_period = {}
    if published is not None:
        metrics_by_period[period] = [quantity(published, NEW_VIDEOS if period in ("24h", "overnight") else VIDEOS)]
    if views is not None:
        metrics_by_period.setdefault(views_period, []).append(quantity(views, VIEWS))
    sentences = []
    for metric_period, metrics in metrics_by_period.items():
        label = f"{PERIODS.get(metric_period, '')} {place}".strip()
        sentences.append(f"{label[0].upper() + label[1:]} — {' и '.join(metrics)}.")
    if subscribers is not None:
        sentences.append(f"{place[0].upper() + place[1:]} сейчас {quantity(subscribers, SUBSCRIBERS)}.")
    if delta is not None and delta != 0:
        label = f"{PERIODS.get(period, '') if period in ('24h', 'overnight') else ''} {place}".strip()
        sign = "плюс" if delta > 0 else "минус"
        sentences.append(f"{label[0].upper() + label[1:]} — {sign} {quantity(abs(delta), SUBSCRIBERS)}.")
    return sentences


def briefing(request: dict) -> tuple[str, str]:
    name = safe_name(request.get("name"))
    greeting = f"Доброе утро, {name}." if name else "Доброе утро."
    rows = request.get("stats")
    rows = [row for row in rows[:12] if isinstance(row, dict)] if isinstance(rows, list) else []
    sentences = [sentence for row in rows for sentence in stats_sentences(row)]
    if not sentences:
        sentences.append("Данных для отчёта пока нет." if any(connected(row) for row in rows) else "Подключите платформу, чтобы получить отчёт о статистике.")
    scripts = count(request.get("scripts_count"))
    if scripts:
        sentences.append(f"Подготовлено {quantity(scripts, SCRIPTS)}.")
    return greeting, " ".join(sentences)


def reply_text(value) -> str:
    if not isinstance(value, str):
        raise VoiceUnavailable("Некорректный текст ответа.")
    # System say accepts embedded speech commands in square brackets.
    text = " ".join("".join(c for c in value[:600] if c.isprintable() and c not in "[]").split())
    if not text:
        raise VoiceUnavailable("Текст ответа пуст.")
    return text


def run(command: list[str], *, input_data: bytes | None = None, timeout: int = 25) -> bytes:
    # No child diagnostics are emitted. Provider responses can include request data.
    try:
        result = subprocess.run(command, input=input_data, capture_output=True, timeout=timeout, check=True)
    except (OSError, subprocess.SubprocessError):
        raise VoiceUnavailable("Синтез речи недоступен.") from None
    return result.stdout


def convert_wav(source: Path, destination: Path) -> None:
    run(["/usr/bin/afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", str(source), str(destination)])


def wave_frames(path: Path) -> bytes:
    with wave.open(str(path), "rb") as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, SAMPLE_RATE):
            raise VoiceUnavailable("Не удалось прочитать PCM озвучку.")
        frames = reader.readframes(reader.getnframes())
    if not frames:
        raise VoiceUnavailable("Получена пустая озвучка.")
    return frames


def join_voice_parts(frames: list[bytes], output: Path) -> float:
    pause = bytes(round(SAMPLE_RATE * 0.14) * 2)
    with wave.open(str(output), "wb") as writer:
        writer.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
        writer.writeframes(pause.join(frames))
    return (len(frames[0]) + len(pause)) / (2 * SAMPLE_RATE) if len(frames) > 1 else 0.0


def system_voice(parts: tuple[str, ...], work: Path, output: Path) -> float:
    frames = []
    for index, part in enumerate(parts):
        source = work / f"part-{index}.aiff"
        converted = work / f"part-{index}.wav"
        text = work / f"part-{index}.txt"
        text.write_text(part, encoding="utf-8")
        try:
            run(["/usr/bin/say", "-v", "Milena", "-r", "168", "-o", str(source), "-f", str(text)])
        except VoiceUnavailable:
            source.unlink(missing_ok=True)
            run(["/usr/bin/say", "-r", "168", "-o", str(source), "-f", str(text)])
        convert_wav(source, converted)
        frames.append(wave_frames(converted))
    return join_voice_parts(frames, output)


def voicestudio_request(path: str, payload: dict | None = None) -> bytes:
    # Fixed numeric loopback without proxies, redirects or credentials.
    connection = http.client.HTTPConnection("127.0.0.1", 3900, timeout=27 if payload else 3)
    try:
        if payload is None:
            connection.request("GET", path, headers={"Accept": "application/json"})
        else:
            connection.request("POST", path, body=json.dumps(payload, ensure_ascii=False).encode(),
                               headers={"Content-Type": "application/json", "Accept": "audio/wav"})
        response = connection.getresponse()
        content_type = response.getheader("Content-Type", "").split(";", 1)[0].lower().strip()
        valid_types = {"application/json"} if payload is None else {"audio/wav", "audio/x-wav"}
        if response.status != 200 or content_type not in valid_types:
            raise VoiceUnavailable("voicestudio_unavailable")
        maximum = 2_000_000 if payload is None else 12_000_000
        data = response.read(maximum + 1)
        if not data or len(data) > maximum:
            raise VoiceUnavailable("voicestudio_unavailable")
        return data
    finally:
        connection.close()


def voicestudio_voice(parts: tuple[str, ...], voice_id: str, work: Path, output: Path) -> float:
    preset = voice_id.strip().upper() if isinstance(voice_id, str) else ""
    preset = preset or "M1"
    if not re.fullmatch(r"[MF][1-5]", preset):
        raise VoiceUnavailable("voicestudio_invalid_voice")

    # /v1/models lists engine support, regardless of downloaded weights.
    inventory = json.loads(voicestudio_request("/models"))
    rows = inventory.get("models") if isinstance(inventory, dict) and inventory.get("target") == "local" else None
    installed = isinstance(rows, list) and any(
        isinstance(entry, dict) and entry.get("installed") is True
        and entry.get("hf_repo", entry.get("repo_id")) == "Supertone/supertonic-3"
        for entry in rows
    )
    if not installed:
        raise VoiceUnavailable("voicestudio_not_ready")

    frames = []
    for index, part in enumerate(parts):
        source = work / f"voicestudio-{index}.wav"
        converted = work / f"voicestudio-{index}-pcm.wav"
        source.write_bytes(voicestudio_request("/v1/audio/speech", {
            "model": "supertonic3", "input": part, "voice": preset,
            "language": "ru", "response_format": "wav",
        }))
        convert_wav(source, converted)
        frames.append(wave_frames(converted))
    return join_voice_parts(frames, output)


def elevenlabs_voice(parts: tuple[str, ...], voice_id: str, key: str, work: Path, output: Path) -> float:
    text = " ".join(parts)
    body = work / "request.json"
    body.write_text(json.dumps({"text": text, "model_id": "eleven_multilingual_v2"}, ensure_ascii=False), encoding="utf-8")
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/with-timestamps?output_format=mp3_44100_128"
    # curl uses the system trust store. The key reaches only the HTTPS request,
    # via stdin; disabling curlrc avoids user-configured redirects or logging.
    response = run([
        "/usr/bin/curl", "--disable", "--silent", "--fail", "--proto", "=https",
        "--max-time", "20", "--max-filesize", "25000000", "--header", "@-",
        "--header", "Content-Type: application/json", "--data-binary", f"@{body}", url,
    ], input_data=f"xi-api-key: {key}\n".encode(), timeout=23)
    try:
        result = json.loads(response)
        audio = base64.b64decode(result["audio_base64"], validate=True)
        cue = 0.0
        if len(parts) > 1:
            alignment = result["alignment"]
            aligned = "".join(alignment["characters"])
            report_index = aligned.index(parts[1][:24], len(parts[0]))
            cue = float(alignment["character_start_times_seconds"][report_index])
        mp3 = work / "remote.mp3"
        mp3.write_bytes(audio)
        convert_wav(mp3, output)
        duration = len(wave_frames(output)) / (2 * SAMPLE_RATE)
        if not 0 <= cue < duration:
            raise ValueError("invalid cue")
    except (TypeError, ValueError, KeyError, IndexError, wave.Error, EOFError):
        raise VoiceUnavailable("Синтез ElevenLabs недоступен.") from None
    return cue


def render(request: dict, output: Path) -> dict:
    if output.suffix.lower() != ".wav":
        raise VoiceUnavailable("Путь к озвучке должен заканчиваться на .wav.")
    voice = request.get("voice")
    voice = voice if isinstance(voice, dict) else {}
    voice_id = voice.get("voice_id")
    supplied_key = voice.get("api_key")
    key = supplied_key if isinstance(supplied_key, str) and supplied_key else os.environ.get("ELEVENLABS_API_KEY", "")
    parts = (reply_text(request["reply"]),) if "reply" in request else briefing(request)
    if key:
        parts = tuple(part.replace(key, "скрыто") for part in parts)
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    provider = "system"
    fallback_reason = None
    with tempfile.TemporaryDirectory(prefix=".voice-", dir=output.parent) as temp:
        work = Path(temp)
        staged = work / "briefing.wav"
        if voice.get("provider") == "voicestudio":
            try:
                cue = voicestudio_voice(parts, voice_id, work, staged)
                provider = "voicestudio"
            except (VoiceUnavailable, OSError, http.client.HTTPException, ValueError, TypeError, wave.Error, EOFError) as error:
                known_reasons = {"voicestudio_not_ready", "voicestudio_invalid_voice"}
                fallback_reason = str(error) if str(error) in known_reasons else "voicestudio_unavailable"
        elif voice.get("provider") == "elevenlabs":
            configured = isinstance(voice_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", voice_id)
            if configured and re.fullmatch(r"[A-Za-z0-9_-]{8,200}", key):
                try:
                    cue = elevenlabs_voice(parts, voice_id, key, work, staged)
                    provider = "elevenlabs"
                except (VoiceUnavailable, OSError):
                    fallback_reason = "elevenlabs_unavailable"
            else:
                fallback_reason = "elevenlabs_not_configured"
        if provider == "system":
            staged.unlink(missing_ok=True)
            if "reply" not in request:
                parts = (parts[0], f"{parts[1]} {SYSTEM_BRIEFING_HINT}")
            cue = system_voice(parts, work, staged)
        duration = len(wave_frames(staged)) / (2 * SAMPLE_RATE)
        staged.chmod(0o600)
        staged.replace(output)
    result = {
        "audioPath": str(output), "durationSeconds": round(duration, 6),
        "sideRevealSeconds": round(cue, 6), "provider": provider, "text": " ".join(parts),
    }
    if fallback_reason:
        result["fallbackReason"] = fallback_reason
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Local Jarvis Creator voice briefing")
    parser.add_argument("--output", type=Path, required=True, help="Destination WAV file")
    args = parser.parse_args()
    try:
        encoded = sys.stdin.buffer.read(64 * 1024 + 1)
        if len(encoded) > 64 * 1024:
            raise VoiceUnavailable("Запрос превышает допустимый размер.")
        request = json.loads(encoded)
        if not isinstance(request, dict):
            raise VoiceUnavailable("Ожидается объект JSON.")
        result = render(request, args.output)
    except VoiceUnavailable as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 1
    except (OSError, ValueError, TypeError, EOFError, wave.Error):
        print(json.dumps({"error": "Не удалось подготовить озвучку."}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
