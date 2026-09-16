#!/usr/bin/env python3
"""Exercise resumable publication against a deliberately unreliable HTTP server."""
import hashlib
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("prepare_model", Path(__file__).with_name("prepare-model.py"))
model = importlib.util.module_from_spec(spec)
spec.loader.exec_module(model)
PAYLOAD = bytes(range(256)) * 4


class Downloads(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.models = Path(self.directory.name)
        self.mode = "normal"
        self.requests = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                offset = int(self.headers.get("Range", "bytes=0-")[6:-1])
                fixture.requests.append(offset)
                if offset and fixture.mode == "reject":
                    self.send_error(416)
                    return
                if fixture.mode == "ignore":
                    offset = 0
                self.send_response(206 if offset else 200)
                if offset:
                    self.send_header("Content-Range", f"bytes {offset}-{len(PAYLOAD)-1}/{len(PAYLOAD)}")
                self.send_header("Content-Length", str(len(PAYLOAD) - offset))
                self.end_headers()
                body = PAYLOAD[offset:]
                if fixture.mode == "corrupt":
                    body = b"x" * len(body)
                elif fixture.mode == "interrupt":
                    body = body[:100]
                self.wfile.write(body)
                self.close_connection = True

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}/model.bin"
        self.enterContext(patch("huggingface_hub.hf_hub_url", return_value=url))
        self.enterContext(patch.dict(model.PINS, {"fixture": ("fixture/repo", "pinned")}))
        self.enterContext(patch.dict(model.ASSETS, {"fixture": {"model.bin": (len(PAYLOAD), hashlib.sha256(PAYLOAD).hexdigest())}}))
        self.destination = self.models / "sources/fixture/pinned/model.bin"
        self.destination.parent.mkdir(parents=True)
        self.part = self.destination.with_name("model.bin.part")

    def fetch(self):
        destination, _ = model.fetch(self.models, "fixture", "model.bin")
        self.assertEqual(destination.read_bytes(), PAYLOAD)
        self.assertFalse(self.part.exists())

    def test_valid_resume_and_ignored_range(self):
        for mode in ("normal", "ignore"):
            with self.subTest(mode=mode):
                self.mode = mode
                self.destination.unlink(missing_ok=True)
                self.part.write_bytes(PAYLOAD[:111])
                self.fetch()

    def test_rejected_range_restarts_cleanly(self):
        self.mode = "reject"
        self.part.write_bytes(PAYLOAD[:111])
        self.fetch()
        self.assertEqual(self.requests, [111, 0])

    def test_corrupt_and_oversized_progress_recovers(self):
        for partial in (b"x" * 111, b"x" * len(PAYLOAD), PAYLOAD + b"extra"):
            with self.subTest(size=len(partial)):
                self.destination.unlink(missing_ok=True)
                self.part.write_bytes(partial)
                self.fetch()

    def test_persistent_corruption_never_publishes(self):
        self.mode = "corrupt"
        with self.assertRaises(ValueError):
            self.fetch()
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.part.exists())

    def test_interruption_preserves_resumable_progress(self):
        self.mode = "interrupt"
        with self.assertRaises(OSError):
            self.fetch()
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.part.read_bytes(), PAYLOAD[:100])
        self.mode = "normal"
        self.fetch()
        self.assertEqual(self.requests, [0, 100])


if __name__ == "__main__":
    unittest.main()
