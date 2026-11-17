#!/usr/bin/env python3
"""zradio-usb-ids.py — builds usb-ids.json, the table of USB sticks the kit knows: the USB ids Home Assistant's own
integrations list for Zigbee and Z-Wave sticks, plus what the kit adds (usb-annotations.json, next to this file:
family, serial settings, which port of a two-port adapter, and sticks Home Assistant's lists do not carry). Run at
install time, by install.sh on the node and by guest/install.sh in a VM that was not given the node's table. The
table is not kept in the repository: it is made from these two sources each time.

    zradio-usb-ids.py --out FILE        # FILE written whole or not at all; a summary on stderr

Reads raw.githubusercontent.com/home-assistant/core/<commit>/homeassistant/components/<c>/manifest.json for the
components in COMPONENTS, at the commit pinned in usb-annotations.json (home_assistant_core_commit), so every install
of one version of the kit builds the same table. ZRADIO_USB_IDS_SOURCE=<dir>: read <dir>/<c>/manifest.json instead
(the tests: tests/fixtures/ha-core). Home Assistant core is Apache-2.0; the ids are facts about hardware. Stdlib only.
What is read is checked before a table is made of it: the pin is a full commit id (a branch or tag name would move
under the installs), a manifest is at most MAX_BYTES, and each USB entry has the shape zradio-detect reads.
Exit 1 when the pin is not a commit, or a manifest cannot be read or is not what it should be (nothing is written
then), 2 on a usage error."""
import json, os, re, sys, urllib.request

COMPONENTS = {"zha": "zigbee", "zwave_js": "zwave", "homeassistant_sky_connect": "zigbee", "homeassistant_connect_zbt2": "zigbee"}
HERE = os.path.dirname(os.path.abspath(__file__))
MAX_BYTES = 1 << 20      # a manifest is a few kB (zha's, the longest, about 10): what is longer is not one


def manifest(commit, comp):
    """One component's USB entries, each checked: vid and pid 4 hex digits; description and manufacturer, where given,
    strings; known_devices, where given, a list of strings. ValueError says what is wrong."""
    src = os.environ.get("ZRADIO_USB_IDS_SOURCE", "")
    if src: f = open(os.path.join(src, comp, "manifest.json"), "rb")
    else: f = urllib.request.urlopen("https://raw.githubusercontent.com/home-assistant/core/%s/homeassistant/components/%s/manifest.json"
                                     % (commit, comp), timeout=30)
    with f: raw = f.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES: raise ValueError("larger than %d bytes: not a manifest" % MAX_BYTES)
    m = json.loads(raw)
    usb = m.get("usb", []) if isinstance(m, dict) else None
    if not isinstance(usb, list): raise ValueError("not a manifest with a list of USB entries")
    for u in usb:
        ok = (isinstance(u, dict) and all(isinstance(u.get(k), str) and re.fullmatch(r"[0-9A-Fa-f]{4}", u[k]) for k in ("vid", "pid"))
              and all(isinstance(u.get(k, ""), str) for k in ("description", "manufacturer"))
              and isinstance(u.get("known_devices", []), list) and all(isinstance(d, str) for d in u.get("known_devices", [])))
        if not ok: raise ValueError("a USB entry of another shape than the kit reads: %s" % json.dumps(u)[:160])
    return usb


def main():
    args = sys.argv[1:]
    if len(args) != 2 or args[0] != "--out":
        print(__doc__, file=sys.stderr); return 2
    path = args[1]
    ann = json.load(open(os.path.join(HERE, "usb-annotations.json")))
    commit = ann["home_assistant_core_commit"]
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):      # it goes into a URL, and names what every install reads
        print("FAIL  home_assistant_core_commit in usb-annotations.json is %r: a full commit id is wanted (40 hex digits), "
              "not a branch or a tag" % (commit,), file=sys.stderr); return 1
    entries, used = [], set()
    for comp, kind in COMPONENTS.items():
        try: usb = manifest(commit, comp)
        except Exception as e:
            print("FAIL  Home Assistant's USB list for %s (commit %s): %s" % (comp, commit[:12], e), file=sys.stderr); return 1
        for u in usb:
            e = {"vid": u["vid"].upper(), "pid": u["pid"].upper(), "description": u.get("description", "*").lower(), "kind": kind,
                 "known_devices": u.get("known_devices", []), "source": "home-assistant:" + comp}
            if u.get("manufacturer"): e["manufacturer"] = u["manufacturer"].lower()
            key = "%s:%s %s" % (e["vid"], e["pid"], e["description"])
            a = ann["annotate"].get(key)
            if a: used.add(key)
            a = a or {}
            e["family"] = a.get("family", ""); e["baud"] = a.get("baud", 115200); e["flow"] = a.get("flow", "none")
            e["proven"] = bool(a.get("proven", False)); e["annotated"] = key in used
            for k in ("iface", "note"):
                if k in a: e[k] = a[k]
            if e not in entries: entries.append(e)
    unused = sorted(set(ann["annotate"]) - used)
    for a in ann["add"]:
        e = dict(a); e["vid"] = e["vid"].upper(); e["pid"] = e["pid"].upper(); e.setdefault("proven", False); e["annotated"] = True
        entries.append(e)
    out = {"format": "zradio usb ids v1", "home_assistant_core_commit": commit,
           "_comment": "Built at install time by zradio-usb-ids.py; do not edit. 'description' is matched like Home Assistant "
                       "matches it: a case-insensitive glob on the USB product string. proven=true: served, synced and failed "
                       "over on real hardware by this project.",
           "entries": entries}
    try:
        with open(path + ".tmp", "w") as f: json.dump(out, f, indent=1, sort_keys=True)
        os.replace(path + ".tmp", path)
    except OSError as e:
        print("FAIL  %s not written: %s" % (path, e), file=sys.stderr); return 1
    print("usb-ids.json: %d sticks (%d from Home Assistant's lists at %s, %d added by the kit)"
          % (len(entries), len(entries) - len(ann["add"]), commit[:12], len(ann["add"])), file=sys.stderr)
    for k in unused: print("WARN  annotation without a list entry (the list changed?): %s" % k, file=sys.stderr)
    for e in entries:
        if not e["annotated"]:
            print("NOTE  no annotation (family unknown, 115200 8N1 assumed): %s:%s %s %s"
                  % (e["vid"], e["pid"], e["description"], e["known_devices"]), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
