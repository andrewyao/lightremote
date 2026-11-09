#!/usr/bin/env python3
"""Geotag photos imported from the A7II using LightRemote's GPX tracks.

    python3 MacHelper/geotag.py ~/Pictures/2026-11-07            # GPX from iCloud Drive › LightRemote › GPX
    python3 MacHelper/geotag.py FOLDER --gpx-dir ~/Downloads      # GPX somewhere else
    python3 MacHelper/geotag.py FOLDER --dry-run                  # show what would happen

How matching works: the camera stores DateTimeOriginal in local time with no zone. LightRemote's GPX
records, per day, the camera clock offset it measured (camera wall clock minus UTC; this covers the camera's
time zone, DST setting and drift together) and the phone's UTC offset at every change. This script works out
the true UTC time of each photo and lets exiftool write GPS into the file (ARW, JPG, HIF; RAWs included).

Requires exiftool (brew install exiftool).
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

GPX_NS = "{http://www.topografix.com/GPX/1/1}"
LR_NS = "{https://lightremote.app/gpx/1}"
ICLOUD_GPX = os.path.expanduser("~/Library/Mobile Documents/iCloud~com~andrewyao~LightRemote/Documents/GPX")
PHOTO_EXT = ["ARW", "JPG", "JPEG", "HIF", "HEIC", "DNG"]
MAX_GAP = 300  # seconds from the nearest track point; matches the app


def parse_time(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


class Track:
    def __init__(self, path):
        self.path = path
        root = ET.parse(path).getroot()
        self.points = [parse_time(t.text) for t in root.iter(f"{GPX_NS}time") if t.text and
                       t.text[:4].isdigit()]
        self.points = sorted(set(self.points))
        self.utc_offsets = sorted((parse_time(e.get("from")), int(e.get("minutes")))
                                  for e in root.iter(f"{LR_NS}utcOffset"))
        self.clock = [int(e.get("cameraMinusUtcSeconds")) for e in root.iter(f"{LR_NS}cameraClock")]
        self.day = os.path.splitext(os.path.basename(path))[0]

    def covers(self, utc):
        return any(abs((p - utc).total_seconds()) <= MAX_GAP for p in self.nearby(utc))

    def nearby(self, utc):
        # points are sorted; binary search would be faster, but tracks are small
        return [p for p in self.points if abs((p - utc).total_seconds()) <= MAX_GAP]

    def phone_offset_seconds(self, around_utc):
        best = None
        for start, minutes in self.utc_offsets:
            if start <= around_utc or best is None:
                best = minutes
        return None if best is None else best * 60


def read_photos(folder):
    cmd = ["exiftool", "-json", "-r", "-q", "-DateTimeOriginal", "-SubSecTimeOriginal"]
    for e in PHOTO_EXT:
        cmd += ["-ext", e]
    out = subprocess.run(cmd + [folder], capture_output=True, text=True)
    photos = []
    for item in json.loads(out.stdout or "[]"):
        s = item.get("DateTimeOriginal")
        if not s or s.startswith("0000"):
            continue
        photos.append((item["SourceFile"], dt.datetime.strptime(s[:19], "%Y:%m:%d %H:%M:%S")))
    return photos


def choose_offset(tracks_by_day, wall):
    """Seconds to subtract from the camera wall clock to get UTC, and where the number came from."""
    day = wall.strftime("%Y-%m-%d")
    candidates = [tracks_by_day[d] for d in (day,) if d in tracks_by_day]
    for t in candidates:
        if t.clock:
            return statistics.median(t.clock), f"measured camera clock ({len(t.clock)} remote shots)"
    # No measurement: assume the camera showed correct local time; use the phone's zone for that moment.
    near = candidates or list(tracks_by_day.values())
    for t in near:
        guess = wall.replace(tzinfo=dt.timezone.utc)
        off = t.phone_offset_seconds(guess)
        if off is not None:
            # refine once: the guess was off by the zone itself
            off = t.phone_offset_seconds(guess - dt.timedelta(seconds=off))
            return off, "phone time zone (camera clock assumed correct)"
    return None, "no GPX for this day"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder")
    ap.add_argument("--gpx-dir", default=ICLOUD_GPX)
    ap.add_argument("--shift", default="0", help="extra camera clock correction, e.g. 1h, -30s, 2m "
                                                 "(positive = camera was fast)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-backup", action="store_true", help="don't keep *_original copies")
    args = ap.parse_args()

    if not shutil.which("exiftool"):
        sys.exit("exiftool not found. Install it with: brew install exiftool")
    gpx_files = sorted(glob.glob(os.path.join(os.path.expanduser(args.gpx_dir), "*.gpx")))
    if not gpx_files:
        sys.exit(f"No GPX files in {args.gpx_dir}. Use --gpx-dir to point at them.")
    tracks = {}
    for f in gpx_files:
        try:
            t = Track(f)
            tracks[t.day] = t
        except ET.ParseError as e:
            print(f"skipping {f}: {e}")
    photos = read_photos(args.folder)
    if not photos:
        sys.exit("No photos with DateTimeOriginal found.")

    unit = {"h": 3600, "m": 60, "s": 1}
    shift = int(float(args.shift[:-1]) * unit[args.shift[-1]]) if args.shift[-1] in unit else int(args.shift)

    groups = {}   # offset seconds -> [files]
    misses = []
    for path, wall in photos:
        off, source = choose_offset(tracks, wall)
        if off is None:
            misses.append((path, source))
            continue
        off += shift
        utc = (wall - dt.timedelta(seconds=off)).replace(tzinfo=dt.timezone.utc)
        if not any(t.covers(utc) for t in tracks.values()):
            misses.append((path, "outside the recorded track"))
            # DST / zone sanity check: would the photo land on the track an hour either way?
            for delta in (3600, -3600):
                if any(t.covers(utc - dt.timedelta(seconds=delta)) for t in tracks.values()):
                    misses[-1] = (path, f"outside the track, but fits with --shift {delta // 3600:+d}h")
                    break
            continue
        groups.setdefault(off, []).append(path)

    tagged = sum(len(v) for v in groups.values())
    print(f"{len(photos)} photos · {tagged} on the track · {len(misses)} not")
    hints = [why for _, why in misses if "--shift" in why]
    if hints and len(hints) >= len(misses) / 2:
        print(f"⚠ Most unmatched photos fit an hour off. The camera's DST setting was probably wrong: "
              f"rerun with {hints[0].split('with ')[-1]}")
    for off, files in sorted(groups.items()):
        sign = "+" if off >= 0 else "-"
        a = abs(int(off))
        print(f"  camera clock = UTC {sign}{a // 3600:02d}:{a % 3600 // 60:02d}:{a % 60:02d}  → {len(files)} photos")

    if args.dry_run or not groups:
        for p, why in misses[:20]:
            print(f"  skip {os.path.basename(p)}: {why}")
        return

    written = 0
    for off, files in groups.items():
        with tempfile.NamedTemporaryFile("w", suffix=".args", delete=False) as argfile:
            argfile.write("\n".join(files))
        # Treat DateTimeOriginal as UTC; exiftool adds Geosync to that, so pass -off to land on true UTC.
        cmd = ["exiftool", "-api", f"GeoMaxIntSecs={MAX_GAP * 2}", "-api", f"GeoMaxExtSecs={MAX_GAP}",
               "-Geotime<${DateTimeOriginal}+00:00", f"-Geosync={-int(off):+d}"]
        for f in gpx_files:
            cmd += ["-geotag", f]
        if args.no_backup:
            cmd.append("-overwrite_original")
        cmd += ["-@", argfile.name]
        result = subprocess.run(cmd, capture_output=True, text=True)
        os.unlink(argfile.name)
        m = re.search(r"(\d+) image files? updated", result.stdout)
        written += int(m.group(1)) if m else 0
        for line in result.stderr.splitlines():
            if "Warning" in line or "Error" in line:
                print("  exiftool:", line.strip())
    print(f"Done. GPS written to {written} of {tagged} photos."
          + ("" if args.no_backup or not written else " Originals kept as *_original."))
    if written < tagged:
        sys.exit(1)


if __name__ == "__main__":
    main()
