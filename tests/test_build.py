"""Тесты генератора: python -m unittest discover -s tests"""

import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import build  # noqa: E402

HEADER = """
[site]
host = "projects.example.ru"
title = "Проекты"
lead = "Витрина."
redirects = ["example.ru"]

[[category]]
id = "tools"
title = "Инструменты"
"""


def registry(projects: str) -> build.Registry:
    """Собирает реестр из фрагмента TOML с проектами."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "projects.toml"
        path.write_text(HEADER + textwrap.dedent(projects), encoding="utf-8")
        return build.load_registry(path)


class RealRegistryTest(unittest.TestCase):
    def test_repository_registry_is_valid(self):
        reg = build.load_registry()
        self.assertTrue(reg.projects)
        for p in reg.projects:
            if not p.hidden:
                self.assertTrue(p.links(), p.id)


class ValidationTest(unittest.TestCase):
    def assertRejected(self, projects: str, fragment: str):
        with self.assertRaises(build.RegistryError) as ctx:
            registry(projects)
        self.assertIn(fragment, str(ctx.exception))

    def test_unknown_field_is_a_typo(self):
        self.assertRejected(
            """
            [[project]]
            id = "foo"
            title = "Foo"
            description = "d"
            category = "tools"
            web = "foo.example.ru"
            upstrem = "foo:80"
            """,
            "upstrem",
        )

    def test_host_cannot_be_taken_twice(self):
        self.assertRejected(
            """
            [[project]]
            id = "foo"
            title = "Foo"
            description = "d"
            category = "tools"
            web = "foo.example.ru"
            upstream = "foo:80"

            [[project]]
            id = "bar"
            title = "Bar"
            description = "d"
            category = "tools"
            web = "bar.example.ru"
            upstream = "bar:80"
            aliases = ["foo.example.ru"]
            """,
            "уже занят",
        )

    def test_site_needs_upstream_or_static_deploy(self):
        self.assertRejected(
            """
            [[project]]
            id = "foo"
            title = "Foo"
            description = "d"
            category = "tools"
            web = "foo.example.ru"
            """,
            "ровно одно из двух",
        )

    def test_unknown_category(self):
        self.assertRejected(
            """
            [[project]]
            id = "foo"
            title = "Foo"
            description = "d"
            category = "games"
            rustore = "com.example.foo"
            """,
            "нет категории",
        )

    def test_visible_project_needs_a_link(self):
        self.assertRejected(
            """
            [[project]]
            id = "foo"
            title = "Foo"
            description = "d"
            category = "tools"
            """,
            "нужна ссылка",
        )

    def test_repository_is_deployed_once(self):
        self.assertRejected(
            """
            [[project]]
            id = "foo"
            title = "Foo"
            description = "d"
            category = "tools"
            web = "foo.example.ru"
            upstream = "foo:80"

            [project.deploy]
            repo = "sites_configs"
            """,
            "уже разворачивается",
        )


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.reg = registry(
            """
            [[project]]
            id = "static"
            title = "Тренажёр, 2 класс"
            description = "Упражнения по учебнику <b>Моро</b>."
            category = "tools"
            web = "static.example.ru"

            [project.deploy]
            repo = "static_repo"
            mode = "static"

            [[project]]
            id = "full"
            title = "Full"
            description = "Фронтенд и API."
            category = "tools"
            web = "full.example.ru"
            upstream = "full-frontend:3000"
            api = "full-backend:8000"
            aliases = ["old.example.ru"]
            rustore = "com.example.full"

            [project.deploy]
            repo = "Full"
            branch = "master"

            [[project]]
            id = "app"
            title = "App"
            description = "Только в RuStore."
            category = "tools"
            rustore = "com.example.app"
            """
        )

    def test_caddyfile(self):
        caddy = build.render_caddyfile(self.reg)
        self.assertIn("projects.example.ru {\n\timport showcase\n}", caddy)
        self.assertIn("example.ru {\n\tredir https://projects.example.ru{uri} permanent\n}", caddy)
        self.assertIn("static.example.ru {\n\timport static_site static_repo\n}", caddy)
        self.assertIn("\timport proxy_with_api full-frontend:3000 full-backend:8000", caddy)
        self.assertIn("old.example.ru {\n\tredir https://full.example.ru{uri} permanent\n}", caddy)
        self.assertNotIn("com.example.app", caddy)

    def test_static_mounts_and_deploy_list(self):
        self.assertIn("../static_repo:/srv/static/static_repo:ro", build.render_static_compose(self.reg))
        rows = build.render_deploy_list(self.reg).splitlines()
        self.assertIn("sites_configs|self|main|docker-compose.yml,compose.static.yml", rows)
        self.assertIn("static_repo|static|main|", rows)
        self.assertIn("Full|image|master|docker-compose.prod.yml", rows)

    def test_index(self):
        page = build.render_index(self.reg)
        self.assertIn('href="https://full.example.ru/">Full</a>', page)
        self.assertIn('href="https://www.rustore.ru/catalog/app/com.example.full">Версия для Android в&nbsp;RuStore', page)
        self.assertIn('href="https://www.rustore.ru/catalog/app/com.example.app">App</a>', page)
        self.assertIn("Тренажёр, 2&nbsp;класс", page)
        self.assertIn("&lt;b&gt;Моро&lt;/b&gt;", page)
        self.assertNotIn("<b>Моро</b>", page)

    def test_output_is_stable(self):
        self.assertEqual(build.render_index(self.reg), build.render_index(self.reg))


class ProseTest(unittest.TestCase):
    def test_short_words_and_numbers_stick_to_the_next_word(self):
        self.assertEqual(build._prose("в браузере, 3–12 лет"), "в&nbsp;браузере, 3–12&nbsp;лет")

    def test_long_words_and_hyphenated_parts_are_untouched(self):
        self.assertEqual(build._prose("Канбан-доска для всех"), "Канбан-доска для всех")


if __name__ == "__main__":
    unittest.main()
