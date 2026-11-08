"""Install the pinned Threads Content Factory and open its local MCP session."""

import http.client
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

REPO = "https://github.com/C0mrade530/threads-content-factory.git"
REVISION = "0d15e232d9ad727cc9e24456deabb486f6c33451"
LOCAL_API = "http://127.0.0.1:8000"
SERVER_NAME = "threads-content-factory"
CHAT_PROMPT = (
    "Открой skills/jarvis-threads/SKILL.md. Помоги с Threads Content Factory. "
    "Начни с get_factory_status. Ссылку подключения запрашивай по моей просьбе. "
    "Перед привязкой аккаунта, постановкой текстов или включением расписания "
    "покажи точное действие и получи моё согласие."
)


class ThreadsError(Exception):
    pass


def add_threads_commands(commands):
    threads = commands.add_parser("threads", help="установить и открыть Threads Content Factory")
    actions = threads.add_subparsers(dest="threads_action", required=True)
    actions.add_parser("install", help="установить проверенную версию и MCP-зависимости")
    actions.add_parser("setup", help="ввести ключ Upload-Post в терминале")
    actions.add_parser("status", help="проверить установку и доступность локального API")
    actions.add_parser("run", help="запустить локальный API и очередь публикаций")
    chat = actions.add_parser("chat", help="открыть чат с инструментами Threads")
    chat.add_argument("--agent", choices=("auto", "codex", "claude"))


def integration_path(state_dir):
    return state_dir / "integrations" / SERVER_NAME


def require_verified_checkout(git, path):
    if path.is_symlink() or not (path / ".git").is_dir():
        raise ThreadsError(f"Проверь каталог Threads: {path}")
    for command, expected in ((["remote", "get-url", "origin"], REPO), (["rev-parse", "HEAD"], REVISION)):
        result = subprocess.run([git, *command], cwd=path, capture_output=True, text=True, check=False)
        if result.returncode or result.stdout.strip() != expected:
            raise ThreadsError(f"В {path} другая версия Threads Factory. Проверь изменения перед заменой.")
    dirty = subprocess.run([git, "diff", "--quiet", "HEAD", "--"], cwd=path, check=False)
    if dirty.returncode:
        raise ThreadsError(f"В {path} есть изменения исходников. Проверь их перед запуском.")


def install(path, git, uv):
    if not path.exists():
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".threads-install-", dir=path.parent) as folder:
            checkout = Path(folder) / SERVER_NAME
            checkout.mkdir()
            subprocess.run([git, "init", "--quiet", str(checkout)], check=True)
            subprocess.run([git, "remote", "add", "origin", REPO], cwd=checkout, check=True)
            subprocess.run([git, "fetch", "--quiet", "--depth", "1", "origin", REVISION], cwd=checkout, check=True)
            subprocess.run([git, "checkout", "--quiet", "--detach", "FETCH_HEAD"], cwd=checkout, check=True)
            require_verified_checkout(git, checkout)
            checkout.rename(path)
    require_verified_checkout(git, path)
    subprocess.run([uv, "--directory", str(path), "sync", "--locked", "--no-dev", "--extra", "mcp"], check=True)
    print(f"Threads Factory установлен: {path}")
    print("Следующий шаг: ./jarvis threads setup")


