"""Builds assets/house/presets.json (lib/core/presets.dart) from a household's channel list, and checks the list.

Usage:
    python tools/make_house_presets.py <list.md> --env <.env> [--sportsdb-env <.env>] [--check] [--out assets/house/presets.json]

The list (kept out of the repository) holds:
    Code: 12345678
    Source: My provider
    My Teams: <config.json>     the built-in My Teams channel (MyTeamsTV's config.json: teams, feeds, options), with
                                the TheSportsDB key from SPORTSDB_API_KEY in --env or --sportsdb-env
    My Teams address: <url>     a hosted copy opened first (e.g. a house's Home Assistant /myteams/); the built-in copy
                                when it does not answer
    ## Channels
    - GROUP: word; word         each channel of the provider group whose name holds one of the words
    - GROUP: all                the whole group
    - GROUP -> Name: ...        the group shown on the TV as Name
    ## Web
    - Name: https://...         a site for the guide's Web category

The .env gives the Xtream server (IPTV_XTREAM_URL) written into the preset. With --check it also gives the login to
read the provider's groups and channels (list calls only, no stream) and shows what each line ticks. The login is never
written or printed.
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.parse
import urllib.request


def read_env(path):
    values = {}
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"')
    return values


def read_list(path):
    """(code, source name, guides, groups, sites, (My Teams config path, My Teams address)) from the list."""
    code = source = myteams = myteams_url = None
    guides = []
    groups, sites = [], []
    section = None
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("## "):
            section = line[3:].strip().lower()
            continue
        if line.lower().startswith("code:"):
            code = line.split(":", 1)[1].strip()
        elif line.lower().startswith("source:"):
            source = line.split(":", 1)[1].strip()
        elif line.lower().startswith("my teams address:"):
            myteams_url = line.split(":", 1)[1].strip()
        elif line.lower().startswith("my teams:"):
            myteams = line.split(":", 1)[1].strip()
        elif line.lower().startswith("guides:"):
            # epgshare01 files ticked with the picks (lib/core/guide.dart epgFiles codes: UK, NO, US, US_SPORTS, CA...)
            guides = [g.strip().upper() for g in line.split(":", 1)[1].split(",") if g.strip()]
        elif not line.startswith("- ") or "`" in line:
            continue
        elif section == "channels":
            spec, _, picks = line[2:].partition(":")
            group, _, name = spec.partition("->")
            entry = {"group": group.strip()}
            if name.strip():
                entry["name"] = name.strip()
            if picks.strip().lower() == "all":
                entry["all"] = True
            else:
                entry["channels"] = [p.strip().lower() for p in picks.split(";") if p.strip()]
            groups.append(entry)
        elif section == "web":
            m = re.match(r"^- (.+?):\s+(https?://\S+)$", line)
            if m:
                sites.append({"name": m.group(1).strip(), "url": m.group(2)})
    if not code or not source:
        sys.exit("the list needs a Code: and a Source: line")
    return code, source, guides, groups, sites, (myteams, myteams_url)


def provider_call(base, user, password, action):
    query = urllib.parse.urlencode({"username": user, "password": password, "action": action})
    req = urllib.request.Request(f"{base}/player_api.php?{query}", headers={"User-Agent": "NevermoreIPTV-check"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def check(env, groups):
    """Prints what each line ticks at the provider now (as lib/core/presets.dart applies it)."""
    base = env["IPTV_XTREAM_URL"].rstrip("/")
    user, password = env["IPTV_XTREAM_USERNAME"], env["IPTV_XTREAM_PASSWORD"]
    categories = provider_call(base, user, password, "get_live_categories")
    streams = provider_call(base, user, password, "get_live_streams")
    by_name = {str(c.get("category_name", "")).strip().lower(): str(c.get("category_id")) for c in categories}
    total, problems = 0, 0
    for g in groups:
        gid = by_name.get(g["group"].lower())
        label = g["group"] + (f" -> {g['name']}" if "name" in g else "")
        if gid is None:
            print(f"  MISSING group {g['group']}")
            problems += 1
            continue
        members = [s for s in streams if str(s.get("category_id")) == gid]
        if g.get("all"):
            print(f"  {label}: all {len(members)}")
            total += len(members)
            continue
        ticked = []
        for word in g["channels"]:
            hits = [s["name"] for s in members if word in str(s.get("name", "")).lower()]
            if not hits:
                print(f"  MISSING in {g['group']}: {word}")
                problems += 1
            ticked += [h for h in hits if h not in ticked]
        print(f"  {label}: {len(ticked)} - {' | '.join(ticked)}")
        total += len(ticked)
    print(f"{total} channels, {problems} line(s) to look at")


SCRYPT_N = 16384


def lock_login(code, username, password):
    """The login locked with the code: scrypt for the key, AES-256-GCM for the text (lib/core/preset_lock.dart opens
    it). The code itself is not written down: the TV finds the preset by the code opening it."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    salt, nonce = os.urandom(16), os.urandom(12)
    key = hashlib.scrypt(code.encode(), salt=salt, n=SCRYPT_N, r=8, p=1, dklen=32, maxmem=64 * 1024 * 1024)
    data = AESGCM(key).encrypt(nonce, json.dumps({"username": username, "password": password}).encode(), None)
    b64 = lambda b: base64.b64encode(b).decode()
    return {"kdf": "scrypt", "n": SCRYPT_N, "r": 8, "p": 1, "len": len(code), "cipher": "aes-256-gcm",
            "salt": b64(salt), "nonce": b64(nonce), "data": b64(data)}


