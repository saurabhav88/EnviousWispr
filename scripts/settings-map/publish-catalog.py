#!/usr/bin/env python3
"""Publishes the Settings Map to the local product catalog's macOS screen map (#3482).

  publish-catalog.py --catalog ~/.claude/knowledge/enviouswispr --revision <sha>
      Dry run: builds the migration from the export committed at <sha>, applies it to a
      disposable copy of catalog.db and to a full rebuild in a copy of the catalog folder, and
      reports what it preserves. Writes nothing in the catalog.
  publish-catalog.py --catalog ... --revision <sha> --write
      The same checks, then writes data/NNN-macos-settings-map-<date>.sql and runs the
      catalog's own rebuild.sh. Run it only at the session wind-down catalog step
      (session-behavior.md RULE: winddown-five-step), after the change's review gates.
  publish-catalog.py --self-test
      Offline checks on a tiny catalog.

Never run by export.sh or CI. Inputs at <sha>: reference/settings-map.json (the export) and
scripts/settings-map/catalog-surfaces.json (the one map-id-to-surface-slug mapping). The
migration:
  - adds or refreshes one evidence row per mapped surface, key ui-map-<slug>, naming its map ids
    and citing the map declaration at <sha> and the export hash;
  - inserts the surfaces the mapping declares new (newSurfaces), each pointing at its ui-map
    evidence; it updates no other ui_surface row and touches no setting_surface row;
  - deletes only the ui-map evidence rows of slugs the mapping no longer owns, listed by key.
"""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
EXPORT = "reference/settings-map.json"
MAPPING = "scripts/settings-map/catalog-surfaces.json"
MAP_FILE = "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift"
ID_FILE = "Sources/EnviousWisprAppKit/Views/Settings/SettingsMapID.swift"
KINDS = {"window", "menu", "sidebar_group", "page", "section", "control", "sheet", "step", "menu_item"}


class PublishError(Exception):
    pass


def git_show(revision, path):
    try:
        return subprocess.run(["git", "-C", str(REPO), "show", f"{revision}:{path}"],
                              check=True, capture_output=True).stdout
    except subprocess.CalledProcessError as error:
        raise PublishError(f"{path} is not at {revision}: {error.stderr.decode().strip()}")


def quote(value):
    if value is None:
        return "NULL"
    if isinstance(value, int):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def declaration_lines(map_source, id_source, parents, choices):
    """Map raw id -> (file, line, producer) of the code that builds the node at the pinned
    revision: its literal `id: .case` in SettingsMap.swift, or, for a generated choice, the
    `choices(of: .parentCase, ...)` call that builds its family (else the one shared choice
    constructor). SettingsMapID.swift only spells an id, so it is never cited."""
    cases = {}
    for line in id_source.splitlines():
        match = re.search(r'case (\w+) = "([^"]+)"', line)
        if match:
            cases[match.group(2)] = match.group(1)
    map_lines = map_source.splitlines()
    generators = [n for n, text in enumerate(map_lines, 1)
                  if re.search(r"\bid:\s*id,\s*structure:\s*\.item,\s*item:\s*\.choice\b", text)]
    found = {}
    for raw, case in cases.items():
        pattern = re.compile(r"(id: \.|\(\.)" + re.escape(case) + r"\b")
        line = next((n for n, text in enumerate(map_lines, 1) if pattern.search(text)), None)
        if line is not None:
            found[raw] = (MAP_FILE, line, "node")
            continue
        parent_case = cases.get(parents.get(raw) or "")
        family = [n for n, text in enumerate(map_lines, 1)
                  if parent_case and re.search(r"\bof: \." + re.escape(parent_case) + r",", text)]
        if raw in choices and len(family) == 1:
            found[raw] = (MAP_FILE, family[0], f"choices(of: .{parent_case})")
        elif raw in choices and len(generators) == 1:
            found[raw] = (MAP_FILE, generators[0], "SettingsMap.choices (shared choice producer)")
        else:
            raise PublishError(f"{raw}: no unique verified map-node producer")
    return found


