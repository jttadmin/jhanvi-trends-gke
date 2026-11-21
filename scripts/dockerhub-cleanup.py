#!/usr/bin/env python3
"""Delete old Jhanvi Trends image tags from Docker Hub, keeping everything that is (or recently was) in use.

A tag is KEPT if any of these is true:
  * it is referenced in deploy/charts/jhanvi-trends/values*.yaml (dev/stage/prod deploy it)
  * it is one of the newest --keep-last tags of that image
  * it was pushed within the last --keep-days days
  * it is listed in --keep-tags, or it is "latest"
Everything else under <namespace>/<prefix>* is deleted, but ONLY with --delete; the default is a dry run.

Env: DOCKERHUB_USERNAME, DOCKERHUB_TOKEN (a personal access token with Read, Write, Delete scope).
Uses only the Python standard library.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request

HUB = "https://hub.docker.com"
SHA_TAG = re.compile(r"\btag:\s*['\"]?([0-9A-Za-z._-]+)")


def http(method, url, token=None, body=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as res:  # noqa: S310 - fixed https host
            text = res.read().decode()
            return res.status, json.loads(text) if text else None
    except urllib.error.HTTPError as err:
        return err.code, None


def login(user, secret):
    # Current endpoint first, then the legacy one (both accept a personal access token).
    status, body = http("POST", f"{HUB}/v2/auth/token", body={"identifier": user, "secret": secret})
    if status == 200 and body and body.get("access_token"):
        return body["access_token"]
    status, body = http("POST", f"{HUB}/v2/users/login", body={"username": user, "password": secret})
    if status == 200 and body and body.get("token"):
        return body["token"]
    sys.exit(f"Docker Hub login failed (HTTP {status}). Check DOCKERHUB_USERNAME / DOCKERHUB_TOKEN.")


def paged(url, token):
    while url:
        status, body = http("GET", url, token)
        if status != 200:
            sys.exit(f"GET {url} failed with HTTP {status}")
        yield from body.get("results", [])
        url = body.get("next")


def deployed_tags(chart_dir):
    tags = set()
    for path in glob.glob(os.path.join(chart_dir, "values*.yaml")):
        with open(path, encoding="utf-8") as f:
            tags.update(SHA_TAG.findall(f.read()))
    return tags


def pushed_at(tag):
    stamp = tag.get("tag_last_pushed") or tag.get("last_updated")
    return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00")) if stamp else dt.datetime.now(dt.UTC)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--namespace", default="jhanviadmin")
    p.add_argument("--prefix", default="jhanvi-trends-")
    p.add_argument("--chart", default="deploy/charts/jhanvi-trends")
    p.add_argument("--keep-last", type=int, default=10)
    p.add_argument("--keep-days", type=int, default=14)
    p.add_argument("--keep-tags", default="", help="comma/space separated extra tags to keep")
    p.add_argument("--delete", action="store_true", help="actually delete (default: dry run)")
    a = p.parse_args()

    deployed = deployed_tags(a.chart)
    keep_always = deployed | {"latest"} | {t for t in re.split(r"[,\s]+", a.keep_tags) if t}
    print(f"Deployed (always kept): {sorted(deployed) or 'none found'}")
    print(f"Also always kept: {sorted(keep_always - deployed)}")
    if not deployed:
        sys.exit("Refusing to run: no deployed tags found in the Helm values (wrong --chart path?).")

    token = login(os.environ["DOCKERHUB_USERNAME"], os.environ["DOCKERHUB_TOKEN"])
    cutoff = dt.datetime.now(dt.UTC) - dt.timedelta(days=a.keep_days)
    repos = [r["name"] for r in paged(f"{HUB}/v2/namespaces/{a.namespace}/repositories?page_size=100", token)
             if r["name"].startswith(a.prefix)]
    print(f"Images: {', '.join(sorted(repos))}\n")

    total_del = total_bytes = failed = 0
    for repo in sorted(repos):
        tags = sorted(paged(f"{HUB}/v2/namespaces/{a.namespace}/repositories/{repo}/tags?page_size=100", token),
                      key=pushed_at, reverse=True)
        newest = {t["name"] for t in tags[: a.keep_last]}
        doomed = [t for t in tags
                  if t["name"] not in keep_always and t["name"] not in newest and pushed_at(t) < cutoff]
        size = sum(t.get("full_size") or 0 for t in doomed)
        print(f"{repo}: {len(tags)} tags, keep {len(tags) - len(doomed)}, delete {len(doomed)} (~{size / 1e6:.0f} MB)")
        for t in doomed:
            line = f"    {t['name']}  pushed {pushed_at(t):%Y-%m-%d}"
            if not a.delete:
                print(line + "  [dry run]")
                continue
            status, _ = http("DELETE", f"{HUB}/v2/namespaces/{a.namespace}/repositories/{repo}/tags/{t['name']}", token)
            if status not in (200, 202, 204):
                status, _ = http("DELETE", f"{HUB}/v2/repositories/{a.namespace}/{repo}/tags/{t['name']}/", token)
            ok = status in (200, 202, 204)
            failed += not ok
            print(line + ("  deleted" if ok else f"  FAILED (HTTP {status})"))
        total_del += len(doomed)
        total_bytes += size

    verb = "Deleted" if a.delete else "Would delete"
    print(f"\n{verb} {total_del - failed} tags (~{total_bytes / 1e9:.2f} GB).")
    if not a.delete:
        print("Dry run only. Re-run with delete enabled to remove them.")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
