"""Answer simple social metrics questions from the last local stats snapshot."""

import datetime as dt
import re


_PLATFORMS = {
    "instagram": (r"instagram|инстаграмм?(?:а|е|у|ом)?|инст(?:а|е|у|ы|ой)", "В Instagram"),
    "youtube": (r"you\s*tube|ютью?б(?:а|е|у|ом)?|ютуб(?:а|е|у|ом)?", "На YouTube"),
    "telegram": (r"telegram|телеграмм?(?:а|е|у|ом)?|телег(?:а|е|у|и)|тг", "В Telegram"),
}
_METRICS = {
    "subscribers": r"подписчик(?:а|и|ов)?|участник(?:а|и|ов)?",
    "views": r"просмотр(?:а|ы|ов)?",
    "published": r"публикаци(?:я|и|й)|видео|ролик(?:а|и|ов)?|пост(?:а|ы|ов)?|опубликовано",
}
_STATISTICS = r"статистик(?:а|у|и|е|ой)|цифр(?:ы|ах)|показател(?:и|ей)"
_WEEK = r"за (?:последни[ех] )?(?:неделю|(?:семь|7) (?:дней|суток))"
_LIFETIME = r"за все время|за весь период"
_UNAVAILABLE = (
    r"сегодня|вчера|позавчера|за (?:(?:прошлую|прошлый|последнюю|последний|последние) )?"
    r"(?:ночь|сутки|день|вчера|месяц|год|неделю|\d+ (?:день|дня|дней|суток|недель|месяцев))|"
    r"нов(?:ых|ые|ого)|прирост|рост|добавилось|прибавилось|пришло|охват(?:а|ы|ов)?|"
    r"лайк(?:а|и|ов)?|комментари(?:й|и|ев)|рилс(?:а|ы|ов)?|reels|шортс(?:ы|ов)?|shorts"
)
_QUESTION_WORD = re.compile(
    r"jarvis|джарвис|джервис|привет|бро|а|и|или|в|во|на|по|у|мне|меня|нас|"
    r"мой|моя|мои|моих|моем|канал(?:а|е)?|аккаунт(?:а|е)?|профил(?:ь|е|я)|"
    r"дай|скажи|подскажи|расскажи|покажи|выведи|пожалуйста|сколько|какая|какие|как|"
    r"там|есть|всего|сейчас|текущ(?:ие|ая|ую)|актуальн(?:ая|ую|ые)|"
    r"соцсет(?:и|ях|ям|ей)|социальн(?:ых|ые)|сет(?:и|ях|ям|ей)|вышло|набралось|набрал[аи]?"
)
_MONTHS = ("января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа",
           "сентября", "октября", "ноября", "декабря")
_MAX_AGE = dt.timedelta(hours=24)


def _take(text, pattern):
    remaining, count = re.subn(r"\b(?:" + pattern + r")\b", " ", text)
    return " ".join(remaining.split()), bool(count)


def _date(value):
    if isinstance(value, str):
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        try:
            parsed = dt.datetime.fromisoformat(value)
            if parsed.utcoffset() is not None:
                return parsed.astimezone(dt.timezone.utc)
        except (ValueError, OverflowError):
            pass
    return None


def _day(value):
    return f"{value.day} {_MONTHS[value.month - 1]}"


def _count(value, one, few, many):
    last_digit = value % 10
    word = many
    if not 11 <= value % 100 <= 14:
        if last_digit == 1:
            word = one
        elif 2 <= last_digit <= 4:
            word = few
    return f"{value:,}".replace(",", " ") + " " + word


