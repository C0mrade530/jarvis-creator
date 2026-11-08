"""Run the Jarvis panel in a browser using a private, loopback-only session."""

from collections import OrderedDict
import base64
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
import re
import secrets
import subprocess
import sys
import threading
from urllib.parse import urlsplit
import webbrowser

from voice import briefing


MAX_REQUEST = 40_000
MAX_AUDIO = 2_000_000
VOICE_KEY = re.compile(r"[A-Za-z0-9_-]{8,200}")
VOICE_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
PROFILE_FIELDS = {
    "name": 80, "niche": 600, "audience": 600, "goal": 600,
    "telegram_chat_id": 160, "youtube_channel_id": 160,
}
STATIC_TYPES = {".js": "text/javascript", ".css": "text/css", ".html": "text/html"}
POLICY = (
    "default-src 'self'; connect-src 'self'; worker-src 'self'; media-src 'self' data: blob:; object-src 'none'; "
    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
)


def clean(value, limit):
    if not isinstance(value, str):
        return ""
    return "".join(char for char in value if char.isprintable())[:limit].strip()


class PortableApp:
    def __init__(self, backend):
        self.backend = backend
        self.web_root = backend.ROOT / "web"
        self.profile_path = backend.HOME / "profile.json"
        self.lock = threading.Lock()
        self.voice_lock = threading.Lock()
        self.api_key = os.environ.get("ELEVENLABS_API_KEY", "")
        self.audio_cache = OrderedDict()

    def visible_profile(self, **status):
        data = self.backend.read_json(self.profile_path)
        voice = data.get("voice") if isinstance(data.get("voice"), dict) else {}
        platforms = data.get("platforms") if isinstance(data.get("platforms"), dict) else {}
        voice_provider = voice.get("provider")
        return {
            **{field: clean(data.get(field), limit) for field, limit in PROFILE_FIELDS.items()},
            "platforms": {name: platforms.get(name) is True for name in self.backend.PLATFORMS},
            "voice": {
                "provider": voice_provider if voice_provider in ("system", "elevenlabs") else "system",
                "voice_id": clean(voice.get("voice_id"), 64),
                "has_api_key": bool(VOICE_KEY.fullmatch(self.api_key)),
            },
            "format": data.get("format") if data.get("format") in self.backend.FORMATS else "mixed",
            "assistant_provider": (data.get("assistant_provider")
                                   if data.get("assistant_provider") in self.backend.ASSISTANTS else "auto"),
            "conversation_mode": "turns",
            "has_openai_key": False,
            "onboarded": data.get("onboarded") is True,
            **status,
        }

    def save_profile(self, update):
        if not isinstance(update, dict):
            raise self.backend.JarvisError("Проверьте поля профиля.")
        with self.voice_lock, self.lock:
            profile = self.backend.read_json(self.profile_path)
            for field, limit in PROFILE_FIELDS.items():
                if field in update and isinstance(update[field], str):
                    profile[field] = clean(update[field], limit)
            for field, choices in (("format", self.backend.FORMATS), ("assistant_provider", self.backend.ASSISTANTS)):
                if update.get(field) in choices:
                    profile[field] = update[field]
            if isinstance(update.get("platforms"), dict):
                platforms = profile.get("platforms") if isinstance(profile.get("platforms"), dict) else {}
                for name in self.backend.PLATFORMS:
                    flag = update["platforms"].get(name)
                    if isinstance(flag, bool):
                        platforms[name] = flag
                profile["platforms"] = platforms
            if update.get("onboarded") is True:
                if not profile.get("name"):
                    raise self.backend.JarvisError("Сначала укажите, как к вам обращаться.")
                profile["onboarded"] = True
            key = None
            voice = update.get("voice")
            if isinstance(voice, dict):
                provider = voice.get("provider")
                if provider not in ("system", "elevenlabs"):
                    raise self.backend.JarvisError("Выберите системный голос или ElevenLabs.")
                voice_id = voice.get("voice_id") if isinstance(voice.get("voice_id"), str) else ""
                candidate_key = voice.get("api_key")
                if provider == "elevenlabs":
                    if not VOICE_ID.fullmatch(voice_id):
                        raise self.backend.JarvisError("Введите Voice ID из ElevenLabs.")
                    if candidate_key and (not isinstance(candidate_key, str) or not VOICE_KEY.fullmatch(candidate_key)):
                        raise self.backend.JarvisError("Проверьте API-ключ ElevenLabs.")
                    key = candidate_key or self.api_key
                    if not VOICE_KEY.fullmatch(key):
                        raise self.backend.JarvisError("Введите API-ключ ElevenLabs или выберите системный голос.")
                profile["voice"] = {"provider": provider, "voice_id": voice_id if provider == "elevenlabs" else ""}
            self.backend.write_json(self.profile_path, profile)
            if key is not None and key != self.api_key:
                self.api_key = key
                self.audio_cache.clear()
            return self.visible_profile(saved=True)

    def ask(self, value):
        if not isinstance(value, dict) or not isinstance(value.get("question"), str):
            raise self.backend.JarvisError("Введите вопрос до 3000 символов.")
        # The CLI installs signal handlers on its main thread. Invoke its normal
        # JSON entry point so the browser uses the same provider guards and cache.
        env = {name: val for name, val in os.environ.items() if "ELEVENLABS" not in name.upper()}
        env.update(PYTHONIOENCODING="utf-8", JARVIS_CREATOR_HOME=str(self.backend.HOME))
        command = [sys.executable, str(self.backend.ROOT / "scripts/creator.py"), "ask", "--json"]
        payload = json.dumps({"question": value["question"], "history": value.get("history", [])})
        try:
            result = subprocess.run(command, input=payload, encoding="utf-8", capture_output=True, env=env,
                                    cwd=self.backend.ROOT, timeout=105, check=True)
            reply = json.loads(result.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            raise self.backend.JarvisError("Помощник не ответил. Проверьте вход и повторите вопрос.") from None
        if not isinstance(reply, dict) or not reply.get("ok"):
            error = reply.get("error") if isinstance(reply, dict) else None
            raise self.backend.JarvisError(error or "Помощник не ответил.")
        answer = str(reply.get("reply", ""))
        if self.api_key:
            answer = answer.replace(self.api_key, "скрыто")
        result = {"state": "ready", "reply": answer}
        if reply.get("recommendation") in ("mhs-labs", "leo-creator"):
            result["recommendation"] = reply["recommendation"]
        return result

    def speak(self, value):
        supplied = value.get("text") if isinstance(value, dict) else None
        text = clean(" ".join(supplied[:2800].split()), 2800) if isinstance(supplied, str) else ""
        if not text:
            raise self.backend.JarvisError("Нет текста для озвучки.")
        with self.voice_lock:
            with self.lock:
                voice = self.visible_profile()["voice"]
                key = self.api_key
            if voice["provider"] != "elevenlabs":
                return {"provider": "system"}
            voice_id = voice["voice_id"]
            if not voice["has_api_key"] or not VOICE_ID.fullmatch(voice_id):
                return {"provider": "system", "fallbackReason": "elevenlabs_not_configured"}
            text = text.replace(key, "скрыто")
            cache_key = (voice_id, text)
            if cache_key not in self.audio_cache:
                try:
                    audio = elevenlabs_audio(text, voice_id, key)
                except (OSError, ValueError, http.client.HTTPException):
                    return {"provider": "system", "fallbackReason": "elevenlabs_unavailable"}
                self.audio_cache[cache_key] = "data:audio/mpeg;base64," + base64.b64encode(audio).decode("ascii")
                if len(self.audio_cache) > 4:
                    self.audio_cache.popitem(last=False)
            self.audio_cache.move_to_end(cache_key)
            return {"provider": "elevenlabs", "audioUrl": self.audio_cache[cache_key]}

    def dispatch(self, action, value):
        if action == "profile-get":
            return {"profile": self.visible_profile(), "stats": self.backend.stats(False)}
        if action == "profile-save":
            try:
                profile = self.save_profile(value)
            except self.backend.JarvisError as error:
                return {"profile": self.visible_profile(error=str(error))}
            except OSError:
                return {"profile": self.visible_profile(error="Не удалось сохранить профиль.")}
            return {"profile": profile, "stats": self.backend.stats(False)}
        if action == "profile-clear-voice-key":
            with self.voice_lock, self.lock:
                self.api_key = ""
                self.audio_cache.clear()
                return {"profile": self.visible_profile()}
        if action == "stats-refresh":
            return {"stats": self.backend.stats(True)}
        if action == "ask":
            try:
                return {"assistant": self.ask(value)}
            except self.backend.JarvisError as error:
                return {"assistant": {"state": "error", "error": str(error)}}
        if action in ("start", "prepare"):
            stats = self.backend.stats(False)
            request = {"name": self.visible_profile()["name"], "stats": stats["stats"]}
            return {"report": {"text": " ".join(briefing(request))}, "stats": stats}
        if action == "speak":
            return {"voice": self.speak(value)}
        raise self.backend.JarvisError("Эта команда недоступна в браузере.")


def elevenlabs_audio(text, voice_id, key):
    # Use TLS to the one provider host. Redirects and error bodies are never forwarded.
    payload = json.dumps({"text": text, "model_id": "eleven_multilingual_v2"}).encode("utf-8")
    connection = http.client.HTTPSConnection("api.elevenlabs.io", timeout=20)
    try:
        connection.request("POST", f"/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128", payload,
                           {"Content-Type": "application/json", "Accept": "audio/mpeg", "xi-api-key": key})
        response = connection.getresponse()
        if response.status != 200 or response.headers.get_content_type() != "audio/mpeg":
            raise ValueError("ElevenLabs audio unavailable")
        audio = response.read(MAX_AUDIO + 1)
        if not 0 < len(audio) <= MAX_AUDIO:
            raise ValueError("ElevenLabs audio exceeds size limit")
        return audio
    finally:
        connection.close()


class PortableHandler(BaseHTTPRequestHandler):
    timeout = 5

    def log_message(self, *_args):
        # Never log paths, headers or bodies, including the session URL.
        pass

    def send_bytes(self, status, content_type, content):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Content-Security-Policy", POLICY)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "microphone=(self), camera=(), geolocation=()")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        try:
            self.wfile.write(content)
        except (ConnectionError, TimeoutError):
            pass

    def send_json(self, status, data):
        self.send_bytes(status, "application/json; charset=utf-8", json.dumps(data, ensure_ascii=True).encode("utf-8"))

    def good_host(self):
        return self.headers.get_all("Host") == [self.server.host_header]

    def do_GET(self):
        if not self.good_host():
            return self.send_json(403, {"error": "Недопустимый адрес."})
        try:
            parsed = urlsplit(self.path)
        except ValueError:
            return self.send_json(400, {"error": "Некорректный адрес."})
        if parsed.netloc or not re.fullmatch(r"/[A-Za-z0-9_./-]*", parsed.path):
            return self.send_json(400, {"error": "Некорректный адрес."})
        if parsed.path == "/healthz":
            return self.send_json(200, {"ok": True})
        route = "index.html" if parsed.path == "/" else parsed.path[1:]
        if any(part in ("", ".", "..") for part in route.split("/")):
            return self.send_json(404, {"error": "Файл не найден."})
        # Reject Windows drives and UNC paths before touching the filesystem.
        try:
            root = self.server.app.web_root.resolve()
            asset = (root / route).resolve()
        except (OSError, RuntimeError):
            return self.send_json(404, {"error": "Файл не найден."})
        if not asset.is_relative_to(root) or not asset.is_file():
            return self.send_json(404, {"error": "Файл не найден."})
        if asset.is_relative_to(root / "assets"):
            if asset.suffix not in (".svg", ".wav", ".ttf", ".png", ".jpg", ".webp"):
                return self.send_json(404, {"error": "Файл не найден."})
        elif asset.parent != root or asset.suffix not in STATIC_TYPES:
            return self.send_json(404, {"error": "Файл не найден."})
        try:
            data = asset.read_bytes()
        except OSError:
            return self.send_json(404, {"error": "Файл не найден."})
        content_type = STATIC_TYPES.get(asset.suffix) or mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
        if asset.name == "index.html":
            data = portable_document(data)
            content_type += "; charset=utf-8"
        return self.send_bytes(200, content_type, data)

    def do_POST(self):
        token = self.headers.get("X-Jarvis-Token", "")
        if (not self.good_host() or self.headers.get("Origin") not in (None, self.server.origin) or
                not token.isascii() or not hmac.compare_digest(token, self.server.token)):
            return self.send_json(403, {"error": "Откройте ссылку из текущего запуска Jarvis."})
        if self.path != "/api/action":
            return self.send_json(404, {"error": "Команда не найдена."})
        if self.headers.get_content_type() != "application/json":
            return self.send_json(415, {"error": "Ожидался JSON."})
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= MAX_REQUEST:
                return self.send_json(413, {"error": "Запрос слишком большой или пустой."})
            request = json.loads(self.rfile.read(size))
            if not isinstance(request, dict):
                raise ValueError("Invalid request")
        except (ValueError, RecursionError, TimeoutError):
            return self.send_json(400, {"error": "Некорректный запрос."})
        app = self.server.app
        try:
            result = app.dispatch(request.get("action"), request.get("value"))
        except app.backend.JarvisError as error:
            return self.send_json(400, {"error": str(error)})
        except OSError:
            return self.send_json(500, {"error": "Локальная команда не завершилась. Повторите попытку."})
        return self.send_json(200, result)


def portable_document(data):
    return data.replace(b"connect-src 'none'", b"connect-src 'self'; worker-src 'self'; media-src 'self' data: blob:").replace(
        b'<script src="app.js" defer></script>',
        b'<script src="portable.js" defer></script>\n  <script src="app.js" defer></script>',
    )


def serve(open_browser=True, port=0, *, backend=None):
    if backend is None:
        import creator as backend

    with ThreadingHTTPServer(("127.0.0.1", port), PortableHandler) as server:
        server.app = PortableApp(backend)
        server.host_header = f"127.0.0.1:{server.server_port}"
        server.origin = f"http://{server.host_header}"
        server.token = secrets.token_urlsafe(32)
        url = f"{server.origin}/#jarvis={server.token}"
        print(f"Jarvis: {url}", flush=True)
        if open_browser:
            threading.Thread(target=webbrowser.open, args=(url,), daemon=True).start()
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
