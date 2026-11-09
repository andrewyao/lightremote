#!/usr/bin/env python3
"""Fake Sony A7II (Smart Remote Control) for developing LightRemote without the camera.

    swift MockCamera/make_frames.swift      # once, writes MockCamera/frames/*.jpg
    python3 MockCamera/mock_camera.py       # serves http://localhost:8080/sony/...

Every API call is printed as `[call] method params` so tests and humans can check what the app sent.
"""
import argparse
import datetime as dt
import glob
import json
import os
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

CAMERA_APIS = [
    "getAvailableApiList", "getApplicationInfo", "getEvent", "startRecMode", "stopRecMode",
    "startLiveview", "stopLiveview", "actTakePicture", "awaitTakePicture",
    "setShootMode", "getShootMode", "getAvailableShootMode",
    "setSelfTimer", "getSelfTimer", "getAvailableSelfTimer",
    "setExposureCompensation", "getExposureCompensation", "getAvailableExposureCompensation",
    "setFNumber", "getFNumber", "getAvailableFNumber",
    "setShutterSpeed", "getShutterSpeed", "getAvailableShutterSpeed",
    "setIsoSpeedRate", "getIsoSpeedRate", "getAvailableIsoSpeedRate",
    "setTouchAFPosition", "cancelTouchAFPosition", "actHalfPressShutter", "cancelHalfPressShutter",
    "startMovieRec", "stopMovieRec",
]
OPTIONAL_CAMERA_APIS = {"bulb": ["startBulbShooting", "stopBulbShooting"],
                        "focus": ["setFocusMode", "getFocusMode", "getAvailableFocusMode"]}

F_NUMBERS = ["2.8", "3.2", "3.5", "4.0", "4.5", "5.0", "5.6", "6.3", "7.1", "8.0", "9.0", "10", "11", "13", "16", "22"]
SHUTTER = ['BULB', '30"', '15"', '8"', '4"', '2"', '1"', '0.5"', "1/4", "1/8", "1/15", "1/30", "1/60",
           "1/125", "1/250", "1/500", "1/1000", "1/2000", "1/4000", "1/8000"]
ISO = ["AUTO", "100", "200", "400", "800", "1600", "3200", "6400", "12800", "25600"]