def health():
    connection = http.client.HTTPConnection("127.0.0.1", 8000, timeout=0.6)
    try:
        connection.request("GET", "/health")
        response = connection.getresponse()
        data = json.loads(response.read(1000)) if response.status == 200 else None
        return isinstance(data, dict) and data.get("ok") is True
    except (OSError, ValueError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def service_env():
    secret_names = {"FACTORY_API_KEY", "UPLOAD_POST_API_KEY", "UPLOAD_POST_PROFILE", "OPENAI_API_KEY", "OPENAI_MODEL",
                    "OPENAI_BASE_URL", "DATA_DIR", "PUBLIC_BASE_URL", "REFERENCE_DIR"}
    env = {key: value for key, value in os.environ.items() if key not in secret_names}
    env["FACTORY_BASE_URL"] = LOCAL_API
    no_proxy = ",".join(filter(None, (env.get("no_proxy", ""), env.get("NO_PROXY", ""), "127.0.0.1,localhost")))
    env["NO_PROXY"] = env["no_proxy"] = no_proxy
    return env


def run_services(command):
    if os.name != "posix":
        raise ThreadsError("Для локального worker на Windows запусти Jarvis в WSL2.")
    if health():
        raise ThreadsError("Локальный API уже отвечает. Для работы с ним используй ./jarvis threads chat.")
    children = []
    def stop(child, sig):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass

    def interrupt(_number, _frame):
        raise KeyboardInterrupt

    old_handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGTERM, signal.SIGHUP)}
    try:
        api = subprocess.Popen([*command, "serve"], env=service_env(), start_new_session=True)
        children.append(api)
        deadline = time.monotonic() + 15
        while not health():
            if api.poll() is not None or time.monotonic() >= deadline:
                raise ThreadsError("Локальный Threads API не запустился. Проверь вывод сервиса и порт 8000.")
            time.sleep(0.25)
        worker = subprocess.Popen([*command, "worker"], env=service_env(), start_new_session=True)
        children.append(worker)
        print("Threads Factory работает. Ctrl+C останавливает API и очередь.", flush=True)
        while all(child.poll() is None for child in children):
            time.sleep(0.25)
        raise ThreadsError("Один из процессов Threads Factory завершился. Проверь его вывод.")
    except KeyboardInterrupt:
        return
    finally:
        for child in reversed(children):
            stop(child, signal.SIGTERM)
        for child in reversed(children):
            try:
                child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                stop(child, signal.SIGKILL)
                child.wait()
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def run_threads(args, state_dir, root, binary, profile):
    path = integration_path(state_dir)
    if args.threads_action == "status":
        print(f"Установлено: {'да' if (path / 'threads_factory/cli.py').is_file() else 'нет'}")
        print(f"Локальная настройка: {'есть' if (path / '.env').is_file() else 'нужен ./jarvis threads setup'}")
        print(f"API на этом Mac: {'отвечает' if health() else 'остановлен'}")
        return 0

    git = binary("git")
    uv = binary("uv")
    if not git or not uv:
        raise ThreadsError("Для Threads Factory нужны git и uv. Инструкция установки uv: https://docs.astral.sh/uv/getting-started/installation/")
    if args.threads_action == "install":
        install(path, git, uv)
        return 0
    if not path.is_dir() or not (path / ".venv").is_dir():
        raise ThreadsError("Сначала выполни ./jarvis threads install.")
    require_verified_checkout(git, path)
    command = [uv, "--directory", str(path), "run", "--no-sync", "threads-factory"]
    if args.threads_action == "setup":
        return subprocess.run([*command, "init"], env=service_env(), check=False).returncode
    if not (path / ".env").is_file():
        raise ThreadsError("Введи свой ключ Upload-Post через ./jarvis threads setup.")
    if args.threads_action == "run":
        run_services(command)
        return 0

    if not health():
        raise ThreadsError("Сначала запусти ./jarvis threads run в отдельном терминале.")
    agent = args.agent or profile.get("assistant_provider", "auto")
    if agent not in ("codex", "claude"):
        agent = "codex" if binary("codex") else "claude"
    executable = binary(agent)
    if not executable:
        raise ThreadsError(f"Команда {agent} не найдена. Установи её и войди в свой аккаунт.")
    mcp_args = [*command[1:], "mcp"]
    if agent == "claude":
        config = {"mcpServers": {SERVER_NAME: {"command": uv, "args": mcp_args, "env": {"FACTORY_BASE_URL": LOCAL_API}}}}
        flags = ["--strict-mcp-config", "--mcp-config", json.dumps(config, ensure_ascii=False)]
    else:
        prefix = f"mcp_servers.{SERVER_NAME}"
        flags = ["-c", f"{prefix}.command={json.dumps(uv, ensure_ascii=False)}",
                 "-c", f"{prefix}.args={json.dumps(mcp_args, ensure_ascii=False)}",
                 "-c", f"{prefix}.env.FACTORY_BASE_URL={json.dumps(LOCAL_API)}"]
    return subprocess.run([executable, *flags, "--", CHAT_PROMPT], cwd=root, env=service_env(), check=False).returncode
