#!/usr/bin/env python3
"""Генерирует конфигурацию сервера и витрину из projects.toml.

    python build.py           пересобрать файлы
    python build.py --check   только проверить, что файлы актуальны (для CI)

Результат:
    caddy/Caddyfile       маршруты Caddy (общие сниппеты — в caddy/snippets.caddy)
    compose.static.yml    монтирование статических сайтов в контейнер Caddy
    deploy.list           что и как разворачивает deploy.sh
    site/index.html       витрина

Зависимостей нет: реестр читается стандартным tomllib (Python 3.11+).
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from string import Template
from typing import Any
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
REGISTRY = ROOT / "projects.toml"
SITE_DIR = ROOT / "site"

NOTICE = "СГЕНЕРИРОВАНО build.py из projects.toml — не редактируйте вручную."

# Сам sites_configs deploy.sh разворачивает отдельно, перед любым проектом, поэтому
# в deploy.list его нет, а имя занято: проект с таким репозиторием был бы развёрнут дважды.
SELF_REPO = "sites_configs"

DEPLOY_MODES = ("image", "build", "static")
DEFAULT_COMPOSE = "docker-compose.prod.yml"
STATIC_ROOT = "/srv/static"
RUSTORE_URL = "https://www.rustore.ru/catalog/app/{package}"

ID_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
HOST_RE = re.compile(r"(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")
UPSTREAM_RE = re.compile(r"[a-z0-9][a-z0-9_.-]*:[0-9]{1,5}")
PACKAGE_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+")
REPO_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
BRANCH_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]*")
RELPATH_RE = re.compile(r"(?!/)(?!.*(^|/)\.\.(/|$))[A-Za-z0-9._/-]+")
ICON_RE = re.compile(r"[a-z0-9][a-z0-9._-]*\.(svg|png|webp)")


class RegistryError(Exception):
    """Ошибка в projects.toml; текст говорит, что и где исправить."""


# ── Модель ───────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Site:
    host: str
    title: str
    lead: str
    redirects: tuple[str, ...]
    github: str | None


@dataclass(frozen=True)
class Category:
    id: str
    title: str


@dataclass(frozen=True)
class Deploy:
    repo: str
    mode: str
    branch: str
    compose: str | None  # None — значение по умолчанию для режима

    @property
    def compose_file(self) -> str:
        return "" if self.mode == "static" else (self.compose or DEFAULT_COMPOSE)


@dataclass(frozen=True)
class Link:
    url: str
    where: str  # подпись под названием, когда ссылка основная
    label: str  # текст ссылки, когда она дополнительная


@dataclass(frozen=True)
class Project:
    id: str
    title: str
    description: str
    category: str
    icon: str | None
    mark: str | None
    hidden: bool
    web: str | None
    upstream: str | None
    api: str | None
    aliases: tuple[str, ...]
    url: str | None
    rustore: str | None
    deploy: Deploy | None

    @property
    def is_static(self) -> bool:
        return self.deploy is not None and self.deploy.mode == "static"

    def links(self) -> list[Link]:
        """Ссылки записи на витрине. Первая — основная: на неё ведёт название."""
        links = []
        if self.web:
            links.append(Link(f"https://{self.web}/", self.web, f"Сайт {self.web}"))
        if self.url:
            host = urlsplit(self.url).hostname or self.url
            links.append(Link(self.url, host, f"Сайт {host}"))
        if self.rustore:
            links.append(
                Link(
                    RUSTORE_URL.format(package=self.rustore),
                    "Приложение для Android в RuStore",
                    "Версия для Android в RuStore",
                )
            )
        return links


@dataclass(frozen=True)
class Registry:
    site: Site
    categories: tuple[Category, ...]
    projects: tuple[Project, ...]


# ── Чтение реестра ───────────────────────────────────────────────────────────

SITE_FIELDS = {"host": str, "title": str, "lead": str, "redirects": list, "github": str}
CATEGORY_FIELDS = {"id": str, "title": str}
PROJECT_FIELDS = {
    "id": str,
    "title": str,
    "description": str,
    "category": str,
    "icon": str,
    "mark": str,
    "hidden": bool,
    "web": str,
    "upstream": str,
    "api": str,
    "aliases": list,
    "url": str,
    "rustore": str,
    "deploy": dict,
}
DEPLOY_FIELDS = {"repo": str, "mode": str, "compose": str, "branch": str}
KIND_NAMES = {str: "строкой", list: "списком строк", bool: "true или false", dict: "таблицей"}


def _fields(table: Any, where: str, schema: dict[str, type], required: set[str]) -> dict[str, Any]:
    """Проверяет состав и типы полей таблицы: опечатка в имени поля — ошибка, а не тишина."""
    if not isinstance(table, dict):
        raise RegistryError(f"{where}: ожидается таблица")
    unknown = sorted(table.keys() - schema.keys())
    if unknown:
        raise RegistryError(f"{where}: неизвестные поля {', '.join(unknown)} — опечатка?")
    missing = sorted(required - table.keys())
    if missing:
        raise RegistryError(f"{where}: не хватает полей {', '.join(missing)}")
    for key, value in table.items():
        kind = schema[key]
        ok = isinstance(value, kind) and (kind is not list or all(isinstance(v, str) for v in value))
        if not ok:
            raise RegistryError(f"{where}: поле {key} должно быть {KIND_NAMES[kind]}")
    return table


def _array(data: dict[str, Any], key: str) -> list[Any]:
    value = data.get(key)
    if not isinstance(value, list) or not value:
        raise RegistryError(f"projects.toml: нужна хотя бы одна таблица [[{key}]]")
    return value


def _parse_project(table: Any, index: int) -> Project:
    where = f"[[project]] №{index}"
    if isinstance(table, dict) and isinstance(table.get("id"), str):
        where = f"проект {table['id']}"
    t = _fields(table, where, PROJECT_FIELDS, {"id", "title", "category"})

    deploy = None
    if "deploy" in t:
        d = _fields(t["deploy"], f"{where}, [project.deploy]", DEPLOY_FIELDS, {"repo"})
        deploy = Deploy(
            repo=d["repo"],
            mode=d.get("mode", "image"),
            branch=d.get("branch", "main"),
            compose=d.get("compose"),
        )

    return Project(
        id=t["id"],
        title=t["title"],
        description=t.get("description", ""),
        category=t["category"],
        icon=t.get("icon"),
        mark=t.get("mark"),
        hidden=t.get("hidden", False),
        web=t.get("web"),
        upstream=t.get("upstream"),
        api=t.get("api"),
        aliases=tuple(t.get("aliases", ())),
        url=t.get("url"),
        rustore=t.get("rustore"),
        deploy=deploy,
    )


def load_registry(path: Path = REGISTRY) -> Registry:
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise RegistryError(f"{path.name}: {exc}") from None

    unknown = sorted(data.keys() - {"site", "category", "project"})
    if unknown:
        raise RegistryError(f"projects.toml: неизвестные разделы {', '.join(unknown)}")
    s = _fields(data.get("site"), "[site]", SITE_FIELDS, {"host", "title", "lead"})
    site = Site(
        host=s["host"],
        title=s["title"],
        lead=s["lead"],
        redirects=tuple(s.get("redirects", ())),
        github=s.get("github"),
    )
    categories = tuple(
        Category(**_fields(c, f"[[category]] №{i}", CATEGORY_FIELDS, {"id", "title"}))
        for i, c in enumerate(_array(data, "category"), 1)
    )
    projects = tuple(_parse_project(p, i) for i, p in enumerate(_array(data, "project"), 1))

    registry = Registry(site, categories, projects)
    problems = validate(registry)
    if problems:
        raise RegistryError("\n".join(problems))
    return registry


# ── Проверки ─────────────────────────────────────────────────────────────────


def validate(reg: Registry) -> list[str]:
    """Собирает все смысловые ошибки сразу, чтобы не чинить их по одной за запуск."""
    problems: list[str] = []
    owners: dict[str, str] = {}  # домен → кто его уже занял

    def bad(where: str, message: str) -> None:
        problems.append(f"{where}: {message}")

    def claim(host: str, where: str) -> None:
        if not HOST_RE.fullmatch(host):
            bad(where, f"некорректный домен {host!r}")
        elif host in owners:
            bad(where, f"домен {host} уже занят ({owners[host]})")
        else:
            owners[host] = where

    site = reg.site
    claim(site.host, "[site]")
    for host in site.redirects:
        claim(host, "[site] redirects")
    if site.github is not None and not REPO_RE.fullmatch(site.github):
        bad("[site]", f"github: некорректное имя пользователя {site.github!r}")

    category_ids = [c.id for c in reg.categories]
    for cid in sorted({c for c in category_ids if category_ids.count(c) > 1}):
        bad("[[category]]", f"id {cid!r} встречается несколько раз")

    seen_ids: set[str] = set()
    repos: dict[str, str] = {SELF_REPO: "сам sites_configs"}
    for p in reg.projects:
        where = f"проект {p.id}"
        if not ID_RE.fullmatch(p.id):
            bad(where, "id — только строчная латиница, цифры и дефис")
        if p.id in seen_ids:
            bad(where, "id повторяется")
        seen_ids.add(p.id)
        if p.category not in category_ids:
            bad(where, f"нет категории {p.category!r}")

        if p.web:
            claim(p.web, where)
            if p.is_static == bool(p.upstream):
                bad(where, "для web нужно ровно одно из двух: upstream или deploy.mode = static")
            for alias in p.aliases:
                claim(alias, f"{where}, aliases")
        else:
            for key in ("upstream", "api", "aliases"):
                if getattr(p, key):
                    bad(where, f"{key} имеет смысл только вместе с web")
            if p.is_static:
                bad(where, "deploy.mode = static без web: Caddy нечего раздавать")
        if p.api and not p.upstream:
            bad(where, "api задаётся только вместе с upstream")
        for key in ("upstream", "api"):
            value = getattr(p, key)
            if value and not UPSTREAM_RE.fullmatch(value):
                bad(where, f"{key}: ожидается «контейнер:порт», получено {value!r}")

        if p.url and not re.fullmatch(r"https://[^\s\"'<>]+", p.url):
            bad(where, "url должен начинаться с https:// и не содержать пробелов и кавычек")
        if p.rustore and not PACKAGE_RE.fullmatch(p.rustore):
            bad(where, f"rustore: некорректный package name {p.rustore!r}")
        if p.icon:
            if not ICON_RE.fullmatch(p.icon):
                bad(where, "icon — имя файла .svg/.png/.webp из строчных латинских букв")
            elif not (SITE_DIR / "icons" / p.icon).is_file():
                bad(where, f"нет файла site/icons/{p.icon}")
        if p.mark is not None and not 1 <= len(p.mark) <= 3:
            bad(where, "mark — от одного до трёх символов")
        if not p.hidden:
            if not p.description:
                bad(where, "у проекта на витрине должно быть description")
            if not p.links():
                bad(where, "на витрине нужна ссылка: web, url или rustore (или hidden = true)")

        if d := p.deploy:
            if d.mode not in DEPLOY_MODES:
                bad(where, f"deploy.mode — одно из: {', '.join(DEPLOY_MODES)}")
            if not REPO_RE.fullmatch(d.repo):
                bad(where, f"deploy.repo: некорректное имя репозитория {d.repo!r}")
            elif d.repo in repos:
                bad(where, f"репозиторий {d.repo} уже разворачивается ({repos[d.repo]})")
            repos[d.repo] = where
            if not BRANCH_RE.fullmatch(d.branch):
                bad(where, f"deploy.branch: некорректное имя ветки {d.branch!r}")
            if d.compose is not None:
                if d.mode == "static":
                    bad(where, "deploy.compose не нужен статическому сайту")
                elif not RELPATH_RE.fullmatch(d.compose):
                    bad(where, "deploy.compose — относительный путь внутри репозитория")
    return problems


def lint_siblings(reg: Registry) -> list[str]:
    """Сверяет реестр с соседними репозиториями, если они лежат рядом (только локально).

    Это предупреждения, а не ошибки: локальная копия может быть на другой ветке.
    """
    warnings = []
    for p in reg.projects:
        d = p.deploy
        if not d or d.mode == "static":
            continue
        repo_dir = ROOT.parent / d.repo
        compose = repo_dir / d.compose_file
        if not repo_dir.is_dir():
            continue
        if not compose.is_file():
            warnings.append(f"{p.id}: в {d.repo} нет файла {d.compose_file}")
            continue
        text = compose.read_text(encoding="utf-8", errors="replace")
        for upstream in filter(None, (p.upstream, p.api)):
            container = upstream.split(":", 1)[0]
            if not re.search(rf"^\s*container_name:\s*[\"']?{re.escape(container)}[\"']?\s*$", text, re.M):
                warnings.append(
                    f"{p.id}: в {d.repo}/{d.compose_file} нет container_name: {container} — Caddy его не найдёт"
                )
        if re.search(r"^\s*ports:", text, re.M):
            warnings.append(f"{p.id}: в {d.repo}/{d.compose_file} есть ports — Caddy ходит через сеть web, порты не нужны")
        if d.mode == "image" and "IMAGE_TAG" not in text:
            warnings.append(
                f"{p.id}: {d.repo}/{d.compose_file} не использует ${{IMAGE_TAG}} — "
                "deploy.sh не сможет выкатить конкретный коммит"
            )
    return warnings


# ── Caddyfile, compose.static.yml, deploy.list ───────────────────────────────


def _redirect(sources: tuple[str, ...], target: str) -> list[str]:
    return [f"{', '.join(sources)} {{", f"\tredir https://{target}{{uri}} permanent", "}", ""]


def render_caddyfile(reg: Registry) -> str:
    out = [
        f"# {NOTICE}",
        "# Общие сниппеты правятся руками в snippets.caddy.",
        "",
        "import snippets.caddy",
        "",
        "# Витрина",
        f"{reg.site.host} {{",
        "\timport showcase",
        "}",
        "",
    ]
    if reg.site.redirects:
        out += _redirect(reg.site.redirects, reg.site.host)

    for category in reg.categories:
        routed = [p for p in reg.projects if p.category == category.id and p.web]
        if not routed:
            continue
        out += [f"# {category.title}", ""]
        for p in routed:
            if p.is_static:
                body = f"import static_site {p.deploy.repo}"
            elif p.api:
                body = f"import proxy_with_api {p.upstream} {p.api}"
            else:
                body = f"import proxy {p.upstream}"
            out += [f"{p.web} {{", f"\t{body}", "}", ""]
            if p.aliases:
                out += _redirect(p.aliases, p.web)
    return "\n".join(out).rstrip("\n") + "\n"


def render_static_compose(reg: Registry) -> str:
    repos = [p.deploy.repo for p in reg.projects if p.is_static]
    lines = [
        f"# {NOTICE}",
        "# Статические сайты: репозитории монтируются в контейнер Caddy только для чтения.",
        "services:",
    ]
    if not repos:
        return "\n".join(lines + ["  caddy: {}"]) + "\n"
    lines += ["  caddy:", "    volumes:"]
    lines += [f"      - ../{repo}:{STATIC_ROOT}/{repo}:ro" for repo in repos]
    return "\n".join(lines) + "\n"


def render_deploy_list(reg: Registry) -> str:
    rows = [
        f"# {NOTICE}",
        "# репозиторий|режим|ветка|compose-файлы через запятую",
    ]
    for p in reg.projects:
        if d := p.deploy:
            rows.append(f"{d.repo}|{d.mode}|{d.branch}|{d.compose_file}")
    return "\n".join(rows) + "\n"


# ── Витрина ──────────────────────────────────────────────────────────────────

PAGE = Template("""\
<!doctype html>
<!-- $notice -->
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<meta name="description" content="$lead">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#fdfeff" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#1f3a30" media="(prefers-color-scheme: dark)">
<link rel="canonical" href="$canonical">
<meta property="og:type" content="website">
<meta property="og:locale" content="ru_RU">
<meta property="og:title" content="$title">
<meta property="og:description" content="$lead">
<meta property="og:url" content="$canonical">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="preload" href="/fonts/caveat-cyrillic.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/style.css?v=$css_version">
<script type="application/ld+json">$json_ld</script>
</head>
<body>
<main class="sheet">
  <header class="masthead">
    <h1>$title</h1>
    <p class="lead">$lead_prose</p>
  </header>