def plan(export, mapping, connection, declarations, revision, export_hash, date):
    """The migration's statements and the populations it owns."""
    node_ids = [n["id"] for n in export["nodes"]]
    labels = {}
    for n in export["nodes"]:
        title = n["title"]
        labels[n["id"]] = title.get("en") or title.get("text") or "{" + title.get("resolver", "?") + "}"
    surfaces = mapping["surfaces"]
    new = mapping.get("newSurfaces", {})
    mapped = [i for ids in surfaces.values() for i in ids]
    if sorted(mapped) != sorted(set(mapped)):
        raise PublishError("a map id is mapped to two surfaces")
    if set(mapped) != set(node_ids):
        missing = sorted(set(node_ids) - set(mapped))
        unknown = sorted(set(mapped) - set(node_ids))
        raise PublishError(f"mapping out of step with the export: unmapped {missing[:5]}, unknown {unknown[:5]}")

    existing = {row[0]: row for row in connection.execute(
        "SELECT surface_slug, platform_key, parent_surface_slug, surface_kind, user_label, position, "
        "evidence_key FROM ui_surface")}
    # A declared-new surface is inserted once; on a later run it already exists, and is reused
    # only if it is exactly the owned definition.
    pending_new = {}
    for slug in surfaces:
        if slug in new:
            spec = new[slug]
            if spec["kind"] not in KINDS:
                raise PublishError(f"{slug}: unknown kind {spec['kind']}")
            parent = spec["parent"]
            if parent not in existing and parent not in new:
                raise PublishError(f"{slug}: parent {parent} does not exist")
            if parent in existing and existing[parent][1] != "macos":
                raise PublishError(f"{slug}: parent {parent} is not macOS")
            if slug in existing:
                row = existing[slug]
                if (row[1] != "macos" or row[2] != parent or row[3] != spec["kind"]
                        or row[4] != spec["label"] or row[6] != f"ui-map-{slug}"):
                    raise PublishError(f"{slug}: existing surface differs from the owned definition")
            else:
                pending_new[slug] = spec
        elif slug not in existing:
            raise PublishError(f"{slug} is not an existing surface and not declared new")
        elif existing[slug][1] != "macos":
            raise PublishError(f"{slug} is not a macOS surface")
    for slug in new:
        if slug not in surfaces:
            raise PublishError(f"{slug} is declared new but no map id uses it")

    statements = []
    owned_keys = []
    for slug, ids in surfaces.items():
        key = f"ui-map-{slug}"
        owned_keys.append(key)
        file_path, line, producer = declarations[ids[0]]
        symbol = ("SettingsMap ids: " if producer == "node" else f"{producer} ids: ") + ", ".join(ids)
        statements.append(
            "INSERT INTO evidence (evidence_key, evidence_kind, repository, revision, file_path, "
            "symbol_or_anchor, line_start, line_end, excerpt, verified_at) VALUES ("
            + ", ".join(quote(v) for v in (
                key, "code", "EnviousWispr", revision, file_path,
                symbol, line, line,
                f"settings-map export sha256 {export_hash}", date))
            + ") ON CONFLICT(evidence_key) DO UPDATE SET revision = excluded.revision, "
            "file_path = excluded.file_path, symbol_or_anchor = excluded.symbol_or_anchor, "
            "line_start = excluded.line_start, line_end = excluded.line_end, "
            "excerpt = excluded.excerpt, verified_at = excluded.verified_at;")
    positions = {}
    for slug, spec in pending_new.items():
        parent = spec["parent"]
        if parent not in positions:
            current = connection.execute(
                "SELECT max(position) FROM ui_surface WHERE parent_surface_slug = ?", (parent,)).fetchone()[0]
            positions[parent] = current or 0
        positions[parent] += 1
        statements.append(
            "INSERT INTO ui_surface (surface_slug, platform_key, parent_surface_slug, surface_kind, "
            "user_label, position, evidence_key) VALUES ("
            + ", ".join(quote(v) for v in (slug, "macos", parent, spec["kind"], spec["label"],
                                            positions[parent], f"ui-map-{slug}"))
            + ") ON CONFLICT(surface_slug) DO UPDATE SET user_label = excluded.user_label, "
            "evidence_key = excluded.evidence_key;")
    stale = sorted(row[0] for row in connection.execute(
        "SELECT evidence_key FROM evidence WHERE substr(evidence_key, 1, 7) = 'ui-map-'")
        if row[0] not in owned_keys)
    for key in stale:
        users = connection.execute("SELECT surface_slug FROM ui_surface WHERE evidence_key = ?", (key,)).fetchall()
        if users:
            raise PublishError(f"{key} is no longer owned but {users[0][0]} still cites it; retire that surface first")
        statements.append(f"DELETE FROM evidence WHERE evidence_key = {quote(key)};")
    return statements, owned_keys, list(pending_new), stale


