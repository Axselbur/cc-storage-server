#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CC Storage Server -- web monitor + autocraft for Minecraft (Create + CC:Tweaked).
Part 1: data loading and state API.

Python 3 stdlib only. Hosted on Render free tier, deployed from GitHub.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# ---------------- settings ----------------
PORT = int(os.environ.get("PORT", "8787"))
HOST = "0.0.0.0" if "PORT" in os.environ else "127.0.0.1"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ICONS_DIR = os.path.join(BASE_DIR, "info", "icon-exports-x32")
RECIPE_DUMP = os.path.join(BASE_DIR, "info", "recipe-dump.json")
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
CUSTOM_RECIPES_FILE = os.path.join(BASE_DIR, "custom_recipes.json")
STORAGE_DATA_FILE = os.path.join(BASE_DIR, "storage_data.json")
ORDERS_FILE = os.path.join(BASE_DIR, "orders.json")

CONFIG_DEFAULTS = {
    "vaults": [],            # peripheral names of storage vaults
    "turtle_name": "",       # optional crafter turtle network name
    "packagers": [],         # packager peripherals
    "packager_target": "",   # where packagers push into
    "buffer_chest": "",      # buffer chest to distribute into vaults
    "auto_balance": False,   # keep vaults evenly filled (включается вручную на сайте)
    "auto_balance_interval": 600,  # seconds between auto-balance runs
    "vault_capacity": 4096,  # assumed items per vault (for the monitor fill bars)
    "cannons": [],           # автопушки: [{"name", "ammo"}]
}

LOCK = threading.RLock()
CONFIG = dict(CONFIG_DEFAULTS)
STATE = {"items": {}, "vaults": {}, "missing": [], "computer": None, "updated_at": 0}

# Secrets: only via environment variables (never in the repo).
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")   # browser, HTTP Basic
DEVICE_KEY = os.environ.get("DEVICE_KEY", "")           # in-game scripts
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")       # config persistence
GITHUB_REPO = os.environ.get("GITHUB_REPO", "")         # "user/repo"
GITHUB_BRANCH = os.environ.get("GITHUB_BRANCH", "main")

GITHUB_SYNC = {"last_ok": None, "last_error": None, "last_attempt_at": None}
CRAFTER_STATE = {"last_seen": None}
BALANCE_STATE = {
    "status": "idle",       # idle | requested | running | done | failed
    "moved": 0,
    "message": "",
    "requested_at": None,
    "updated_at": None,
}

# ---------------- users / sessions / bans ----------------
USERS_FILE = os.path.join(BASE_DIR, "users.json")
USERS = {"users": {}, "bans": {}}   # users.json: {"users": {name: {...}}, "bans": {ip: {...}}}
KICKED = {}                         # username -> kicked_until (сессии-токены статeless)


SESSION_TTL = 4 * 3600  # сессия живёт 4 часа


def session_secret():
    """Стабильный секрет для подписи сессий (переживает рестарты)."""
    admin = USERS["users"].get("admin") or {}
    salt = admin.get("salt", "nosalt")
    return hashlib.sha256((DEVICE_KEY + ":" + salt).encode("utf-8")).hexdigest()


def make_session_token(username):
    exp = int(time.time()) + SESSION_TTL
    payload = "%s.%d" % (username, exp)
    sig = hmac.new(session_secret().encode("utf-8"), payload.encode("utf-8"),
                   hashlib.sha256).hexdigest()
    return payload + "." + sig


def verify_session_token(token):
    try:
        username, exp_s, sig = token.split(".", 2)
    except ValueError:
        return None
    if username not in USERS["users"]:
        return None
    payload = "%s.%s" % (username, exp_s)
    expected = hmac.new(session_secret().encode("utf-8"), payload.encode("utf-8"),
                        hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        return None
    try:
        exp = int(exp_s)
    except ValueError:
        return None
    if time.time() > exp:
        return None
    if KICKED.get(username) and time.time() < KICKED[username]:
        return None
    return username


def hash_password(password, salt_hex):
    return hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), bytes.fromhex(salt_hex), 100_000
    ).hex()


def load_users():
    global USERS
    if os.path.exists(USERS_FILE):
        try:
            with open(USERS_FILE, "r", encoding="utf-8-sig") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                USERS = {
                    "users": data.get("users") or {},
                    "bans": data.get("bans") or {},
                }
                return
        except Exception:
            pass
    salt = secrets.token_hex(16)
    USERS = {
        "users": {"admin": {"salt": salt, "hash": hash_password("password", salt),
                            "role": "admin"}},
        "bans": {},
    }
    save_users()
    log("Created users.json: admin / password (смени пароль на сайте!)")


def save_users():
    try:
        tmp = USERS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(USERS, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, USERS_FILE)
    except Exception as e:
        log("save_users failed: %s" % e)
    _github_commit_file_async("users.json", "Update users")

TEXTURE_INDEX = {}       # item_id -> png path
RECIPES_BY_RESULT = {}   # item_id -> [recipe]
RECIPES_BY_INPUT = {}    # item_id -> [recipe]
TAG_INDEX = {}           # "ns:tag" -> [item_id or #other:tag]
TAG_RESOLVE_CACHE = {}
ALL_ITEMS = []           # every known item id


def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


# ---------------- info/ data ----------------
def scan_info_icons():
    """Build TEXTURE_INDEX from info/icon-exports-x32/*.png.

    File name <namespace>__<path>.png maps to <namespace>:<path>;
    an NBT suffix like computercraft__disk__{...}.png maps to the base id
    computercraft:disk.
    """
    global TEXTURE_INDEX
    index = {}
    if os.path.isdir(ICONS_DIR):
        for name in os.listdir(ICONS_DIR):
            if not name.lower().endswith(".png"):
                continue
            stem = name[:-4]
            brace = stem.find("{")
            if brace != -1:
                stem = stem[:brace]
            stem = stem.rstrip("_")
            ns, sep, path = stem.partition("__")
            if sep and path:
                index[ns + ":" + path] = os.path.join(ICONS_DIR, name)
    TEXTURE_INDEX = index
    return len(index)


def _parse_ingredient(entry, default_count=1):
    """Normalize one ingredient into a cell dict.

    Cell: {"id": x, "count": n} | {"tag": t, "count": n} |
          {"fluid": f, "count": n} | {"anyOf": [cells], "count": n}
    """
    if entry is None:
        return None
    if isinstance(entry, list):
        options = [c for c in (_parse_ingredient(e, 1) for e in entry) if c]
        return {"anyOf": options, "count": default_count} if options else None
    if isinstance(entry, dict):
        count = entry.get("count", default_count)
        it = entry.get("item")
        if isinstance(it, dict):
            return {"id": it.get("id") or it.get("item"), "count": it.get("count", count)}
        if "item" in entry:
            return {"id": entry["item"], "count": count}
        if "id" in entry:
            return {"id": entry["id"], "count": count}
        if "tag" in entry:
            return {"tag": entry["tag"], "count": count}
        if "fluid" in entry:
            f = entry["fluid"]
            if isinstance(f, dict):
                f = f.get("id") or f.get("fluid") or str(f)
            return {"fluid": f, "count": entry.get("amount", count)}
        if "children" in entry or "anyOf" in entry:
            lst = entry.get("children") or entry.get("anyOf") or []
            options = [c for c in (_parse_ingredient(e, 1) for e in lst) if c]
            return {"anyOf": options, "count": count} if options else None
    return None