$sections
$footer</main>
</body>
</html>
""")


def _e(text: str) -> str:
    return html.escape(text, quote=True)


# Короткое слово или число не должно оставаться в конце строки: «в браузере», «2 класс».
NBSP_AFTER = re.compile(r"(?<![\w-])(\w{1,2}|\d+)\s+(?=\w)")


def _prose(text: str) -> str:
    """Экранирует текст для HTML и расставляет неразрывные пробелы."""
    return _e(NBSP_AFTER.sub(lambda m: m.group(1) + " ", text)).replace(" ", "&nbsp;")


def _file_version(path: Path) -> str:
    data = path.read_bytes().replace(b"\r\n", b"\n")  # одинаковый хеш на Windows и Linux
    return hashlib.sha256(data).hexdigest()[:10]


def render_entry(p: Project) -> str:
    primary, *extra = p.links()
    if p.icon:
        icon = (
            f'<img class="entry-icon" src="/icons/{_e(p.icon)}" alt="" '
            'width="72" height="72" loading="lazy" decoding="async">'
        )
    else:
        icon = f'<span class="entry-icon entry-mark" aria-hidden="true">{_e(p.mark or p.title[0])}</span>'
    lines = [
        '      <li class="entry">',
        f"        {icon}",
        '        <div class="entry-body">',
        f'          <h3 class="entry-title"><a class="entry-link" href="{_e(primary.url)}">{_prose(p.title)}</a></h3>',
        f'          <p class="entry-where">{_prose(primary.where)}</p>',
        f'          <p class="entry-text">{_prose(p.description)}</p>',
    ]
    for link in extra:
        lines.append(f'          <p class="entry-more"><a href="{_e(link.url)}">{_prose(link.label)}</a></p>')
    lines += ["        </div>", "      </li>"]
    return "\n".join(lines)


def render_index(reg: Registry) -> str:
    site = reg.site
    canonical = f"https://{site.host}/"
    visible = [p for p in reg.projects if not p.hidden]

    sections = []
    for category in reg.categories:
        items = [p for p in visible if p.category == category.id]
        if not items:
            continue
        heading_id = f"cat-{category.id}"
        entries = "\n".join(render_entry(p) for p in items)
        sections.append(
            f'  <section class="subject" aria-labelledby="{heading_id}">\n'
            f'    <h2 id="{heading_id}">{_e(category.title)}</h2>\n'
            f'    <ul class="entries">\n{entries}\n    </ul>\n'
            "  </section>"
        )

    footer = ""
    if site.github:
        profile = f"https://github.com/{site.github}"
        footer = (
            '  <footer class="colophon">\n'
            f'    <p><a href="{_e(profile)}">{_e(site.github)} на GitHub</a></p>\n'
            "  </footer>\n"
        )

    json_ld = {
        "@context": "https://schema.org",
        "@type": "ItemList",
        "name": site.title,
        "url": canonical,
        "itemListElement": [
            {"@type": "ListItem", "position": i, "name": p.title, "url": p.links()[0].url}
            for i, p in enumerate(visible, 1)
        ],
    }
    json_text = json.dumps(json_ld, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")

    return PAGE.substitute(
        notice=NOTICE,
        title=_e(site.title),
        lead=_e(site.lead),
        lead_prose=_prose(site.lead),
        canonical=_e(canonical),
        css_version=_file_version(SITE_DIR / "style.css"),
        json_ld=json_text,
        sections="\n\n".join(sections),
        footer=footer,
    )


# ── Точка входа ──────────────────────────────────────────────────────────────


def _read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").replace("\r\n", "\n")
    except FileNotFoundError:
        return None


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(errors="backslashreplace")  # консоль Windows не знает часть символов

    parser = argparse.ArgumentParser(description="Генерирует конфигурацию и витрину из projects.toml.")
    parser.add_argument("--check", action="store_true", help="не писать файлы, а проверить их актуальность")
    args = parser.parse_args(argv)

    try:
        registry = load_registry()
    except RegistryError as exc:
        print(f"Ошибки в projects.toml:\n{exc}", file=sys.stderr)
        return 2
    for warning in lint_siblings(registry):
        print(f"предупреждение: {warning}", file=sys.stderr)

    outputs = {
        ROOT / "caddy" / "Caddyfile": render_caddyfile(registry),
        ROOT / "compose.static.yml": render_static_compose(registry),
        ROOT / "deploy.list": render_deploy_list(registry),
        SITE_DIR / "index.html": render_index(registry),
    }
    stale = [path for path, text in outputs.items() if _read(path) != text]

    if args.check:
        if stale:
            print("Сгенерированные файлы отстали от реестра. Запустите python build.py и закоммитьте:", file=sys.stderr)
            for path in stale:
                print(f"  {path.relative_to(ROOT).as_posix()}", file=sys.stderr)
            return 1
        print("Сгенерированные файлы актуальны.")
        return 0

    for path in stale:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(outputs[path], encoding="utf-8", newline="\n")
        print(f"обновлён {path.relative_to(ROOT).as_posix()}")
    if not stale:
        print("Всё актуально, файлы не менялись.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