def main():
    args = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    args.add_argument("list")
    args.add_argument("--env", required=True)
    args.add_argument("--sportsdb-env", help="a .env holding SPORTSDB_API_KEY, for the My Teams channel")
    args.add_argument("--check", action="store_true")
    args.add_argument("--out", default=str(pathlib.Path(__file__).resolve().parent.parent / "assets/house/presets.json"))
    a = args.parse_args()
    code, source, guides, groups, sites, (myteams, myteams_url) = read_list(a.list)
    env = read_env(a.env)
    # no plain code in the file: the login is locked with it (Mark, 27 Oct 2026: "i want to ship it with this")
    preset = {"name": source, "server": env["IPTV_XTREAM_URL"], "groups": groups}
    if guides:
        preset["guides"] = guides
    preset["lock"] = lock_login(code, env["IPTV_XTREAM_USERNAME"], env["IPTV_XTREAM_PASSWORD"])
    house = {"presets": [preset], "sites": sites}
    if myteams:
        # the key travels plain in the house file: Mark is the app's only user (15 Nov 2026: "im the only person to
        # use the app so it can carry"); lib/core/myteams_server.dart keeps it off the page itself
        key = env.get("SPORTSDB_API_KEY") or (read_env(a.sportsdb_env).get("SPORTSDB_API_KEY") if a.sportsdb_env else None)
        if not key:
            sys.exit("My Teams needs SPORTSDB_API_KEY: in --env, or pass --sportsdb-env <.env>")
        house["myteams"] = {"key": key, "config": json.loads(pathlib.Path(myteams).read_text(encoding="utf-8"))}
        if myteams_url:
            # the house's hosted copy (Home Assistant's myteams_tv), opened first; the built-in one when it does not answer
            house["myteams"]["url"] = myteams_url if myteams_url.endswith("/") else myteams_url + "/"
    out = pathlib.Path(a.out)
    out.write_text(json.dumps(house, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    teams = len(house.get("myteams", {}).get("config", {}).get("teams", []))
    print(f"wrote {out}: {len(groups)} groups, {len(sites)} sites" + (f", My Teams ({teams} teams)" if myteams else ""))
    if a.check:
        check(env, groups)


main()
