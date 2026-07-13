#!/usr/bin/env python3
"""
Generate a MiSTer Downloader / Update_All database (db.json.zip) for this repo's
GitHub release, so the core can be installed & updated via the update_all script.

The database maps each release asset to its SD-card destination:
    _Arcade/<Full MRA Name>.mra          <- the .mra files
    _Arcade/cores/<rbf filename>.rbf     <- the FPGA core
Each entry carries the MD5 hash + size the Downloader verifies, and an explicit
`url` pointing straight at the GitHub *release asset* (so the repo tree does not
need to mirror the SD layout).

Usage:
    python3 tools/gen_update_all_db.py --repo derpyder/Arcade-NightSlashers_MiSTer --tag v1.3
Requires network (queries the GitHub releases API for the real asset URLs/sizes)
and the matching files present in ./releases/ (used for the proper SD filenames
+ MD5). Emits ./nightslashers.json and ./nightslashers.json.zip in the repo root.

Re-run after each release (change --tag) and commit the refreshed .json.zip.
"""
import argparse, hashlib, io, json, os, sys, urllib.request, zipfile

DB_ID   = "derpyder_nightslashers"
DB_NAME = "nightslashers"                     # <DB_NAME>.json(.zip)
BRANCH  = "main"                              # branch the .json.zip is hosted on

def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()

def fetch_release_assets(repo, tag):
    url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "gen-update-all-db"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    return {a["size"]: a for a in data["assets"]}   # keyed by size (assets have distinct sizes)

def sd_path(fname):
    return f"_Arcade/cores/{fname}" if fname.lower().endswith(".rbf") else f"_Arcade/{fname}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="derpyder/Arcade-NightSlashers_MiSTer")
    ap.add_argument("--tag",  default="v1.3")
    ap.add_argument("--releases-dir", default=None)
    a = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rel  = a.releases_dir or os.path.join(root, "releases")
    local = [f for f in os.listdir(rel) if f.lower().endswith((".rbf", ".mra"))]
    if not local:
        sys.exit(f"no .rbf/.mra found in {rel}")

    assets_by_size = fetch_release_assets(a.repo, a.tag)

    files = {}
    for fname in sorted(local):
        p = os.path.join(rel, fname)
        size = os.path.getsize(p)
        asset = assets_by_size.get(size)
        if not asset:
            sys.exit(f"no release asset of size {size} for local file {fname} "
                     f"(is {fname} part of release {a.tag}?)")
        files[sd_path(fname)] = {
            "hash": md5(p),
            "size": size,
            "url":  asset["browser_download_url"],
        }
        print(f"  {sd_path(fname):55s} {size:>8d}  {os.path.basename(asset['browser_download_url'])}")

    db = {
        "db_id":  DB_ID,
        "db_url": f"https://raw.githubusercontent.com/{a.repo}/{BRANCH}/{DB_NAME}.json.zip",
        "files":  files,
        "folders": {"_Arcade": {}, "_Arcade/cores": {}},
    }

    json_path = os.path.join(root, f"{DB_NAME}.json")
    zip_path  = os.path.join(root, f"{DB_NAME}.json.zip")
    blob = json.dumps(db, indent=2).encode()
    with open(json_path, "wb") as f:
        f.write(blob)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{DB_NAME}.json", blob)      # inner name matches the zip basename
    print(f"\nwrote {json_path}\nwrote {zip_path}  (db_url = {db['db_url']})")

if __name__ == "__main__":
    main()