class Camera:
    def __init__(self, args):
        self.args = args
        self.cond = threading.Condition()
        self.version = 0
        self.status = "IDLE"
        self.shoot_mode = "still"
        self.f = "5.6"
        self.tv = "1/250"
        self.iso = "400"
        self.ev = 0
        self.focus = "AF-S"
        self.self_timer = 0
        self.pending_urls = []
        self.shot_counter = 0
        self.clock_offset = args.clock_offset   # seconds the camera clock is ahead of true local time
        self.tz_minutes = None                  # set by setCurrentTime; None = host local zone
        self.awaiting = None
        self.awaited_url = None
        frames = sorted(glob.glob(os.path.join(HERE, "frames", "*.jpg")))
        if not frames:
            raise SystemExit("No frames. Run: swift MockCamera/make_frames.swift")
        self.frames = [open(p, "rb").read() for p in frames]
        self.postviews = {}

    # ---- state helpers ----
    def changed(self):
        with self.cond:
            self.version += 1
            self.cond.notify_all()

    def apis(self):
        names = list(CAMERA_APIS)
        if not self.args.no_bulb:
            names += OPTIONAL_CAMERA_APIS["bulb"]
        if not self.args.no_focus_mode:
            names += OPTIONAL_CAMERA_APIS["focus"]
        return names

    def system_apis(self):
        names = ["getAvailableApiList", "getVersions"]
        if self.args.with_set_time:
            names.append("setCurrentTime")
        return names

    def camera_now(self):
        utc = dt.datetime.now(dt.timezone.utc)
        if self.tz_minutes is not None:
            local = utc + dt.timedelta(minutes=self.tz_minutes)
        else:
            local = utc.astimezone()
        return (local + dt.timedelta(seconds=self.clock_offset)).replace(tzinfo=None)

    def event(self):
        ev = [None] * 40
        ev[0] = {"type": "availableApiList", "names": self.apis()}
        ev[1] = {"type": "cameraStatus", "cameraStatus": self.status}
        if self.pending_urls:
            ev[5] = [{"type": "takePicture", "takePictureUrl": self.pending_urls}]
            self.pending_urls = []
        ev[10] = [{"type": "storageInformation", "numberOfRecordableImages": 900 - self.shot_counter,
                   "recordTarget": True}]
        ev[11] = [{"type": "batteryInfo", "levelNumer": 72, "levelDenom": 100}]
        ev[18] = {"type": "exposureMode", "currentExposureMode": "Manual",
                  "exposureModeCandidates": ["Manual"]}
        ev[21] = {"type": "shootMode", "currentShootMode": self.shoot_mode, "shootModeCandidates": ["still", "movie"]}
        ev[25] = {"type": "exposureCompensation", "currentExposureCompensation": self.ev,
                  "maxExposureCompensation": 15, "minExposureCompensation": -15, "stepIndexOfExposureCompensation": 1}
        ev[26] = {"type": "selfTimer", "currentSelfTimer": self.self_timer, "selfTimerCandidates": [0, 2, 10]}
        ev[27] = {"type": "fNumber", "currentFNumber": self.f, "fNumberCandidates": F_NUMBERS}
        if not self.args.no_focus_mode:
            ev[28] = {"type": "focusMode", "currentFocusMode": self.focus, "focusModeCandidates": ["AF-S", "AF-C", "MF"]}
        ev[29] = {"type": "isoSpeedRate", "currentIsoSpeedRate": self.iso, "isoSpeedRateCandidates": ISO}
        ev[32] = {"type": "shutterSpeed", "currentShutterSpeed": self.tv, "shutterSpeedCandidates": SHUTTER}
        return ev

    def make_postview(self):
        self.shot_counter += 1
        name = f"pict{self.shot_counter:04d}.JPG"
        self.postviews[name] = with_exif(self.frames[self.shot_counter % len(self.frames)], self.camera_now())
        return f"http://{self.args.public_host}:{self.args.port}/postview/{name}"

    def shoot(self):
        if self.self_timer:
            time.sleep(self.self_timer)
        self.status = "StillCapturing"
        self.changed()
        time.sleep(0.2)
        url = self.make_postview()
        self.status = "IDLE"
        self.pending_urls.append(url)
        self.changed()
        return url

    # ---- API ----
    def handle(self, service, method, params):
        print(f"[call] {service}.{method} {json.dumps(params)}", flush=True)
        if service == "system":
            if method == "getAvailableApiList":
                return [self.system_apis()]
            if method == "setCurrentTime" and self.args.with_set_time:
                p = params[0]
                self.tz_minutes = p["timeZoneOffsetMinute"] + p["dstOffsetMinute"]
                self.clock_offset = 0
                return [0]
            raise ApiError(12, "No such method")
        if method not in self.apis():
            raise ApiError(12, "No such method")
        if method == "getAvailableApiList":
            return [self.apis()]
        if method == "getEvent":
            if params and params[0]:
                with self.cond:
                    start = self.version
                    self.cond.wait_for(lambda: self.version != start, timeout=self.args.poll_timeout)
            return self.event()
        if method in ("startRecMode", "stopRecMode", "cancelTouchAFPosition", "cancelHalfPressShutter", "stopLiveview"):
            return [0]
        if method == "startLiveview":
            return [f"http://{self.args.public_host}:{self.args.port}/liveview/liveviewstream"]
        if method == "actTakePicture":
            if self.shoot_mode != "still" or self.status != "IDLE":
                raise ApiError(7, "Illegal State")
            if self.tv == "BULB":
                raise ApiError(7, "Use startBulbShooting")
            if '"' in self.tv:
                def long_shot():
                    self.awaited_url = self.shoot()
                self.awaiting = threading.Thread(target=long_shot)
                self.awaiting.start()
                raise ApiError(40403, "Long shooting")
            return [[self.shoot()]]
        if method == "awaitTakePicture":
            if not self.awaiting:
                raise ApiError(7, "Not shooting")
            self.awaiting.join()
            self.awaiting = None
            return [[self.awaited_url]]
        setters = {"setFNumber": ("f", F_NUMBERS), "setShutterSpeed": ("tv", SHUTTER), "setIsoSpeedRate": ("iso", ISO),
                   "setFocusMode": ("focus", ["AF-S", "AF-C", "MF"]), "setShootMode": ("shoot_mode", ["still", "movie"]),
                   "setSelfTimer": ("self_timer", [0, 2, 10])}
        if method in setters:
            attr, allowed = setters[method]
            if params[0] not in allowed:
                raise ApiError(3, "Illegal Argument")
            setattr(self, attr, params[0])
            self.changed()
            return [0]
        if method == "setExposureCompensation":
            if not -15 <= params[0] <= 15:
                raise ApiError(3, "Illegal Argument")
            self.ev = params[0]
            self.changed()
            return [0]
        if method == "setTouchAFPosition":
            return [0, {"AFResult": True, "AFType": "Touch"}]
        if method == "actHalfPressShutter":
            return [0]
        if method == "startMovieRec":
            if self.shoot_mode != "movie":
                raise ApiError(7, "Illegal State")
            self.status = "MovieRecording"
            self.changed()
            return [0]
        if method == "stopMovieRec":
            self.status = "IDLE"
            self.changed()
            return [""]
        if method == "startBulbShooting":
            if self.tv != "BULB":
                raise ApiError(7, "Illegal State")
            self.status = "StillCapturing"
            self.changed()
            return [0]
        if method == "stopBulbShooting":
            self.status = "IDLE"
            self.pending_urls.append(self.make_postview())
            self.changed()
            return [0]
        return [0]