def _parse_result_entry(r):
    if not isinstance(r, dict):
        return None
    it = r.get("item")
    cnt = r.get("count", 1)
    if isinstance(it, dict):
        rid = it.get("id") or it.get("item")
        cnt = it.get("count", cnt)
    else:
        rid = it or r.get("id")
    if not rid or not isinstance(rid, str):
        return None
    return {"id": rid, "count": cnt, "chance": r.get("chance")}


def _parse_results(raw):
    out = []
    res = raw.get("result")
    if res is None:
        res = raw.get("results")
    if isinstance(res, list):
        for r in res:
            e = _parse_result_entry(r)
            if e:
                out.append(e)
    elif isinstance(res, dict):
        e = _parse_result_entry(res)
        if e:
            out.append(e)
    return out


def _parse_recipe(rid, raw):
    rtype = raw.get("type") or raw.get("realType") or ""
    results = _parse_results(raw)
    if not results:
        return None

    grid = None
    inputs = []
    pattern = raw.get("pattern")
    key = raw.get("key") or {}
    if isinstance(pattern, list) and pattern:
        grid = []
        for row in pattern:
            line = []
            for ch in row:
                line.append(_parse_ingredient(key.get(ch)) if ch and ch != " " else None)
            grid.append(line)
        # pad to 3x3, anchored top-left
        while len(grid) < 3:
            grid.append([None, None, None])
        for line in grid:
            while len(line) < 3:
                line.append(None)
        grid = [line[:3] for line in grid[:3]]
    else:
        ing = raw.get("ingredients")
        if isinstance(ing, list):
            # keep None positions -- they matter for shaped grids
            cells = [_parse_ingredient(e) for e in ing]
            w = int(raw.get("width") or 0)
            h = int(raw.get("height") or 0)
            if 0 < w <= 3 and 0 < h <= 3 and len(cells) >= w * h:
                grid = []
                idx = 0
                for _ in range(h):
                    line = []
                    for _ in range(w):
                        line.append(cells[idx] if idx < len(cells) else None)
                        idx += 1
                    while len(line) < 3:
                        line.append(None)
                    grid.append(line)
                while len(grid) < 3:
                    grid.append([None, None, None])
            inputs = [c for c in cells if c is not None]

    recipe = {"id": rid, "type": rtype, "grid": grid, "inputs": inputs,
              "results": results}
    if "loops" in raw:
        recipe["loops"] = raw["loops"]
    return recipe


def scan_info_recipes():
    """Parse info/recipe-dump.json into the unified recipe format and indexes."""
    global RECIPES_BY_RESULT, RECIPES_BY_INPUT, TAG_INDEX, ALL_ITEMS
    by_result = {}
    by_input = {}
    tags = {}
    items = []

    if os.path.exists(RECIPE_DUMP):
        try:
            with open(RECIPE_DUMP, "r", encoding="utf-8-sig") as fh:
                dump = json.load(fh)
        except Exception as e:
            log("recipe dump parse failed: %s" % e)
            dump = {}
        if isinstance(dump, dict):
            items = list(dump.get("__items") or [])
            raw_tags = dump.get("__tags") or {}
            tags = {k: list(v) for k, v in raw_tags.items() if isinstance(v, list)}

            def add_cell_inputs(cell):
                if cell is None:
                    return
                if "anyOf" in cell:
                    for c in cell["anyOf"]:
                        add_cell_inputs(c)
                    return
                k = cell.get("id") or cell.get("tag")
                if k:
                    by_input.setdefault(k, []).append(recipe)

            for rid, raw in dump.items():
                if rid.startswith("__") or not isinstance(raw, dict):
                    continue
                recipe = _parse_recipe(rid, raw)
                if recipe is None:
                    continue
                for res in recipe["results"]:
                    by_result.setdefault(res["id"], []).append(recipe)
                if recipe["grid"]:
                    for line in recipe["grid"]:
                        for cell in line:
                            add_cell_inputs(cell)
                for cell in recipe["inputs"]:
                    add_cell_inputs(cell)

    RECIPES_BY_RESULT = by_result
    RECIPES_BY_INPUT = by_input
    TAG_INDEX = tags
    TAG_RESOLVE_CACHE.clear()
    ALL_ITEMS = items
    return len(items), sum(len(v) for v in by_result.values())


def resolve_tag(tag):
    """Expand '#ns:tag' recursively into a list of item ids (depth <= 6)."""
    if tag in TAG_RESOLVE_CACHE:
        return TAG_RESOLVE_CACHE[tag]
    seen = set()
    out = []

    def walk(t, depth):
        t = t.lstrip("#")
        if t in seen or depth > 6:
            return
        seen.add(t)
        for entry in TAG_INDEX.get(t, []):
            if entry.startswith("#"):
                walk(entry, depth + 1)
            else:
                out.append(entry)

    walk(tag, 0)
    TAG_RESOLVE_CACHE[tag] = out
    return out


def _base_id(item):
    """Отрезаем компоненты (1.20.5+): id[comp=...] / id{...} -> базовый id."""
    item = str(item)
    i = item.find("[")
    if i == -1:
        i = item.find("{")
    if i != -1:
        return item[:i]
    return item


# ---------------- config / state files ----------------
def load_config():
    global CONFIG
    cfg = dict(CONFIG_DEFAULTS)
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            for k in CONFIG_DEFAULTS:
                if k in data:
                    cfg[k] = data[k]
    except Exception:
        pass
    CONFIG = cfg


def save_config():
    try:
        tmp = CONFIG_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(CONFIG, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, CONFIG_FILE)
    except Exception as e:
        log("save_config failed: %s" % e)
    _github_commit_file_async("config.json", "Update config.json")


