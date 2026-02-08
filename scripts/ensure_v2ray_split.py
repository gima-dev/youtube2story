#!/usr/bin/env python3
"""
ensure_v2ray_split.py

Найти конфиги v2RayTun и добавить/обновить routing правило,
которое направляет диапазоны Cloudflare через outbound с тегом "direct".

Использование:
  ./ensure_v2ray_split.py [paths...]

Если пути не указаны, скрипт ищет в:
  ~/Library/Group Containers/**/Configs/*.json

Скрипт делает резервную копию каждого изменяемого файла с суффиксом .bak.TIMESTAMP
"""
import json
import glob
import os
import shutil
import sys
from datetime import datetime

CF_RANGES = [
    "198.41.128.0/17",
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "162.158.0.0/15",
    "104.16.0.0/12",
    "172.64.0.0/13",
    "131.0.72.0/22",
]


def find_candidate_files(args):
    if args:
        files = []
        for p in args:
            files.extend(glob.glob(os.path.expanduser(p)))
        return files

    base = os.path.expanduser("~/Library/Group Containers")
    pattern = os.path.join(base, "**", "Configs", "*.json")
    return glob.glob(pattern, recursive=True)


def backup_file(path):
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    bak = f"{path}.bak.{ts}"
    shutil.copy2(path, bak)
    return bak


def ensure_routing(data):
    routing = data.get("routing")
    rule = {
        "type": "field",
        "ip": CF_RANGES,
        "outboundTag": "direct",
    }

    if routing is None:
        data["routing"] = {
            "domainStrategy": "IPIfNonMatch",
            "rules": [rule],
        }
        return True

    # routing exists
    rules = routing.get("rules")
    if not isinstance(rules, list):
        routing["rules"] = [rule]
        return True

    # Check if a rule with outboundTag direct and CF ranges already exists
    for r in rules:
        if r.get("outboundTag") == "direct":
            ips = r.get("ip") or []
            # if any CF range missing, extend
            missing = [x for x in CF_RANGES if x not in ips]
            if missing:
                r.setdefault("ip", []).extend(missing)
                return True
            return False

    # no matching direct rule -> prepend
    rules.insert(0, rule)
    return True


def process_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"SKIP {path}: failed to read JSON: {e}")
        return False

    changed = ensure_routing(data)
    if not changed:
        print(f"NOCHANGE {path}")
        return False

    bak = backup_file(path)
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f"UPDATED {path} (backup: {bak})")
        return True
    except Exception as e:
        print(f"FAIL {path}: failed to write: {e}")
        # attempt restore
        try:
            shutil.copy2(bak, path)
            print(f"RESTORED {path} from {bak}")
        except Exception:
            print(f"FAILED TO RESTORE {path}")
        return False


def main():
    args = sys.argv[1:]
    files = find_candidate_files(args)
    if not files:
        print("No candidate config files found.")
        print("You can pass explicit paths to check, e.g.: ./ensure_v2ray_split.py '/Users/gima/Library/Group Containers/**/Configs/*.json'")
        return 1

    for path in files:
        process_file(path)

    return 0


if __name__ == '__main__':
    sys.exit(main())