def _metric(row, name, period, today):
    value = row.get(name)
    if type(value) is not int or value < 0:
        return None
    if name == "views":
        stored_period = row.get("views_period")
        if period is not None and stored_period != period:
            return None
        count = _count(value, "просмотр", "просмотра", "просмотров")
        if row["platform"] == "youtube" and stored_period == "lifetime":
            return f"{count} за всё время"
        if row["platform"] == "instagram" and stored_period == "7d":
            start, end = _date(row.get("views_from")), _date(row.get("views_to"))
            if start == today - dt.timedelta(days=7) and end == today:
                return f"{count} за семь завершившихся дней по UTC"
        return None
    if period is not None or row.get("period") != "current":
        return None
    if name == "subscribers":
        if row["platform"] == "telegram":
            return _count(value, "участник", "участника", "участников")
        return _count(value, "подписчик", "подписчика", "подписчиков")
    if row["platform"] == "youtube":
        return _count(value, "видео", "видео", "видео")
    if row["platform"] == "instagram":
        return _count(value, "публикация", "публикации", "публикаций")
    return None


def cached_answer(question: str, snapshot: dict, now: dt.datetime | None = None) -> str | None:
    """Return a factual local reply, or None for requests outside simple stats."""
    if not isinstance(question, str):
        return None
    remaining = " ".join(re.findall(r"\w+", question.casefold().replace("ё", "е")))
    platforms, metrics = [], []
    for platform, (pattern, _) in _PLATFORMS.items():
        remaining, found = _take(remaining, pattern)
        if found:
            platforms.append(platform)
    for metric, pattern in _METRICS.items():
        remaining, found = _take(remaining, pattern)
        if found:
            metrics.append(metric)
    remaining, overview = _take(remaining, _STATISTICS)
    remaining, week = _take(remaining, _WEEK)
    remaining, lifetime = _take(remaining, _LIFETIME)
    remaining, unavailable = _take(remaining, _UNAVAILABLE)
    if any(not _QUESTION_WORD.fullmatch(word) for word in remaining.split()):
        return None
    if not (metrics or overview or (platforms and unavailable)):
        return None
    if not (overview or platforms or "сколько" in remaining.split()):
        return None
    if len(platforms) > 1 and len(metrics) > 1:
        return None
    if unavailable or (week and lifetime):
        return "В сохранённой статистике Jarvis нет такого показателя или периода."

    utc_now = (now or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone.utc)
    local_zone = now.tzinfo if now is not None and now.utcoffset() is not None else None
    snapshot = snapshot if isinstance(snapshot, dict) else {}
    updated = _date(snapshot.get("as_of"))
    refresh = "Обнови статистику в пульте Jarvis."
    if updated is None or updated > utc_now:
        return f"Нет сохранённой статистики с проверяемым временем обновления. {refresh}"
    local_update = updated.astimezone(local_zone)
    day = _day(local_update)
    if local_update.year != utc_now.astimezone(local_zone).year:
        day += f" {local_update.year} года"
    date = f"{day} в {local_update:%H:%M} по местному времени"
    if utc_now - updated > _MAX_AGE:
        return f"Сохранённая статистика устарела. Последнее обновление — {date}. {refresh}"

    period = "7d" if week else "lifetime" if lifetime else None
    today = utc_now.replace(hour=0, minute=0, second=0, microsecond=0)
    raw_rows = snapshot.get("stats")
    rows = {row["platform"]: row for row in raw_rows if isinstance(row, dict) and
            isinstance(row.get("platform"), str) and row["platform"] in _PLATFORMS} if isinstance(raw_rows, list) else {}
    selected = platforms or list(_PLATFORMS)
    requested = metrics or list(_METRICS)
    replies, missing = [], []
    for platform in selected:
        row = rows.get(platform, {})
        label = _PLATFORMS[platform][1]
        available = []
        if row.get("connected") is True and row.get("state", "connected") == "connected":
            available = [result for metric in requested if (result := _metric(row, metric, period, today)) is not None]
        if available:
            replies.append(f"{label} {', '.join(available)}.")
        if platforms and (not available or (metrics and len(available) != len(metrics))):
            missing.append(f"{label} часть запрошенных данных отсутствует." if available else
                           f"{label} запрошенных данных в кэше нет.")
    if not replies:
        return " ".join([*(missing or ["Запрошенных данных в кэше нет."]), refresh])
    return " ".join([*replies, *missing, f"Данные обновлены {date}."])