# ---------------- GitHub persistence ----------------
# Render's free disk is wiped on every spin-down/deploy, so config and
# custom recipes are committed back to the repo after each save.
def _github_api(method, url, body=None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", "Bearer " + GITHUB_TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "cc-storage-server")
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def github_commit_file(rel_path, message):
    if not GITHUB_TOKEN or not GITHUB_REPO:
        return
    GITHUB_SYNC["last_attempt_at"] = time.time()
    api = "https://api.github.com/repos/%s/contents/%s" % (GITHUB_REPO, rel_path)
    try:
        with open(os.path.join(BASE_DIR, rel_path), "rb") as fh:
            content_b64 = base64.b64encode(fh.read()).decode("ascii")
        sha = None
        try:
            sha = _github_api("GET", api + "?ref=" + GITHUB_BRANCH).get("sha")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        body = {"message": message, "content": content_b64, "branch": GITHUB_BRANCH}
        if sha:
            body["sha"] = sha
        _github_api("PUT", api, body)
        GITHUB_SYNC["last_ok"] = time.time()
        GITHUB_SYNC["last_error"] = None
        log("GitHub sync: committed %s" % rel_path)
    except Exception as e:
        GITHUB_SYNC["last_error"] = str(e)[:300]
        log("GitHub sync FAILED for %s: %s" % (rel_path, e))


def _github_commit_file_async(rel_path, message):
    if not GITHUB_TOKEN or not GITHUB_REPO:
        return
    threading.Thread(target=github_commit_file, args=(rel_path, message),
                     daemon=True).start()


def load_state():
    global STATE
    st = dict(STATE)
    try:
        with open(STORAGE_DATA_FILE, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            st.update(data)
    except Exception:
        pass
    STATE = st


def save_state():
    try:
        tmp = STORAGE_DATA_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(STATE, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, STORAGE_DATA_FILE)
    except Exception as e:
        log("save_state failed: %s" % e)


# ---------------- custom recipes ----------------
CUSTOM_RECIPES = []


def load_custom_recipes():
    global CUSTOM_RECIPES
    try:
        with open(CUSTOM_RECIPES_FILE, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        if isinstance(data, list):
            CUSTOM_RECIPES = data
    except Exception:
        CUSTOM_RECIPES = []


def save_custom_recipes():
    try:
        tmp = CUSTOM_RECIPES_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(CUSTOM_RECIPES, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, CUSTOM_RECIPES_FILE)
    except Exception as e:
        log("save_custom_recipes failed: %s" % e)
    _github_commit_file_async("custom_recipes.json", "Update custom recipes")


def _borrow_dump_grid(output, ingredients):
    """Пользовательский рецепт не описывает ФОРМУ. Если в дампе есть
    shaped-рецепт того же предмета с теми же ингредиентами -- берём его
    сетку, чтобы черепашка крафтила по реальной форме (вертикаль,
    кольцо и т.п.), а не раскладывала подряд."""
    if not RECIPES_BY_RESULT:
        return None
    want = {}
    for i in ingredients:
        key = i.get("item") or i.get("id")
        if key:
            want[str(key)] = want.get(str(key), 0) + int(i.get("count", 1))

    def cell_matches(cell, cid):
        if not cell:
            return False
        if cell.get("id") == cid:
            return True
        if "tag" in cell and cid in resolve_tag(cell["tag"]):
            return True
        return False

    for r in RECIPES_BY_RESULT.get(output, []):
        if r.get("custom") or not r.get("grid"):
            continue
        cells = [c for row in r["grid"] for c in row if c is not None]
        if len(cells) != sum(want.values()):
            continue
        ids = []
        for cid, cnt in want.items():
            ids += [cid] * cnt
        used = [False] * len(cells)
        ok = True
        for cid in ids:
            found = False
            for idx, cell in enumerate(cells):
                if not used[idx] and cell_matches(cell, cid):
                    used[idx] = True
                    found = True
                    break
            if not found:
                ok = False
                break
        if ok:
            return r["grid"]
    return None


def rebuild_custom_recipe_index():
    """Re-insert current custom recipes into the planner indexes as
    craftable recipes with method/destination/mechanism_*.
    Форму (сетку) берём из дампа, если такой рецепт там есть."""
    global RECIPES_BY_RESULT, RECIPES_BY_INPUT
    for index in (RECIPES_BY_RESULT, RECIPES_BY_INPUT):
        for key in list(index.keys()):
            kept = [r for r in index[key] if not r.get("custom")]
            if kept:
                index[key] = kept
            else:
                del index[key]
    for cr in CUSTOM_RECIPES:
        inputs = [{"id": str(i.get("item")), "count": int(i.get("count", 1))}
                  for i in cr.get("ingredients", []) if i.get("item")]
        grid = None
        if cr.get("method", "table") == "table":
            grid = _borrow_dump_grid(cr["output"], inputs)
        recipe = {
            "id": cr.get("id", "custom"),
            "type": "minecraft:crafting_shapeless",
            "grid": grid,
            "inputs": inputs,
            "results": [{"id": cr["output"], "count": int(cr.get("output_count", 1))}],
            "custom": True,
            "method": cr.get("method", "table"),
        }
        for k in ("destination", "mechanism_input", "mechanism_output"):
            if cr.get(k):
                recipe[k] = cr[k]
        if not recipe["inputs"] or not recipe["results"]:
            continue
        RECIPES_BY_RESULT.setdefault(recipe["results"][0]["id"], []).insert(0, recipe)
        for cell in recipe["inputs"]:
            RECIPES_BY_INPUT.setdefault(cell["id"], []).append(recipe)


# ---------------- orders & crafting planner (AE2-style) ----------------
# Port of Applied Energistics 2 crafting tree simulation
# (CraftingCalculation / CraftingTreeNode / CraftingTreeProcess /
# CraftingSimulationState). Only workbench recipes are craftable -- the
# turtle with a crafting table executes them.
CRAFTABLE_TYPES = {"minecraft:crafting_shaped", "minecraft:crafting_shapeless",
                   "recipedump:shaped"}

PLAN_MAX_OPS = 200000
PLAN_MAX_DEPTH = 24
PLAN_TIME_LIMIT = 6.0
MAX_ORDERS = 50

ORDERS = []


class CraftBranchFailure(Exception):
    """One simulation branch failed: not enough materials in this branch."""


class _PlanAborted(Exception):
    """Planning budget exhausted. Must NOT be caught by branch handlers."""


def _recipe_cells(r):
    """All non-empty input cells of a recipe, in grid order."""
    if r.get("grid"):
        out = []
        for row in r["grid"]:
            for cell in row:
                if cell is not None:
                    out.append(cell)
        return out
    return r.get("inputs") or []


def _is_craftable(r):
    return r.get("custom") or r.get("type") in CRAFTABLE_TYPES


class _SimInventory(object):
    """Branching simulated inventory on top of the real STATE['items'].

    branch() makes a child that sees the parent state; apply_diff(parent)
    commits the child's changes (extractions, produced items, steps) into
    the parent -- like applyDiff in AE2. ignore(item) zeroes the stock of
    an item so it must be crafted rather than taken from storage.
    """

    def __init__(self, base, items=None, steps=None, ignored=None):
        self.base = dict(base)           # copy: never mutate the caller's stock
        self.items = dict(items or {})   # simulated delta: production/consumption
        self.steps = steps if steps is not None else []
        self.ignored = set(ignored or set())

    def _observe(self, item):
        base = 0 if item in self.ignored else self.base.get(item, 0)
        return base + self.items.get(item, 0)

    def peek(self, item):
        v = self._observe(item)
        return v if v > 0 else 0

    def insert(self, item, amount):
        if amount <= 0:
            return
        self.items[item] = self.items.get(item, 0) + amount

    def extract(self, item, amount):
        if amount <= 0:
            return
        cur = self.items.get(item, 0)
        take = min(amount, cur)
        self.items[item] = cur - take
        remaining = amount - take
        if remaining > 0:
            base = 0 if item in self.ignored else self.base.get(item, 0)
            if remaining > base:
                raise CraftBranchFailure("not enough %s" % item)
            self.base[item] = base - remaining

    def branch(self):
        return _SimInventory(dict(self.base), dict(self.items), None, set(self.ignored))

    def apply_diff(self, parent):
        parent.base.update(self.base)
        parent.items.clear()
        parent.items.update(self.items)
        parent.steps.extend(self.steps)
        parent.ignored |= self.ignored

    def ignore(self, item):
        self.ignored.add(item)
        self.base.pop(item, None)
        self.items.pop(item, None)


class _Planner(object):
    def __init__(self, stock):
        self.stock = stock
        self.ops = 0
        self.t0 = time.time()
        self.simulate = False
        self.missing = {}

    def _tick(self):
        self.ops += 1
        if self.ops > PLAN_MAX_OPS:
            raise _PlanAborted()
        if self.ops % 500 == 0 and time.time() - self.t0 > PLAN_TIME_LIMIT:
            raise _PlanAborted()

    def cell_ids(self, cell):
        ids = set()
        if cell is None:
            return ids
        if "id" in cell:
            ids.add(cell["id"])
        elif "tag" in cell:
            ids |= set(resolve_tag(cell["tag"]))
        elif "anyOf" in cell:
            for c in cell["anyOf"]:
                ids |= self.cell_ids(c)
        return ids

    def _ingredient_options(self, entry):
        if entry is None:
            return []
        if "id" in entry:
            return [entry["id"]]
        if "tag" in entry:
            return resolve_tag(entry["tag"])
        if "anyOf" in entry:
            out = []
            for c in entry["anyOf"]:
                for x in self._ingredient_options(c):
                    if x not in out:
                        out.append(x)
            return out
        return []

    def recipes_for(self, item):
        # сначала точный id (в т.ч. с компонентами), затем базовый
        rs = RECIPES_BY_RESULT.get(item) or RECIPES_BY_RESULT.get(_base_id(item), [])
        rs = [r for r in rs if _is_craftable(r)]
        rs.sort(key=lambda r: 0 if r.get("custom") else 1)  # custom first
        return rs[:10]

    def attempt(self, item, amount, simulate=False):
        """Try to produce `amount` of `item`. Returns (steps, amount).
        Raises CraftBranchFailure when impossible (unless simulate)."""
        self.simulate = simulate
        self.missing = {}
        inv = _SimInventory(self.stock)
        inv.ignore(item)
        node = _Node(self, {"id": item}, None)
        node.request(inv, amount)
        return _merge_steps(inv.steps), amount

    def binary_search_max(self, item, count):
        """CRAFT_LESS: biggest amount that is actually craftable."""
        lo, hi = 0, count
        while lo < hi:
            mid = (lo + hi + 1) // 2
            ok = False
            try:
                self.attempt(item, mid, simulate=False)
                ok = True
            except CraftBranchFailure:
                ok = False
            except _PlanAborted:
                ok = False
            if ok:
                lo = mid
            else:
                hi = mid - 1
        return lo

    def simulate_missing(self, item, count):
        """Full simulated pass to collect the complete missing list."""
        try:
            self.attempt(item, count, simulate=True)
        except _PlanAborted:
            pass
        return self.missing


class _Node(object):
    """"We need N of this ingredient": take from stock, craft the rest."""

    def __init__(self, planner, entry, parent):
        self.planner = planner
        self.entry = entry
        self.parent = parent
        self.candidates = planner._ingredient_options(entry)
        self.chain = set()
        if parent is not None:
            self.chain |= parent.chain
            self.chain |= set(parent.candidates)

    def _sorted_candidates(self, inv):
        """Tag candidates: in stock first, then one-step craftable,
        then the rest. Avoids picking acacia by alphabet when oak_log
        is available for #planks."""
        if len(self.candidates) <= 1:
            return self.candidates[:]
        in_stock, craftable, rest = [], [], []
        for c in self.candidates:
            if inv.peek(c) > 0:
                in_stock.append(c)
            elif self._one_step_craftable(c, inv):
                craftable.append(c)
            else:
                rest.append(c)
        return (in_stock + craftable + rest)[:12]

    def _one_step_craftable(self, item, inv):
        for r in self.planner.recipes_for(item):
            ok = True
            for cell in _recipe_cells(r):
                ids = self.planner.cell_ids(cell)
                if ids and not any(inv.peek(i) > 0 for i in ids):
                    ok = False
                    break
            if ok:
                return True
        return False

    def _recipes_allowed(self, item):
        """Reject recipes whose inputs or outputs contain any ancestor item
        (recursion check starts from the parent, not from self)."""
        out = []
        for r in self.planner.recipes_for(item):
            ids = set()
            for cell in _recipe_cells(r):
                ids |= self.planner.cell_ids(cell)
            for res in r["results"]:
                ids.add(res["id"])
            if ids & self.chain:
                continue
            out.append(r)
        return out

    def request(self, inv, amount):
        if amount <= 0:
            return {}
        if len(self.chain) > PLAN_MAX_DEPTH:
            raise _PlanAborted()
        self.planner._tick()

        consumed = {}
        remaining = amount
        # 1) take any suitable candidate from storage
        for cand in self._sorted_candidates(inv):
            if remaining <= 0:
                break
            take = min(inv.peek(cand), remaining)
            if take > 0:
                inv.extract(cand, take)
                consumed[cand] = consumed.get(cand, 0) + take
                remaining -= take
        # 2) craft the rest through processes (по импортированным
        #    рецептам: сперва крафтим недостающее на черепашке, и только
        #    потом эти предметы пойдут в станок)
        for cand in self._sorted_candidates(inv):
            if remaining <= 0:
                break
            while remaining > 0:
                progressed = False
                for recipe in self._recipes_allowed(cand):
                    if remaining <= 0:
                        break
                    proc = _Process(self.planner, recipe, self)
                    produced = proc.try_produce(inv, remaining)
                    if produced > 0:
                        take = min(produced, remaining)
                        inv.extract(cand, take)
                        consumed[cand] = consumed.get(cand, 0) + take
                        remaining -= take
                        progressed = True
                        break
                if not progressed:
                    break
        # 3) shortage
        if remaining > 0:
            key = self.candidates[0] if self.candidates else ("tag:" + str(self.entry.get("tag", "?")))
            self.planner.missing[key] = self.planner.missing.get(key, 0) + remaining
            if not self.planner.simulate:
                raise CraftBranchFailure("not enough: %s" % key)
        return consumed


class _Process(object):
    """One recipe: run N times, requesting inputs from children."""

    def __init__(self, planner, recipe, node):
        self.planner = planner
        self.recipe = recipe
        self.node = node
        self.cells = _recipe_cells(recipe)
        self.children = [(c, _Node(planner, c, node)) for c in self.cells]
        self.per_craft = recipe["results"][0]["count"]
        in_ids = set()
        for c in self.cells:
            in_ids |= planner.cell_ids(c)
        out_ids = {r["id"] for r in recipe["results"]}
        # recipes that eat their own output craft 1 at a time
        self.limit_qty = bool(in_ids & out_ids)

    def run(self, inv, times):
        self.planner._tick()
        chosen = []
        for cell, child in self.children:
            m = child.request(inv, cell["count"] * times)
            if m:
                chosen.append(max(m.items(), key=lambda kv: kv[1])[0])
            else:
                chosen.append(None)
        for res in self.recipe["results"]:
            if res.get("chance") is None or res.get("chance") >= 1.0:
                inv.insert(res["id"], res["count"] * times)
        self._add_step(inv, times, chosen)

    def try_produce(self, inv, amount):
        times = -(-amount // self.per_craft)  # ceil
        if self.limit_qty:
            times = 1
        branch = inv.branch()
        try:
            self.run(branch, times)
        except CraftBranchFailure:
            return 0  # branch discarded
        branch.apply_diff(inv)
        return times * self.per_craft

    def _add_step(self, inv, times, chosen):
        r = self.recipe
        grid = None
        shapeless = False
        if r.get("grid"):
            flat = []
            k = 0
            for row in r["grid"]:
                for cell in row:
                    if cell is None:
                        flat.append(None)
                    else:
                        flat.append(chosen[k])
                        k += 1
            grid = flat
        else:
            shapeless = True
        ingredients = {}
        for i, cell in enumerate(self.cells):
            cid = chosen[i]
            if cid is None:
                continue
            ingredients[cid] = ingredients.get(cid, 0) + cell["count"] * times
        step = {
            "result": r["results"][0]["id"],
            "count": self.per_craft * times,
            "batches": times,
            "grid": grid,
            "shapeless": shapeless,
            "ingredients": [{"id": k, "count": v} for k, v in ingredients.items()],
            "method": r.get("method") or "table",
        }
        for k in ("destination", "mechanism_input", "mechanism_output"):
            if r.get(k):
                step[k] = r[k]
        inv.steps.append(step)


def _step_key(s):
    return (s["result"], tuple(s["grid"] or []), s.get("shapeless"),
            s.get("method"), s.get("destination"),
            s.get("mechanism_input"), s.get("mechanism_output"))


def _merge_steps(steps):
    """Merge adjacent identical steps, summing batches/count/ingredients,
    up to 64 batches per step."""
    out = []
    for s in steps:
        if out and _step_key(out[-1]) == _step_key(s) \
                and out[-1]["batches"] + s["batches"] <= 64:
            prev = out[-1]
            prev["batches"] += s["batches"]
            prev["count"] += s["count"]
            amap = {i["id"]: i["count"] for i in prev["ingredients"]}
            for i in s["ingredients"]:
                amap[i["id"]] = amap.get(i["id"], 0) + i["count"]
            prev["ingredients"] = [{"id": k, "count": v} for k, v in amap.items()]
        else:
            out.append(dict(s))
    return out


# ---------------- orders ----------------
def load_orders():
    global ORDERS
    try:
        with open(ORDERS_FILE, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        if isinstance(data, list):
            ORDERS = data[:MAX_ORDERS]
    except Exception:
        ORDERS = []


def save_orders():
    try:
        tmp = ORDERS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(ORDERS, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, ORDERS_FILE)
    except Exception as e:
        log("save_orders failed: %s" % e)


def _next_order_id():
    return max([o.get("id", 0) for o in ORDERS] + [0]) + 1


def _replan_order(item, count):
    """Returns (steps, missing, planned, status) or None if no craftable recipe.

    NOTE: existing stock of the ordered item is intentionally ignored --
    the order always crafts the requested amount on top of the stock."""
    stock = dict(STATE.get("items", {}))
    if not any(_is_craftable(r) for r in
               (RECIPES_BY_RESULT.get(item) or RECIPES_BY_RESULT.get(_base_id(item), []))):
        return None

    planner = _Planner(stock)
    steps = None
    missing = {}
    planned = 0
    try:
        steps, planned = planner.attempt(item, count, simulate=False)
    except CraftBranchFailure:
        steps = None
    except _PlanAborted:
        steps = None

    if steps is None:
        planned = planner.binary_search_max(item, count)
        if planned > 0:
            p2 = _Planner(stock)
            try:
                steps, _ = p2.attempt(item, planned, simulate=False)
            except (CraftBranchFailure, _PlanAborted):
                steps = []
        else:
            steps = []
        missing = planner.simulate_missing(item, count)

    return _merge_steps(steps), missing, planned, ("queued" if planned > 0 else "missing")


def heal_orders():
    """Orders left mid-flight by a restart go back to the queue."""
    with LOCK:
        changed = False
        for o in ORDERS:
            if o.get("status") == "crafting":
                o["status"] = "queued"
                o["step_done"] = 0
                changed = True
            if o.get("status") == "queued" and not o.get("steps"):
                res = _replan_order(o["item"], o["count"])
                if res is not None:
                    o["steps"], o["missing"], o["planned"], o["status"] = res
                    changed = True
        if changed:
            save_orders()


# ---------------- auto-maintain (автоподдержание) ----------------
AUTO_MAINTENANCE_INTERVAL = 30.0


def _heal_stale_orders():
    """Crafting orders stuck for 5+ minutes (turtle reboot mid-order)
    go back to the queue. The turtle resumes from step_done, so already
    completed steps are not re-crafted."""
    now = time.time()
    with LOCK:
        changed = False
        for o in ORDERS:
            if o.get("status") == "crafting":
                age = now - (o.get("created_at") or now)
                if age > 300:
                    o["status"] = "queued"
                    changed = True
        if changed:
            save_orders()


def _auto_maintain_tick():
    with LOCK:
        stock = dict(STATE.get("items", {}))
        orders = list(ORDERS)
        customs = list(CUSTOM_RECIPES)
    for cr in customs:
        if not cr.get("auto_enabled"):
            continue
        try:
            target = int(cr.get("auto_target") or 0)
        except (TypeError, ValueError):
            target = 0
        item = cr.get("output")
        if target <= 0 or not item:
            continue
        have = stock.get(_base_id(item), 0)
        if have >= target:
            continue
        # не спамим: пропускаем, если уже есть активный заказ или
        # недавний (10 мин) провал по этому предмету
        if any(o.get("item") == item and (
                o.get("status") in ("queued", "crafting")
                or (o.get("status") == "failed"
                    and time.time() - (o.get("created_at") or 0) < 600))
               for o in orders):
            continue
        need = target - have
        res = _replan_order(item, need)
        if res is None:
            continue
        steps, missing, planned, status = res
        if planned <= 0:
            continue
        with LOCK:
            oid = _next_order_id()
            order = {
                "id": oid, "item": item, "count": planned,
                "status": "queued", "steps": steps, "missing": missing,
                "planned": planned, "step_done": 0, "error": None,
                "created_at": time.time(),
            }
            ORDERS.insert(0, order)
            del ORDERS[MAX_ORDERS:]
            save_orders()
        log("auto-maintain: order #%d %s x%d" % (oid, item, planned))


def auto_maintain_loop():
    tick = 0
    while True:
        time.sleep(AUTO_MAINTENANCE_INTERVAL)
        try:
            _auto_maintain_tick()
            tick += 1
            if tick % 6 == 0:  # каждые ~3 минуты
                _heal_stale_orders()
        except Exception as e:
            log("auto-maintain error: %s" % e)


# ---------------- http ----------------
class Handler(BaseHTTPRequestHandler):
    server_version = "CCStorage/1.0"

    def log_message(self, fmt, *args):
        log("%s - %s" % (self.address_string(), fmt % args))

    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Device-Key")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False))

    def do_OPTIONS(self):
        self._send(204, "")

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = 0
        if length <= 0 or length > 16 * 1024 * 1024:
            return None
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return None

    # ---- auth (сессии + пользователи) ----
    def _client_ip(self):
        xff = self.headers.get("X-Forwarded-For", "")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0]

    def _is_banned(self):
        return self._client_ip() in USERS.get("bans", {})

    @staticmethod
    def _cookie_value(header, name):
        m = re.search(r"(?:^|;\s*)%s=([A-Za-z0-9_.-]+)" % re.escape(name), header or "")
        return m.group(1) if m else None

    def _session_user(self):
        token = self._cookie_value(self.headers.get("Cookie", ""), "session")
        if not token:
            return None
        return verify_session_token(token)

    def _is_device(self):
        if not DEVICE_KEY:
            return True
        return hmac.compare_digest(self.headers.get("X-Device-Key", ""), DEVICE_KEY)

    def _require_login(self):
        if self._is_banned():
            self._json(403, {"error": "banned"})
            return False
        if self._session_user():
            return True
        self._json(401, {"error": "unauthorized"})
        return False

    def _require_admin(self):
        if self._is_banned():
            self._json(403, {"error": "banned"})
            return False
        u = self._session_user()
        if u and USERS["users"].get(u, {}).get("role") == "admin":
            return True
        self._json(403, {"error": "admin only"})
        return False

    def _require_device_or_login(self):
        if self._is_device():
            return True
        if self._is_banned():
            self._json(403, {"error": "banned"})
            return False
        if self._session_user():
            return True
        self._json(403, {"error": "forbidden"})
        return False

    def _serve_file(self, path, ctype):
        fp = os.path.join(BASE_DIR, path)
        if os.path.isfile(fp):
            with open(fp, "rb") as fh:
                self._send(200, fh.read(), ctype, {"Cache-Control": "no-cache"})
        else:
            self._json(404, {"error": "not found"})

    # ---- routes ----
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        try:
            if path == "/":
                if self._session_user():
                    self._serve_file("index.html", "text/html; charset=utf-8")
                else:
                    self._send(302, "", "text/html; charset=utf-8",
                               {"Location": "/login"})

            elif path == "/login":
                if self._session_user():
                    self._send(302, "", "text/html; charset=utf-8",
                               {"Location": "/"})
                else:
                    self._serve_file("login.html", "text/html; charset=utf-8")

            elif path == "/logout":
                self._send(302, "", "text/html; charset=utf-8",
                           {"Location": "/login",
                            "Set-Cookie": "session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"})

            elif path == "/api/me":
                if not self._require_login():
                    return
                u = self._session_user()
                self._json(200, {"username": u,
                                 "role": USERS["users"][u]["role"]})

            elif path == "/api/state":
                if not self._require_login():
                    return
                with LOCK:
                    st = dict(STATE)
                now = time.time()
                online = bool(st.get("updated_at") and now - st["updated_at"] <= 20)
                resp = dict(st)
                resp["online"] = online
                resp["server_time"] = now
                resp["crafter_online"] = bool(
                    CRAFTER_STATE["last_seen"] and now - CRAFTER_STATE["last_seen"] <= 45)
                resp["crafter_last_seen"] = CRAFTER_STATE["last_seen"]
                self._json(200, resp)

            elif path == "/api/info":
                if not self._require_login():
                    return
                self._json(200, {
                    "stats": {"textures": len(TEXTURE_INDEX),
                              "recipes": sum(len(v) for v in RECIPES_BY_RESULT.values())},
                    "port": PORT,
                    "github_sync": GITHUB_SYNC,
                })

            elif path == "/api/recipes":
                if not self._require_login():
                    return
                item = _base_id((qs.get("item") or [""])[0])
                self._json(200, {
                    "recipes": RECIPES_BY_RESULT.get(item, [])[:60],
                    "usage": RECIPES_BY_INPUT.get(item, [])[:60],
                })

            elif path == "/api/texture":
                if not self._require_login():
                    return
                item = _base_id((qs.get("id") or [""])[0])
                fp = TEXTURE_INDEX.get(item)
                if fp and os.path.isfile(fp):
                    with open(fp, "rb") as fh:
                        self._send(200, fh.read(), "image/png",
                                   {"Cache-Control": "max-age=3600"})
                else:
                    self._json(404, {"error": "no texture"})

            elif path == "/api/allitems":
                if not self._require_login():
                    return
                self._json(200, {"items": ALL_ITEMS})

            elif path == "/api/config":
                if not self._require_device_or_login():
                    return
                with LOCK:
                    self._json(200, dict(CONFIG))

            elif path == "/api/orders":
                if not self._require_device_or_login():
                    return
                with LOCK:
                    self._json(200, {"orders": ORDERS[:20]})

            elif path == "/api/orders/next":
                if not self._require_device_or_login():
                    return
                with LOCK:
                    CRAFTER_STATE["last_seen"] = time.time()
                    order = None
                    for o in ORDERS:
                        if o.get("status") == "queued":
                            o["status"] = "crafting"
                            order = o
                            save_orders()
                            break
                self._json(200, {"order": order})

            elif path == "/api/custom-recipes":
                if not self._require_login():
                    return
                with LOCK:
                    self._json(200, {"recipes": CUSTOM_RECIPES})

            elif path == "/api/balance":
                if not self._require_device_or_login():
                    return
                with LOCK:
                    self._json(200, dict(BALANCE_STATE))

            elif path == "/api/users":
                if not self._require_admin():
                    return
                self._json(200, {
                    "users": [{"username": k, "role": v.get("role", "user"),
                               "last_ip": v.get("last_ip")}
                              for k, v in USERS["users"].items()],
                })

            elif path == "/api/bans":
                if not self._require_admin():
                    return
                self._json(200, {"bans": USERS.get("bans", {})})

            elif path == "/main.lua":
                self._serve_file("main.lua", "text/plain; charset=utf-8")

            elif path == "/crafter.lua":
                self._serve_file("crafter.lua", "text/plain; charset=utf-8")

            elif path == "/cannon.lua":
                self._serve_file("cannon.lua", "text/plain; charset=utf-8")

            else:
                self._json(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            self._json(500, {"error": str(e)})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        try:
            if path == "/login":
                self._handle_login()
            elif path == "/api/items" or path == "/":
                if not self._require_device_or_login():
                    return
                self._handle_items()
            elif path == "/api/order":
                if not self._require_login():
                    return
                self._handle_order()
            elif path == "/api/orders/progress":
                if not self._require_device_or_login():
                    return
                CRAFTER_STATE["last_seen"] = time.time()
                self._handle_order_progress()
            elif path == "/api/heartbeat":
                if not self._require_device_or_login():
                    return
                with LOCK:
                    CRAFTER_STATE["last_seen"] = time.time()
                self._json(200, {"ok": True})
            elif path == "/api/balance":
                if not self._require_login():
                    return
                with LOCK:
                    BALANCE_STATE["status"] = "requested"
                    BALANCE_STATE["moved"] = 0
                    BALANCE_STATE["message"] = "ждём компьютер"
                    BALANCE_STATE["requested_at"] = time.time()
                    BALANCE_STATE["updated_at"] = time.time()
                self._json(200, {"ok": True, "status": "requested"})
            elif path == "/api/balance/progress":
                if not self._require_device_or_login():
                    return
                data = self._read_json()
                if isinstance(data, dict):
                    with LOCK:
                        BALANCE_STATE["status"] = data.get("status", "running")
                        BALANCE_STATE["moved"] = int(data.get("moved", 0))
                        BALANCE_STATE["message"] = str(data.get("message", ""))
                        BALANCE_STATE["updated_at"] = time.time()
                self._json(200, {"ok": True})
            elif path == "/api/custom-recipes":
                if not self._require_login():
                    return
                self._handle_custom_recipes_post()
            elif path == "/api/users":
                if not self._require_admin():
                    return
                self._handle_user_add()
            elif path == "/api/users/password":
                self._handle_password_change()
            elif path == "/api/bans":
                if not self._require_admin():
                    return
                self._handle_ban_add()
            elif path == "/api/sessions/kick":
                if not self._require_admin():
                    return
                data = self._read_json() or {}
                username = str(data.get("username") or "").strip()
                KICKED[username] = time.time() + SESSION_TTL
                self._json(200, {"ok": True})
            elif path == "/api/config":
                if not self._require_login():
                    return
                data = self._read_json()
                if not isinstance(data, dict):
                    self._json(400, {"error": "bad json"})
                    return
                with LOCK:
                    for k in CONFIG_DEFAULTS:
                        if k not in data:
                            continue
                        v = data[k]
                        default = CONFIG_DEFAULTS[k]
                        if k == "cannons":
                            out = []
                            if isinstance(v, list):
                                for c in v:
                                    if not isinstance(c, dict):
                                        continue
                                    name = str(c.get("name") or "").strip()
                                    if not name:
                                        continue
                                    ammo = str(c.get("ammo") or "").strip()
                                    if ammo:
                                        out.append({"name": name, "ammo": ammo})
                            CONFIG[k] = out
                        elif isinstance(default, list):
                            CONFIG[k] = [str(x).strip() for x in v
                                         if str(x).strip()] if isinstance(v, list) else []
                        elif isinstance(default, bool):
                            CONFIG[k] = bool(v)
                        elif isinstance(default, int):
                            try:
                                CONFIG[k] = max(0, int(v))
                            except (TypeError, ValueError):
                                CONFIG[k] = default
                        else:
                            CONFIG[k] = str(v).strip()
                    save_config()
                    self._json(200, {"ok": True, "config": dict(CONFIG)})
            else:
                self._json(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            self._json(500, {"error": str(e)})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        try:
            if path == "/api/order":
                if not self._require_login():
                    return
                oid = (qs.get("id") or [""])[0]
                try:
                    oid = int(oid)
                except ValueError:
                    oid = 0
                with LOCK:
                    ORDERS[:] = [o for o in ORDERS if o.get("id") != oid]
                    save_orders()
                self._json(200, {"ok": True})
            elif path == "/api/custom-recipes":
                if not self._require_login():
                    return
                rid = (qs.get("id") or [""])[0]
                with LOCK:
                    CUSTOM_RECIPES[:] = [c for c in CUSTOM_RECIPES if c.get("id") != rid]
                    save_custom_recipes()
                    rebuild_custom_recipe_index()
                self._json(200, {"ok": True})
            elif path == "/api/users":
                if not self._require_admin():
                    return
                name = (qs.get("id") or [""])[0].strip()
                me = self._session_user()
                if not name:
                    self._json(400, {"error": "need id"})
                    return
                if name == me:
                    self._json(400, {"error": "нельзя удалить самого себя"})
                    return
                if name not in USERS["users"]:
                    self._json(404, {"error": "пользователь не найден"})
                    return
                admins = [u for u, v in USERS["users"].items()
                          if v.get("role") == "admin" and u != name]
                if USERS["users"][name].get("role") == "admin" and not admins:
                    self._json(400, {"error": "нельзя удалить последнего админа"})
                    return
                del USERS["users"][name]
                KICKED[name] = time.time() + SESSION_TTL
                save_users()
                self._json(200, {"ok": True})
            elif path == "/api/bans":
                if not self._require_admin():
                    return
                ip = (qs.get("id") or [""])[0].strip()
                USERS.setdefault("bans", {}).pop(ip, None)
                save_users()
                self._json(200, {"ok": True})
            else:
                self._json(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            self._json(500, {"error": str(e)})

    # ---- auth / users / bans handlers ----
    def _handle_login(self):
        if self._is_banned():
            self._json(403, {"error": "banned"})
            return
        data = self._read_json() or {}
        username = str(data.get("username") or "").strip()
        password = str(data.get("password") or "")
        u = USERS["users"].get(username)
        if not u or u.get("hash") != hash_password(password, u.get("salt", "")):
            self._json(401, {"error": "Неверный логин или пароль"})
            return
        token = make_session_token(username)
        ip = self._client_ip()
        if u.get("last_ip") != ip:
            u["last_ip"] = ip
            save_users()
        self._send(200, json.dumps({"ok": True, "user": {"username": username,
                                                         "role": u.get("role", "user")}}),
                   extra={"Set-Cookie": "session=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d"
                          % (token, SESSION_TTL)})

    def _handle_user_add(self):
        data = self._read_json() or {}
        username = str(data.get("username") or "").strip()
        password = str(data.get("password") or "")
        role = data.get("role", "user")
        if role not in ("admin", "user"):
            role = "user"
        if not username or not password:
            self._json(400, {"error": "нужны username и password"})
            return
        if username in USERS["users"]:
            self._json(409, {"error": "пользователь уже существует"})
            return
        salt = secrets.token_hex(16)
        USERS["users"][username] = {"salt": salt,
                                    "hash": hash_password(password, salt),
                                    "role": role}
        save_users()
        self._json(200, {"ok": True, "user": {"username": username, "role": role}})

    def _handle_password_change(self):
        if self._is_banned():
            self._json(403, {"error": "banned"})
            return
        me = self._session_user()
        if not me:
            self._json(401, {"error": "unauthorized"})
            return
        data = self._read_json() or {}
        target = str(data.get("username") or "").strip() or me
        new_password = str(data.get("password") or "")
        is_admin = USERS["users"][me].get("role") == "admin"
        if target != me and not is_admin:
            self._json(403, {"error": "admin only"})
            return
        if not new_password:
            self._json(400, {"error": "нужен password"})
            return
        if target not in USERS["users"]:
            self._json(404, {"error": "пользователь не найден"})
            return
        salt = secrets.token_hex(16)
        USERS["users"][target]["salt"] = salt
        USERS["users"][target]["hash"] = hash_password(new_password, salt)
        if target != me:
            KICKED[target] = time.time() + SESSION_TTL
        save_users()
        self._json(200, {"ok": True})

    def _handle_ban_add(self):
        data = self._read_json() or {}
        ip = str(data.get("ip") or "").strip()
        if not ip:
            self._json(400, {"error": "нужен ip"})
            return
        USERS.setdefault("bans", {})[ip] = {"at": time.time()}
        save_users()
        self._json(200, {"ok": True, "ip": ip})

    def _handle_custom_recipes_post(self):
        data = self._read_json()
        if not isinstance(data, dict):
            self._json(400, {"error": "bad json"})
            return

        def parse_ingredients(raw):
            out = []
            for ing in raw or []:
                if isinstance(ing, dict) and ing.get("item"):
                    try:
                        cnt = max(1, int(ing.get("count", 1)))
                    except (TypeError, ValueError):
                        cnt = 1
                    out.append({"item": str(ing["item"]).strip(), "count": cnt})
            return out

        rid = str(data.get("id") or "").strip()

        # ---------- update existing ----------
        if rid:
            with LOCK:
                target = None
                for c in CUSTOM_RECIPES:
                    if c.get("id") == rid:
                        target = c
                        break
                if target is None:
                    self._json(404, {"error": "not found"})
                    return
                if "output" in data:
                    target["output"] = str(data["output"]).strip()
                if "output_count" in data:
                    try:
                        target["output_count"] = max(1, int(data["output_count"]))
                    except (TypeError, ValueError):
                        pass
                if "method" in data and data["method"] in ("table", "mechanism"):
                    target["method"] = data["method"]
                if "ingredients" in data:
                    target["ingredients"] = parse_ingredients(data["ingredients"])
                if "destination" in data:
                    target["destination"] = str(data["destination"]).strip() or None
                if "mechanism_input" in data:
                    target["mechanism_input"] = str(data["mechanism_input"]).strip()
                if "mechanism_output" in data:
                    target["mechanism_output"] = str(data["mechanism_output"]).strip()
                if "auto_enabled" in data:
                    target["auto_enabled"] = bool(data["auto_enabled"])
                if "auto_target" in data:
                    try:
                        target["auto_target"] = max(0, int(data["auto_target"]))
                    except (TypeError, ValueError):
                        target["auto_target"] = 0
                save_custom_recipes()
                rebuild_custom_recipe_index()
                self._json(200, {"ok": True, "recipe": target})
            return

        # ---------- create new ----------
        output = str(data.get("output") or "").strip()
        method = data.get("method", "table")
        if method not in ("table", "mechanism"):
            method = "table"
        try:
            output_count = max(1, int(data.get("output_count", 1)))
        except (TypeError, ValueError):
            output_count = 1
        ingredients = parse_ingredients(data.get("ingredients"))
        if not output:
            self._json(400, {"error": "need output"})
            return
        if not ingredients:
            self._json(400, {"error": "need ingredients"})
            return
        cr = {
            "id": "custom:%d" % int(time.time() * 1000),
            "output": output,
            "output_count": output_count,
            "method": method,
            "ingredients": ingredients,
            "auto_enabled": bool(data.get("auto_enabled", False)),
            "auto_target": max(0, int(data.get("auto_target") or 0) if data.get("auto_target") else 0),
        }
        if data.get("destination"):
            cr["destination"] = str(data["destination"]).strip()
        if method == "mechanism":
            m_in = str(data.get("mechanism_input") or "").strip()
            m_out = str(data.get("mechanism_output") or "").strip()
            if not m_in or not m_out:
                self._json(400, {"error": "нужны mechanism_input и mechanism_output"})
                return
            cr["mechanism_input"] = m_in
            cr["mechanism_output"] = m_out
        with LOCK:
            CUSTOM_RECIPES.append(cr)
            save_custom_recipes()
            rebuild_custom_recipe_index()
        self._json(200, {"ok": True, "recipe": cr})

    def _handle_order(self):
        data = self._read_json()
        if not isinstance(data, dict):
            self._json(400, {"error": "bad json"})
            return
        item = str(data.get("item") or "").strip()
        try:
            count = max(1, int(data.get("count", 1)))
        except (TypeError, ValueError):
            count = 1
        if not item:
            self._json(400, {"error": "need item"})
            return
        with LOCK:
            res = _replan_order(item, count)
        if res is None:
            self._json(200, {"status": "no_recipe"})
            return
        steps, missing, planned, status = res
        if status == "done":
            self._json(200, {"status": "done"})
            return
        # результат ручного заказа кладём в "куда упаковщики кладут"
        target_vault = (CONFIG.get("packager_target") or "").strip()
        if target_vault:
            for s in steps:
                if not s.get("destination"):
                    s["destination"] = target_vault
        with LOCK:
            oid = _next_order_id()
            order = {
                "id": oid, "item": item, "count": count,
                "status": status, "steps": steps, "missing": missing,
                "planned": planned, "step_done": 0, "error": None,
                "created_at": time.time(),
            }
            ORDERS.insert(0, order)
            del ORDERS[MAX_ORDERS:]
            save_orders()
        self._json(200, {
            "status": status, "id": oid, "steps": steps,
            "missing": missing, "planned": planned,
        })

    def _handle_order_progress(self):
        data = self._read_json()
        if not isinstance(data, dict) or "order" not in data:
            self._json(400, {"error": "bad json"})
            return
        oid = data.get("order")
        status = data.get("status", "ok")
        with LOCK:
            order = None
            for o in ORDERS:
                if o.get("id") == oid:
                    order = o
                    break
            if order is None:
                self._json(404, {"error": "order not found"})
                return
            if status == "fail":
                order["status"] = "failed"
                order["error"] = str(data.get("msg", ""))
            else:
                step = int(data.get("step", 0))
                order["step_done"] = max(order.get("step_done", 0), step)
                if order["step_done"] >= len(order.get("steps") or []):
                    order["status"] = "done"
            save_orders()
            self._json(200, {"ok": True, "status": order["status"]})

    def _handle_items(self):
        data = self._read_json()
        if not isinstance(data, dict):
            self._json(400, {"error": "bad json"})
            return
        items = data.get("items") or {}
        if isinstance(items, list):
            d = {}
            for e in items:
                if isinstance(e, dict) and "id" in e:
                    d[str(e["id"])] = int(e.get("count", 0))
            items = d
        vaults = data.get("vaults") or {}
        missing = data.get("missing") or []
        with LOCK:
            STATE["items"] = {str(k): int(v) for k, v in items.items()}
            STATE["vaults"] = {str(k): {str(i): int(c) for i, c in (v or {}).items()}
                               for k, v in vaults.items()}
            STATE["missing"] = [str(x) for x in missing]
            STATE["computer"] = data.get("computer")
            STATE["updated_at"] = time.time()
            save_state()
        log("storage update: %d item kinds from computer %s"
            % (len(STATE["items"]), STATE["computer"]))
        self._json(200, {"ok": True})


def main():
    log("CC Storage Server starting")
    log("Icons: %d" % scan_info_icons())
    n_items, n_recipes = scan_info_recipes()
    log("Items: %d, recipes: %d, tags: %d" % (n_items, n_recipes, len(TAG_INDEX)))
    load_custom_recipes()
    rebuild_custom_recipe_index()
    log("Custom recipes: %d" % len(CUSTOM_RECIPES))
    load_config()
    load_state()
    load_orders()
    heal_orders()
    load_users()
    log("Users: %d (session auth)" % len(USERS["users"]))
    log("GitHub sync: %s" % ("ON (%s @ %s)" % (GITHUB_REPO, GITHUB_BRANCH)
                              if GITHUB_TOKEN and GITHUB_REPO else "OFF"))
    threading.Thread(target=auto_maintain_loop, daemon=True).start()
    log("Config: %s" % json.dumps(CONFIG, ensure_ascii=False))
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    log("Listening on http://%s:%d" % (HOST, PORT))
    if "PORT" not in os.environ and "--no-browser" not in sys.argv:
        threading.Timer(0.5, lambda: webbrowser.open("http://localhost:%d" % PORT)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