class ApiError(Exception):
    def __init__(self, code, msg):
        self.code, self.msg = code, msg


def with_exif(jpeg, when):
    """Insert a minimal APP1 EXIF segment carrying DateTimeOriginal (big-endian TIFF)."""
    stamp = when.strftime("%Y:%m:%d %H:%M:%S").encode() + b"\0"
    tiff = b"MM\x00\x2a" + struct.pack(">I", 8)
    tiff += struct.pack(">H", 1) + struct.pack(">HHII", 0x8769, 4, 1, 26) + struct.pack(">I", 0)
    tiff += struct.pack(">H", 1) + struct.pack(">HHII", 0x9003, 2, len(stamp), 44) + struct.pack(">I", 0)
    tiff += stamp
    payload = b"Exif\x00\x00" + tiff
    return jpeg[:2] + b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload + jpeg[2:]


def liveview_packet(seq, jpeg):
    common = struct.pack(">BBHI", 0xFF, 0x01, seq & 0xFFFF, int(time.time() * 1000) & 0xFFFFFFFF)
    size = len(jpeg)
    payload = bytes([0x24, 0x35, 0x68, 0x79]) + size.to_bytes(3, "big") + bytes([0]) + bytes(4) + bytes([0]) + bytes(115)
    return common + payload + jpeg


def make_handler(cam):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def do_POST(self):
            service = self.path.rstrip("/").split("/")[-1]
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            try:
                out = {"result": cam.handle(service, body["method"], body.get("params", [])), "id": body["id"]}
            except ApiError as e:
                out = {"error": [e.code, e.msg], "id": body["id"]}
            data = json.dumps(out).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path.startswith("/liveview"):
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                seq = 0
                try:
                    while True:
                        self.wfile.write(liveview_packet(seq, cam.frames[seq % len(cam.frames)]))
                        self.wfile.flush()
                        seq += 1
                        time.sleep(0.1)
                except (BrokenPipeError, ConnectionResetError):
                    return
            name = self.path.rsplit("/", 1)[-1]
            if self.path.startswith("/postview/") and name in cam.postviews:
                data = cam.postviews[name]
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_error(404)

    return Handler


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--public-host", default="localhost", help="host written into live view / postview URLs")
    p.add_argument("--clock-offset", type=int, default=3, help="seconds the camera clock runs ahead")
    p.add_argument("--with-set-time", action="store_true", help="expose system.setCurrentTime")
    p.add_argument("--no-bulb", action="store_true")
    p.add_argument("--no-focus-mode", action="store_true")
    p.add_argument("--poll-timeout", type=float, default=8.0)
    args = p.parse_args()
    cam = Camera(args)
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(cam))
    print(f"Mock A7II on http://localhost:{args.port}/sony", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