def migration_text(statements, revision, export_hash, owned, new, stale, date):
    header = [
        f"-- Settings Map publication (#3482), source revision {revision}, export sha256 {export_hash}, {date}.",
        "-- Generated by scripts/settings-map/publish-catalog.py from reference/settings-map.json and",
        "-- scripts/settings-map/catalog-surfaces.json at that revision; do not edit by hand.",
        f"-- Owns {len(owned)} evidence rows (ui-map-<surface slug>: the map ids of that surface),",
        f"-- inserts {len(new)} new macOS surfaces, deletes {len(stale)} stale ui-map evidence rows.",
        "-- Updates no other ui_surface row and no setting_surface row. A refactor revision on an",
        "-- unmerged branch is source evidence, not a claim that it shipped.",
        "",
        "BEGIN;",
    ]
    return "\n".join(header + statements + ["COMMIT;", ""])


def snapshot(connection):
    tables = [row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    return {table: set(connection.execute(f"SELECT * FROM {table}")) for table in tables}


def snapshot_after(catalog_db, sql, times):
    """Database contents after applying `sql` `times` times to a disposable copy."""
    with tempfile.TemporaryDirectory() as folder:
        copy = pathlib.Path(folder) / "catalog.db"
        shutil.copyfile(catalog_db, copy)
        connection = sqlite3.connect(copy)
        connection.execute("PRAGMA foreign_keys = OFF")
        for _ in range(times):
            connection.executescript(sql)
        contents = snapshot(connection)
        connection.close()
        return contents


def verify_on_copy(catalog_db, sql, owned_keys, new_slugs, stale_keys):
    """Applies the migration to a disposable copy and proves what it preserves."""
    with tempfile.TemporaryDirectory() as folder:
        copy = pathlib.Path(folder) / "catalog.db"
        shutil.copyfile(catalog_db, copy)
        connection = sqlite3.connect(copy)
        before = snapshot(connection)
        connection.execute("PRAGMA foreign_keys = OFF")
        connection.executescript(sql)
        dangling = connection.execute("PRAGMA foreign_key_check").fetchall()
        after = snapshot(connection)
        connection.close()
    problems = []
    if dangling:
        problems.append(f"foreign key check: {dangling[:3]}")
    report = {}
    for table in sorted(set(before) | set(after)):
        old, new = before.get(table, set()), after.get(table, set())
        removed, added = old - new, new - old
        if table == "evidence":
            touched = {row[0] for row in removed | added}
            outside = touched - set(owned_keys) - set(stale_keys)
            if outside:
                problems.append(f"evidence rows outside the owned set changed: {sorted(outside)[:5]}")
            report[table] = f"{len(old)} -> {len(new)}"
        elif table == "ui_surface":
            if removed:
                problems.append(f"ui_surface rows changed or removed: {sorted(r[0] for r in removed)[:5]}")
            if {row[0] for row in added} != set(new_slugs):
                problems.append(f"ui_surface additions are not exactly the new surfaces: {sorted(r[0] for r in added)[:5]}")
            report[table] = f"{len(old)} -> {len(new)}"
        elif removed or added:
            problems.append(f"{table} changed ({len(removed)} removed, {len(added)} added)")
        else:
            report[table] = f"{len(old)} unchanged"
    return problems, report


def rebuild_in_copy(catalog_dir, sql, name):
    """Runs the catalog's own rebuild.sh in a copy of its folder with the new migration."""
    with tempfile.TemporaryDirectory() as folder:
        copy = pathlib.Path(folder) / "catalog"
        shutil.copytree(catalog_dir, copy, ignore=shutil.ignore_patterns("catalog.db*"))
        (copy / "data" / name).write_text(sql, encoding="utf-8")
        result = subprocess.run(["bash", str(copy / "rebuild.sh")], capture_output=True, text=True)
        return result.returncode, (result.stdout + result.stderr)[-600:]


def write_exclusive(catalog_dir, target, sql):
    """Publishes the migration file without ever replacing one: another session may have taken
    the same number since the dry run."""
    with tempfile.TemporaryDirectory(prefix=".settings-map-", dir=catalog_dir / "data") as folder:
        staging = pathlib.Path(folder) / "migration.sql"
        staging.write_text(sql, encoding="utf-8")
        try:
            os.link(staging, target)
        except FileExistsError:
            raise PublishError(
                f"{target} appeared during publication; nothing overwritten. "
                "Rerun the complete dry run against the current catalog.")


def next_name(catalog_dir, date):
    numbers = [int(p.name[:3]) for p in (catalog_dir / "data").glob("[0-9][0-9][0-9]-*.sql")]
    return f"{max(numbers, default=0) + 1:03d}-macos-settings-map-{date}.sql"


def run(args):
    catalog_dir = pathlib.Path(args.catalog).expanduser()
    catalog_db = catalog_dir / "catalog.db"
    if not catalog_db.is_file():
        raise PublishError(f"no catalog at {catalog_db}")
    revision = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--verify", f"{args.revision}^{{commit}}"],
                              capture_output=True, text=True)
    if revision.returncode != 0:
        raise PublishError(f"unknown revision {args.revision}")
    revision = revision.stdout.strip()
    export_bytes = git_show(revision, EXPORT)
    export_hash = hashlib.sha256(export_bytes).hexdigest()
    export = json.loads(export_bytes)
    mapping = json.loads(git_show(revision, MAPPING))
    parents = {n["id"]: n["parent"] for n in export["nodes"]}
    choices = {n["id"] for n in export["nodes"] if n.get("kind") == "choice"}
    declarations = declaration_lines(
        git_show(revision, MAP_FILE).decode(), git_show(revision, ID_FILE).decode(), parents, choices)
    date = args.date or datetime.date.today().isoformat()
    connection = sqlite3.connect(f"file:{catalog_db}?mode=ro", uri=True)
    statements, owned, new, stale = plan(export, mapping, connection, declarations, revision[:12], export_hash, date)
    connection.close()
    sql = migration_text(statements, revision[:12], export_hash, owned, new, stale, date)

    problems, report = verify_on_copy(catalog_db, sql, owned, new, stale)
    for table, line in report.items():
        print(f"  {table}: {line}")
    if problems:
        raise PublishError("the migration would change data it does not own:\n  " + "\n  ".join(problems))
    name = next_name(catalog_dir, date)
    code, tail = rebuild_in_copy(catalog_dir, sql, name)
    if code != 0:
        raise PublishError(f"rebuild.sh failed on a copy with {name}:\n{tail}")
    print(f"verified on a disposable copy: {len(owned)} owned evidence rows, {len(new)} new surfaces, "
          f"{len(stale)} stale rows removed; full rebuild with {name} passed")
    if not args.write:
        print("dry run: nothing written (pass --write at the wind-down catalog step)")
        return
    publish(catalog_dir, name, sql, rebuild=lambda: subprocess.run(
        ["bash", str(catalog_dir / "rebuild.sh")], capture_output=True, text=True))


