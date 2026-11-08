"""Stream a single, tool-free assistant reply from the installed CLI.

Codex uses App Server's local stdio protocol. Claude Code uses stream-json.
`emit` receives append-only assistant text; the return value is exactly the
concatenation of those deltas. Neither provider's diagnostic output is exposed.
"""
from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import threading
import time
from typing import Callable


class AgentStreamError(Exception):
    """A reply could not be completed."""


class AgentStreamTimeout(AgentStreamError):
    """The CLI did not finish within the deadline."""


class AgentStreamUnsupported(AgentStreamError):
    """The installed CLI does not provide a compatible, restricted protocol."""


class AgentStreamStopped(AgentStreamError):
    """The caller cancelled the reply."""


TIMEOUT_SECONDS = 95
MAX_JSON_LINE = 4 * 1024 * 1024
MAX_REPLY = 2800


def text_only(value) -> str:
    if not isinstance(value, str):
        return ""
    return "".join(" " if char == "\t" else char for char in value if char in "\n\t" or char.isprintable())


class Reply:
    def __init__(self, emit: Callable[[str], None]):
        self.emit = emit
        self.value = ""
        self.trailing = ""

    def append(self, delta):
        if len(self.value) >= MAX_REPLY:
            return
        combined = self.trailing + text_only(delta)
        if not self.value:
            combined = combined.lstrip()
        committed = combined.rstrip()
        available = MAX_REPLY - len(self.value)
        self.trailing = combined[len(committed):len(committed) + available]
        if len(committed) >= available:
            committed = committed[:available].rstrip()
            self.trailing = ""
        if committed:
            self.value += committed
            self.emit(committed)

    def reconcile(self, complete):
        """A cumulative/final message may add a suffix, never replace spoken text."""
        candidate = text_only(complete).strip()[:MAX_REPLY].rstrip()
        if candidate and candidate.startswith(self.value):
            self.trailing = ""
            self.append(candidate[len(self.value):])

    def finish(self) -> str:
        if not self.value:
            raise AgentStreamError("Ассистент вернул пустой ответ.")
        return self.value


def stop_group(child: subprocess.Popen) -> None:
    # Both providers can start descendants. Terminate the owned process group.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=0.7)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=0.7)
    except subprocess.TimeoutExpired:
        pass


@contextmanager
def agent_process(command, cwd, env):
    if os.name != "posix":
        raise AgentStreamUnsupported("Потоковый режим CLI доступен на macOS, Linux и в WSL.")
    restore = {}
    child = None

    def interrupted(_signum, _frame):
        raise AgentStreamStopped("Разговор остановлен.")

    try:
        if threading.current_thread() is threading.main_thread():
            for signum in (signal.SIGINT, signal.SIGTERM):
                restore[signum] = signal.getsignal(signum)
                signal.signal(signum, interrupted)
        child = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 start_new_session=True, bufsize=0)
        yield JsonWire(child)
    except KeyboardInterrupt:
        raise AgentStreamStopped("Разговор остановлен.") from None
    except FileNotFoundError:
        raise AgentStreamUnsupported("CLI ассистента не найден.") from None
    except OSError:
        raise AgentStreamError("Связь с CLI ассистента прервалась.") from None
    finally:
        # Restore before cleanup, so a second terminal interrupt keeps its normal meaning.
        for signum, handler in restore.items():
            signal.signal(signum, handler)
        if child is not None:
            stop_group(child)
            child.stdin.close()
            child.stdout.close()


