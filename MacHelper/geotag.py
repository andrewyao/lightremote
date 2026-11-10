#!/usr/bin/env python3
"""Geotag photos imported from the A7II using LightRemote's GPX tracks.

    python3 MacHelper/geotag.py ~/Pictures/2026-11-07            # GPX from iCloud Drive › LightRemote › GPX
    python3 MacHelper/geotag.py FOLDER --gpx-dir ~/Downloads      # GPX somewhere else
    python3 MacHelper/geotag.py FOLDER --dry-run                  # show what would happen

How matching works: the camera stores DateTimeOriginal in local time with no zone. LightRemote's GPX
records timestamped camera clock measurements (camera wall clock minus UTC; this covers the camera's
time zone, DST setting and drift together) and phone UTC-offset changes. This script matches those periods
to recorded GPS coverage and lets exiftool write GPS into the file (ARW, JPG, HIF; RAWs included). Ambiguous
wall times after a backward clock change are skipped. Missing GPS fixes are never filled with invented stays.

Requires exiftool (brew install exiftool).
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import shutil
from bisect import bisect_left
import subprocess
import sys
import xml.etree.ElementTree as ET

GPX_NS = "{http://www.topografix.com/GPX/1/1}"
LR_NS = "{https://lightremote.app/gpx/1}"
ICLOUD_GPX = os.path.expanduser("~/Library/Mobile Documents/iCloud~com~andrewyao~LightRemote/Documents/GPX")
PHOTO_EXT = ["ARW", "JPG", "JPEG", "HIF", "HEIC", "DNG"]
MAX_GAP = 300  # seconds from the nearest track point; matches the app


def parse_time(s):
    value = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    if value.tzinfo is None:
        raise ValueError("GPX timestamps must include a UTC offset")
    return value.astimezone(dt.timezone.utc)


class Track:
    def __init__(self, path):
        self.path = path
        root = ET.parse(path).getroot()
        self.points = [parse_time(t.text) for point in root.iter(f"{GPX_NS}trkpt")
                       if (t := point.find(f"{GPX_NS}time")) is not None and t.text]
        self.points = sorted(set(self.points))
        self.utc_offsets = sorted((parse_time(e.get("from")), int(e.get("minutes")))
                                  for e in root.iter(f"{LR_NS}utcOffset"))
        self.clock = sorted((parse_time(e.get("measuredAt")), int(e.get("cameraMinusUtcSeconds")))
                            for e in root.iter(f"{LR_NS}cameraClock"))
        self.day = os.path.splitext(os.path.basename(path))[0]

    def covers(self, utc):
        i = bisect_left(self.points, utc)
        return any(abs((p - utc).total_seconds()) <= MAX_GAP for p in self.points[max(0, i - 1):i + 1])


def read_photos(folder):
    cmd = ["exiftool", "-json", "-r", "-q", "-DateTimeOriginal", "-SubSecTimeOriginal"]
    for e in PHOTO_EXT:
        cmd += ["-ext", e]
    out = subprocess.run(cmd + [os.path.abspath(os.path.expanduser(folder))],
                         capture_output=True, text=True, check=True)
    photos = []
    for item in json.loads(out.stdout or "[]"):
        s = item.get("DateTimeOriginal")
        if not s or s.startswith("0000"):
            continue
        try:
            wall = dt.datetime.strptime(s[:19], "%Y:%m:%d %H:%M:%S")
        except ValueError:
            print(f"skipping invalid DateTimeOriginal in {item['SourceFile']}")
            continue
        photos.append((os.path.abspath(item["SourceFile"]), wall))
    return photos


def clock_periods(entries):
    """Collapse small measurement noise, keeping the first timestamp of each distinct clock setting."""
    periods = []
    samples = []
    for when, offset in sorted(set(entries)):
        if periods and abs(offset - periods[-1][1]) <= 5:
            samples.append(offset)
            ordered = sorted(samples)
            periods[-1] = (periods[-1][0], ordered[len(ordered) // 2])
        else:
            samples = [offset]
            periods.append((when, offset))
    return periods


def choose_offset(tracks_by_day, wall, shift=0):
    """Resolve wall time against UTC correction periods and actual coverage, including adjacent local days.

    A repeated wall time after a backward clock change can have two valid UTC instants. Skip it instead of
    silently guessing. Before the first measurement, extrapolate that setting only onto recorded coverage.
    """
    tracks = list(tracks_by_day.values())
    measured = clock_periods([entry for track in tracks for entry in track.clock])
    entries = measured or sorted(set((when, minutes * 60) for track in tracks
                                    for when, minutes in track.utc_offsets))
    source = "measured camera clock" if measured else "phone time zone (camera clock assumed correct)"
    candidates = set()
    for i, (start, offset) in enumerate(entries):
        corrected = offset + shift
        try:
            utc = (wall - dt.timedelta(seconds=corrected)).replace(tzinfo=dt.timezone.utc)
        except (OverflowError, ValueError):
            continue
        if i and utc < start:
            continue
        if i + 1 < len(entries) and utc >= entries[i + 1][0]:
            continue
        if any(t.covers(utc) for t in tracks):
            candidates.add(corrected)
    if len(candidates) == 1:
        return candidates.pop(), source
    if len(candidates) > 1:
        return None, "ambiguous camera wall time after a clock or time-zone change"
    return None, "outside the recorded track or no clock correction available"


def write_photos(files, offset, gpx_files, no_backup=False):
    """Pass filenames directly, in bounded batches; newlines are data rather than ExifTool argfile syntax."""
    written = 0
    for start in range(0, len(files), 50):
        cmd = ["exiftool", "-api", f"GeoMaxIntSecs={MAX_GAP * 2}", "-api", f"GeoMaxExtSecs={MAX_GAP}",
               "-Geotime<${DateTimeOriginal}+00:00", f"-Geosync={-int(offset):+d}"]
        for path in gpx_files:
            cmd += ["-geotag", os.path.abspath(path)]
        if no_backup:
            cmd.append("-overwrite_original")
        cmd += ["--"] + [os.path.abspath(path) for path in files[start:start + 50]]
        result = subprocess.run(cmd, capture_output=True, text=True)
        match = re.search(r"(\d+) image files? updated", result.stdout)
        written += int(match.group(1)) if match else 0
        if result.returncode:
            print("  exiftool:", result.stderr.strip() or f"exit status {result.returncode}")
        else:
            for line in result.stderr.splitlines():
                print("  exiftool:", line.strip())
    return written


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder")
    ap.add_argument("--gpx-dir", default=ICLOUD_GPX)
    ap.add_argument("--shift", default="0", help="extra camera clock correction, e.g. 1h, -30s, 2m "
                                                 "(positive = camera was fast)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-backup", action="store_true", help="don't keep *_original copies")
    argv = sys.argv[1:]
    for i, arg in enumerate(argv[:-1]):
        if arg == "--shift":  # older argparse reads a value like -1h as an option unless it's attached
            argv[i:i + 2] = [f"--shift={argv[i + 1]}"]
            break
    args = ap.parse_args(argv)

    if not shutil.which("exiftool"):
        sys.exit("exiftool not found. Install it with: brew install exiftool")
    gpx_files = sorted(glob.glob(os.path.join(os.path.expanduser(args.gpx_dir), "**", "*.gpx"), recursive=True))
    if not gpx_files:
        sys.exit(f"No GPX files in {args.gpx_dir}. Use --gpx-dir to point at them.")
    tracks = {}
    for f in gpx_files:
        try:
            t = Track(f)
            tracks[t.day] = t
        except (ET.ParseError, ValueError, TypeError, OSError) as e:
            print(f"skipping {f}: {e}")
    gpx_files = [track.path for track in tracks.values()]
    if not gpx_files:
        sys.exit("No valid GPX tracks found.")
    photos = read_photos(args.folder)
    if not photos:
        sys.exit("No photos with DateTimeOriginal found.")

    unit = {"h": 3600, "m": 60, "s": 1}
    try:
        shift = int(float(args.shift[:-1]) * unit[args.shift[-1]]) if args.shift[-1] in unit else int(args.shift)
    except (ValueError, IndexError, OverflowError):
        ap.error("--shift must be seconds or a number followed by h, m, or s")

    groups = {}   # offset seconds -> [files]
    misses = []
    for path, wall in photos:
        off, source = choose_offset(tracks, wall, shift=shift)
        if off is None:
            misses.append((path, source))
            continue
        groups.setdefault(off, []).append(path)

    tagged = sum(len(v) for v in groups.values())
    print(f"{len(photos)} photos · {tagged} on the track · {len(misses)} not")
    for off, files in sorted(groups.items()):
        sign = "+" if off >= 0 else "-"
        a = abs(int(off))
        print(f"  camera clock = UTC {sign}{a // 3600:02d}:{a % 3600 // 60:02d}:{a % 60:02d}  → {len(files)} photos")

    if args.dry_run or not groups:
        for p, why in misses[:20]:
            print(f"  skip {os.path.basename(p)}: {why}")
        return

    written = sum(write_photos(files, off, gpx_files, args.no_backup) for off, files in groups.items())
    print(f"Done. GPS written to {written} of {tagged} photos."
          + ("" if args.no_backup or not written else " Originals kept as *_original."))
    if written < tagged:
        sys.exit(1)


if __name__ == "__main__":
    main()
