#!/usr/bin/env python3
"""Download the voice model for real from a local server, on macOS: the production SGSingModel.m and
SGCatalog.m against a catalog the server answers with, a corrupted file rejected, a cancel keeping the
files already in, an install, a download picked up by the next process, and removal. The model's files
are served from a folder that holds them at their paths (stage_model.py's output, or separator.mlmodelc
itself); nothing is uploaded or fetched from the internet. The server lays the catalog out the way the
real one is: sing/catalog.json, then sing/model-1/... for the full model and sing/model-101/... for a
small synthetic light one.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("model", type=Path, help="a folder with the full model's files at their paths")
args = model = args if (args := parser.parse_args()).model else None
root = args.model.resolve()
here = Path(__file__).resolve().parent
src = here.parent.parent / "tweak/Sources"
WEIGHTS, GRAPH = "weights/weight.bin", "model.mil"
FULL, LIGHT = "sing/model-1", "sing/model-101"

serve_root = Path(tempfile.mkdtemp(prefix="spoti-sing-serve-"))
# The full model at its catalog path, the light one a few small files so a choice of it downloads fast.
full_dir = serve_root / FULL
full_dir.mkdir(parents=True)
for path in root.rglob("*"):
    if path.is_file():
        target = full_dir / path.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
light_dir = serve_root / LIGHT
light_dir.mkdir(parents=True)
for name, size in [(WEIGHTS, 2 << 20), (GRAPH, 64 << 10), ("metadata.json", 2048),
                   ("coremldata.bin", 462), ("analytics/coremldata.bin", 243)]:
    target = light_dir / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(bytes(size))


def entry(folder, version):
    files = [{"path": str(path.relative_to(folder)), "size": path.stat().st_size,
              "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
             for path in sorted(folder.rglob("*")) if path.is_file()]
    return {"version": version, "files": files}


catalog = json.dumps([entry(full_dir, 1), entry(light_dir, 101)]).encode()


class Server:
    corrupt = False   # the graph is served with its last byte changed
    throttle = 0      # bytes per second for the weights, 0 for as fast as it goes
    offsets = {}      # where the last request for each file started
    requests = {}     # requests per file


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *arguments):
        pass

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass   # a connection the client let go of

    def answer(self, status, body, kind="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/control":
            query = parse_qs(url.query)
            if "corrupt" in query:
                Server.corrupt = query["corrupt"][0] == "1"
            if "throttle" in query:
                Server.throttle = int(query["throttle"][0])
            if "reset" in query:
                Server.offsets, Server.requests = {}, {}
            self.answer(200, json.dumps({"offsets": Server.offsets, "requests": Server.requests}).encode())
            return
        name = url.path.lstrip("/")
        if name == "sing/catalog.json":
            self.answer(200, catalog)
            return
        path = (serve_root / name).resolve()
        if serve_root not in path.parents or not path.is_file():
            self.answer(404, b"not found", "text/plain")
            return
        size = path.stat().st_size
        corrupt = Server.corrupt and name == f"{FULL}/{GRAPH}"
        start, end = 0, size - 1
        wanted = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if wanted:
            start = int(wanted[1])
            end = int(wanted[2]) if wanted[2] else size - 1
        if name == f"{FULL}/{WEIGHTS}":
            Server.offsets[name] = start
            Server.requests[name] = Server.requests.get(name, 0) + 1
        self.send_response(206 if wanted else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        try:
            with path.open("rb") as file:
                file.seek(start)
                at, chunk = start, 256 << 10
                while at <= end:
                    data = bytearray(file.read(min(chunk, end - at + 1)))
                    if corrupt and at + len(data) == size:
                        data[-1] ^= 0xFF
                    self.wfile.write(data)
                    at += len(data)
                    if name == f"{FULL}/{WEIGHTS}" and Server.throttle:
                        time.sleep(len(data) / Server.throttle)
        except (BrokenPipeError, ConnectionResetError):
            pass   # the client cancelled


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
with tempfile.TemporaryDirectory(prefix="spoti-sing-model-") as directory:
    binary = Path(directory) / "model-test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-g", "-O1", "-Wall", "-Werror", "-fsanitize=address,undefined",
                    "-I", str(src), f'-DSGCatalogBase=@"http://127.0.0.1:{port}/"',
                    f'-DSGSingModelRoot=@"{directory}/root"',
                    str(here / "model_test.m"), str(src / "Shared/Sing/SGSingModel.m"),
                    str(src / "Shared/Catalog/SGCatalog.m"),
                    str(src / "Core/SGPrefs.m"), str(src / "Core/SGLog.m"),
                    "-framework", "Foundation", "-framework", "Network", "-o", str(binary)], check=True)
    for mode in ["all", "leave", "reconnect"]:
        subprocess.run([str(binary), mode], check=True)
server.shutdown()
shutil.rmtree(serve_root, ignore_errors=True)