class JsonWire:
    def __init__(self, child: subprocess.Popen):
        self.child = child
        self.deadline = time.monotonic() + TIMEOUT_SECONDS
        self.pending = bytearray()
        self.request_id = 0
        os.set_blocking(child.stdin.fileno(), False)
        os.set_blocking(child.stdout.fileno(), False)

    def remaining(self) -> float:
        seconds = self.deadline - time.monotonic()
        if seconds <= 0:
            raise AgentStreamTimeout("Ассистент не успел ответить.")
        return seconds

    def write(self, data: bytes) -> None:
        fd = self.child.stdin.fileno()
        pending = memoryview(data)
        while pending:
            if not select.select([], [fd], [], self.remaining())[1]:
                raise AgentStreamTimeout("CLI не принял запрос вовремя.")
            try:
                sent = os.write(fd, pending)
            except BlockingIOError:
                continue
            pending = pending[sent:]

    def send(self, message: dict) -> None:
        self.write((json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8"))

    def messages(self):
        fd = self.child.stdout.fileno()
        while True:
            while b"\n" not in self.pending:
                if not select.select([fd], [], [], self.remaining())[0]:
                    raise AgentStreamTimeout("Ассистент не успел ответить.")
                try:
                    chunk = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    event = self.parse_line(self.pending)
                    self.pending.clear()
                    if event is not None:
                        yield event
                    return
                self.pending.extend(chunk)
                if len(self.pending) > MAX_JSON_LINE:
                    raise AgentStreamError("CLI вернул слишком большое событие.")
            line, _, rest = self.pending.partition(b"\n")
            self.pending = rest
            event = self.parse_line(line)
            if event is not None:
                yield event

    @staticmethod
    def parse_line(line):
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError):
            return None
        return event if isinstance(event, dict) else None

    def request(self, method: str, params: dict) -> int:
        self.request_id += 1
        self.send({"id": self.request_id, "method": method, "params": params})
        return self.request_id

    def deny_server_request(self, event: dict) -> None:
        if "id" in event and isinstance(event.get("method"), str):
            self.send({"id": event["id"], "error": {"code": -32601, "message": "Unavailable in Jarvis voice mode"}})
            raise AgentStreamError("Codex запросил действие, недоступное в голосовом режиме.")

    def response(self, request_id: int) -> dict:
        for event in self.messages():
            self.deny_server_request(event)
            if event.get("id") == request_id:
                result = event.get("result")
                if isinstance(result, dict):
                    return result
                break
        raise AgentStreamUnsupported("Codex App Server не подтвердил безопасную конфигурацию сеанса.")


def codex_text_item(item) -> bool:
    return isinstance(item, dict) and item.get("type") == "agentMessage" and isinstance(item.get("id"), str)


def stream_codex(executable, prompt, cwd, env, reply):
    # Local CLI authentication is reused. No external agent SDK or key is copied.
    command = [executable, "app-server", "--listen", "stdio://", "-c", 'model_provider="openai"',
               "-c", 'web_search="disabled"', "-c", "features.shell_tool=false", "-c", "features.hooks=false",
               "-c", "features.plugins=false", "-c", "features.multi_agent=false", "-c", "features.enable_mcp_apps=false",
               "-c", "project_doc_max_bytes=0"]
    with agent_process(command, cwd, env) as wire:
        wire.response(wire.request("initialize", {
            "clientInfo": {"name": "jarvis_creator", "title": "Jarvis Creator", "version": "1.0.0"},
            "capabilities": {"experimentalApi": True},
        }))
        wire.send({"method": "initialized", "params": {}})
        effective = wire.response(wire.request("config/read", {"cwd": str(cwd), "includeLayers": False})).get("config")
        if not isinstance(effective, dict):
            raise AgentStreamUnsupported("Не удалось проверить локальные подключения Codex.")
        servers = effective.get("mcp_servers") or {}
        if not isinstance(servers, dict) or any(not re.fullmatch(r"[A-Za-z0-9_-]+", name) for name in servers):
            raise AgentStreamUnsupported("Не удалось изолировать подключения Codex для голосового ответа.")
        # An empty MCP table merges with user config. Disable each entry in this thread instead.
        disabled = {f"mcp_servers.{name}.enabled": False for name in servers}
        result = wire.response(wire.request("thread/start", {
            "cwd": str(cwd), "modelProvider": "openai", "approvalPolicy": "never", "sandbox": "read-only",
            "ephemeral": True, "environments": [], "dynamicTools": [], "config": disabled,
            "developerInstructions": "Answer the user's question in plain text. Do not use tools, files, or the network.",
        }))
        thread = result.get("thread")
        thread_id = thread.get("id") if isinstance(thread, dict) else None
        sandbox = result.get("sandbox")
        if (not isinstance(thread_id, str) or not thread_id or thread.get("ephemeral") is not True
                or result.get("approvalPolicy") != "never" or result.get("modelProvider") != "openai"
                or not isinstance(sandbox, dict) or sandbox.get("type") != "readOnly"
                or sandbox.get("networkAccess") is not False):
            raise AgentStreamUnsupported("Codex не подтвердил временный сеанс только для чтения.")
        turn_request = wire.request("turn/start", {
            "threadId": thread_id, "input": [{"type": "text", "text": prompt}],
        })
        final_id = None
        unclassified = ""
        turn_id = None
        for event in wire.messages():
            wire.deny_server_request(event)
            if event.get("id") == turn_request:
                if "error" in event:
                    raise AgentStreamError("Codex не принял запрос. Проверь вход командой codex login.")
                turn = (event.get("result") or {}).get("turn") or {}
                turn_id = turn.get("id")
                continue
            method = event.get("method")
            params = event.get("params")
            if not isinstance(params, dict) or params.get("threadId") != thread_id:
                continue
            if turn_id and params.get("turnId", turn_id) != turn_id:
                continue
            item = params.get("item")
            if method in ("item/started", "item/completed") and codex_text_item(item):
                phase = item.get("phase")
                if phase == "final_answer" and final_id in (None, item["id"]):
                    final_id = item["id"]
                    reply.reconcile(item.get("text"))
                elif phase is None and method == "item/completed":
                    unclassified = item.get("text") or ""
            elif method == "item/agentMessage/delta" and final_id is not None and params.get("itemId") == final_id:
                reply.append(params.get("delta"))
            elif method == "turn/completed":
                turn = params.get("turn")
                if not isinstance(turn, dict) or (turn_id and turn.get("id") != turn_id):
                    continue
                if turn.get("status") == "interrupted":
                    raise AgentStreamStopped("Разговор остановлен.")
                if turn.get("status") != "completed":
                    raise AgentStreamError("Codex не завершил ответ. Проверь вход и соединение.")
                items = turn.get("items") or []
                candidates = [entry for entry in items if codex_text_item(entry)]
                finals = [entry for entry in candidates if entry.get("phase") == "final_answer"
                          and final_id in (None, entry["id"])]
                if finals:
                    reply.reconcile(finals[-1].get("text"))
                elif not reply.value:
                    legacy = [entry for entry in candidates if entry.get("phase") is None]
                    reply.reconcile(legacy[-1].get("text") if legacy else unclassified)
                return reply.finish()
        raise AgentStreamError("Codex завершил соединение до конца ответа. Проверь вход и соединение.")


def stream_claude(executable, prompt, cwd, env, reply):
    # Keep the user's normal Claude login. Bare mode would require an API key.
    command = [executable, "--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages",
               "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
               "--permission-mode", "dontAsk", "--setting-sources", ""]
    with agent_process(command, cwd, env) as wire:
        wire.write(prompt.encode("utf-8"))
        wire.child.stdin.close()
        completed = ""
        saw_event = False
        for event in wire.messages():
            saw_event = True
            kind = event.get("type")
            if kind == "stream_event" and event.get("parent_tool_use_id") is None:
                data = event.get("event")
                if not isinstance(data, dict):
                    continue
                if data.get("type") == "content_block_delta":
                    delta = data.get("delta")
                    if isinstance(delta, dict) and delta.get("type") == "text_delta":
                        reply.append(delta.get("text"))
                elif data.get("type") == "content_block_start":
                    block = data.get("content_block")
                    if isinstance(block, dict) and block.get("type") == "text":
                        reply.append(block.get("text"))
            elif kind == "assistant" and event.get("parent_tool_use_id") is None:
                message = event.get("message") or {}
                snapshot = "".join(text_only(block.get("text")) for block in message.get("content") or []
                                   if isinstance(block, dict) and block.get("type") == "text")[:MAX_REPLY]
                if snapshot.startswith(completed):
                    completed = snapshot
                elif snapshot and not completed.endswith(snapshot):
                    completed = f"{completed}\n{snapshot}"[:MAX_REPLY]
            elif kind == "result":
                if event.get("is_error") or event.get("subtype") != "success":
                    raise AgentStreamError("Claude Code не завершил ответ. Проверь вход командой claude auth login.")
                reply.reconcile(event.get("result") or completed)
                return reply.finish()
        if not saw_event:
            raise AgentStreamUnsupported("Claude Code не открыл потоковый режим. Проверь версию CLI и вход.")
        raise AgentStreamError("Claude Code завершил соединение до конца ответа. Проверь версию CLI и вход.")


def stream_agent(executable, provider, prompt, cwd, env, emit: Callable[[str], None]) -> str:
    """Stream sanitized assistant deltas and return the final append-only reply."""
    cwd = Path(cwd).resolve()
    reply = Reply(emit)
    if provider == "codex":
        return stream_codex(executable, prompt, cwd, env, reply)
    if provider == "claude":
        return stream_claude(executable, prompt, cwd, env, reply)
    raise AgentStreamUnsupported("Этот CLI не поддерживает потоковый ответ.")