def publish(catalog_dir, name, sql, rebuild):
    """Writes the migration exclusively, then rebuilds; a refused write never rebuilds."""
    target = catalog_dir / "data" / name
    write_exclusive(catalog_dir, target, sql)
    result = rebuild()
    print(result.stdout[-400:])
    if result.returncode != 0:
        raise PublishError(f"rebuild.sh failed after writing {target}: {result.stderr[-400:]}")
    print(f"published {target}")


def self_test():
    passed = failed = 0

    def check(name, condition):
        nonlocal passed, failed
        if condition:
            passed += 1
        else:
            failed += 1
            print(f"FAIL {name}")

    with tempfile.TemporaryDirectory() as folder:
        db = pathlib.Path(folder) / "catalog.db"
        connection = sqlite3.connect(db)
        connection.executescript("""
            CREATE TABLE platform (platform_key TEXT PRIMARY KEY);
            CREATE TABLE evidence (evidence_key TEXT PRIMARY KEY, evidence_kind TEXT NOT NULL,
              repository TEXT NOT NULL, revision TEXT NOT NULL, file_path TEXT NOT NULL,
              symbol_or_anchor TEXT NOT NULL, line_start INTEGER, line_end INTEGER, excerpt TEXT,
              verified_at TEXT NOT NULL);
            CREATE TABLE ui_surface (surface_slug TEXT PRIMARY KEY,
              platform_key TEXT NOT NULL REFERENCES platform(platform_key),
              parent_surface_slug TEXT REFERENCES ui_surface(surface_slug), surface_kind TEXT NOT NULL,
              user_label TEXT NOT NULL, position INTEGER NOT NULL,
              evidence_key TEXT NOT NULL REFERENCES evidence(evidence_key));
            CREATE TABLE setting (setting_slug TEXT PRIMARY KEY);
            CREATE TABLE setting_surface (setting_slug TEXT NOT NULL REFERENCES setting(setting_slug),
              surface_slug TEXT NOT NULL REFERENCES ui_surface(surface_slug), PRIMARY KEY (setting_slug, surface_slug));
            INSERT INTO platform VALUES ('macos'), ('windows');
            INSERT INTO evidence VALUES ('e1','code','r','x','f','s',1,1,NULL,'d'), ('ui-map-gone','code','r','x','f','s',1,1,NULL,'d');
            INSERT INTO ui_surface VALUES ('mac-page','macos',NULL,'page','Page',1,'e1'),
              ('mac-ctl','macos','mac-page','control','Control',1,'e1'),
              ('win-ctl','windows',NULL,'control','Other platform',1,'e1');
            INSERT INTO setting VALUES ('s1');
            INSERT INTO setting_surface VALUES ('s1','mac-ctl');
        """)
        connection.commit()
        export = {"nodes": [{"id": "page", "title": {"source": "verbatim", "text": "Page"}},
                            {"id": "item", "title": {"source": "resource", "en": "Item"}},
                            {"id": "item.a", "title": {"source": "resource", "en": "A"}},
                            {"id": "link", "title": {"source": "resource", "en": "Link"}}]}
        mapping = {"surfaces": {"mac-page": ["page"], "mac-ctl": ["item", "item.a"], "mac-new": ["link"]},
                   "newSurfaces": {"mac-new": {"kind": "control", "parent": "mac-page", "label": "Link [new]"}}}
        declarations = {i: (MAP_FILE, n + 1, "node") for n, i in enumerate(["page", "item", "item.a", "link"])}

        statements, owned, new, stale = plan(export, mapping, connection, declarations, "abc", "hash", "2026-01-01")
        sql = migration_text(statements, "abc", "hash", owned, new, stale, "2026-01-01")
        connection.close()
        check("owns one evidence row per surface", owned == ["ui-map-mac-page", "ui-map-mac-ctl", "ui-map-mac-new"])
        check("only the declared new surface is inserted", new == ["mac-new"])
        check("a stale ui-map row is deleted by key", stale == ["ui-map-gone"] and "DELETE FROM evidence WHERE evidence_key = 'ui-map-gone';" in sql)
        body = "\n".join(statements)
        check("no broad deletion", "LIKE" not in body and "DELETE FROM ui_surface" not in body and "setting_surface" not in body)
        problems, report = verify_on_copy(db, sql, owned, new, stale)
        check("preserves everything it does not own", problems == [])
        check("setting links unchanged", report.get("setting_surface") == "1 unchanged")
        check("other tables unchanged", report.get("platform") == "2 unchanged")
        check("applying twice leaves exactly what applying once does",
              snapshot_after(db, sql, 1) == snapshot_after(db, sql, 2))
        drifting = sql.replace("verified_at = excluded.verified_at;", "verified_at = evidence.verified_at || 'x';", 1)
        check("the drift control changed the migration", drifting != sql)
        check("the stability check catches a migration that drifts on reapplication",
              snapshot_after(db, drifting, 1) != snapshot_after(db, drifting, 2))

        bad = sql.replace("COMMIT;", "UPDATE ui_surface SET user_label = 'x' WHERE surface_slug = 'win-ctl';\nCOMMIT;")
        check("detects a change to a row it does not own", any("ui_surface" in p for p in verify_on_copy(db, bad, owned, new, stale)[0]))
        bad = sql.replace("COMMIT;", "DELETE FROM setting_surface;\nCOMMIT;")
        check("detects a lost setting link", any("setting_surface" in p for p in verify_on_copy(db, bad, owned, new, stale)[0]))
        bad = sql.replace("COMMIT;", "INSERT INTO ui_surface VALUES ('x','macos','nope','control','X',1,'e1');\nCOMMIT;")
        check("detects a dangling reference", any("foreign key" in p for p in verify_on_copy(db, bad, owned, new, stale)[0]))

        # A second planning run after a real publication reuses the owned new surface.
        published = pathlib.Path(folder) / "published.db"
        shutil.copyfile(db, published)
        connection = sqlite3.connect(published)
        connection.execute("PRAGMA foreign_keys = OFF")
        connection.executescript(sql)
        again = plan(export, mapping, connection, declarations, "abd", "hash2", "2026-01-02")
        check("second run inserts nothing new and keeps ownership", again[2] == [] and again[1] == owned and again[3] == [])
        drifted = dict(mapping, newSurfaces={"mac-new": dict(mapping["newSurfaces"]["mac-new"], label="Changed")})
        try:
            plan(export, drifted, connection, declarations, "abd", "hash2", "2026-01-02")
            check("refuses a published surface that differs from its definition", False)
        except PublishError:
            check("refuses a published surface that differs from its definition", True)
        connection.close()

        # The migration file is written exclusively; a refused write leaves the file and never rebuilds.
        catalog_dir = pathlib.Path(folder) / "catalog"
        (catalog_dir / "data").mkdir(parents=True)
        (catalog_dir / "data" / "005-other.sql").write_text("-- another session\n")
        rebuilds = []

        class Done:
            returncode, stdout, stderr = 0, "", ""

        try:
            publish(catalog_dir, "005-other.sql", sql, rebuild=lambda: rebuilds.append(1) or Done())
            check("refuses to overwrite another session's migration", False)
        except PublishError:
            check("refuses to overwrite another session's migration", True)
        check("the other migration is byte-identical", (catalog_dir / "data" / "005-other.sql").read_text() == "-- another session\n")
        check("no rebuild after a refused write", rebuilds == [])
        publish(catalog_dir, "006-settings-map.sql", sql, rebuild=lambda: rebuilds.append(1) or Done())
        check("an exclusive write publishes and rebuilds once", (catalog_dir / "data" / "006-settings-map.sql").read_text() == sql and rebuilds == [1])
        check("no staging folder left behind", [p.name for p in (catalog_dir / "data").iterdir()] == sorted(["005-other.sql", "006-settings-map.sql"]) or sorted(p.name for p in (catalog_dir / "data").iterdir()) == ["005-other.sql", "006-settings-map.sql"])

        # Producers: a literal node, a generated family, the shared constructor; never an id spelling.
        map_source = "x\n    id: .page, structure: .page\n    id: .item, structure: .item\n  choices(\n    of: .item, destination: .x,\n        id: id, structure: .item, item: .choice, title: t\n"
        id_source = 'case page = "page"\ncase item = "item"\ncase itemA = "item.a"\ncase orphan = "orphan"\n'
        try:
            declaration_lines(map_source, id_source, {"item.a": "item", "orphan": None}, {"item.a"})
            check("an id with no producer is refused", False)
        except PublishError:
            check("an id with no producer is refused", True)
        found = declaration_lines(map_source, id_source.replace('case orphan = "orphan"\n', ""), {"item.a": "item"}, {"item.a"})
        shared = declaration_lines(map_source.replace("of: .item,", "of: .elsewhere,"), id_source.replace('case orphan = "orphan"\n', ""), {"item.a": "item"}, {"item.a"})
        try:
            declaration_lines(map_source, id_source.replace('case orphan = "orphan"', 'case notChoice = "item.b"'),
                              {"item.a": "item", "item.b": "item"}, {"item.a"})
            check("a non-choice child of a choice family is refused", False)
        except PublishError:
            check("a non-choice child of a choice family is refused", True)
        check("a choice with no family call cites the shared constructor", shared["item.a"] == (MAP_FILE, 6, "SettingsMap.choices (shared choice producer)"))
        check("a literal node cites its own line", found["page"] == (MAP_FILE, 2, "node"))
        check("a generated choice cites its family call", found["item.a"] == (MAP_FILE, 5, "choices(of: .item)"))
        check("nothing cites the id file", all(f == MAP_FILE for f, _, _ in found.values()))

        connection = sqlite3.connect(db)
        for name, broken in (
            ("refuses an unmapped id", {"surfaces": {"mac-page": ["page"], "mac-ctl": ["item"], "mac-new": ["link"]},
                                        "newSurfaces": mapping["newSurfaces"]}),
            ("refuses an unknown slug", {"surfaces": {"mac-page": ["page"], "mac-nope": ["item", "item.a"], "mac-new": ["link"]},
                                         "newSurfaces": mapping["newSurfaces"]}),
            ("refuses another platform's surface", {"surfaces": {"mac-page": ["page"], "win-ctl": ["item", "item.a"], "mac-new": ["link"]},
                                                    "newSurfaces": mapping["newSurfaces"]}),
            ("refuses a new surface that exists", {"surfaces": mapping["surfaces"],
                                                   "newSurfaces": {"mac-new": mapping["newSurfaces"]["mac-new"],
                                                                   "mac-ctl": {"kind": "control", "parent": "mac-page", "label": "x"}}}),
        ):
            try:
                plan(export, broken, connection, declarations, "abc", "hash", "2026-01-01")
                check(name, False)
            except PublishError:
                check(name, True)
        connection.close()
    print(f"self-test: {passed} passed, {failed} failed")
    sys.exit(1 if failed or not passed else 0)


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--date")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    try:
        run(args)
    except PublishError as error:
        print(f"publish-catalog: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
