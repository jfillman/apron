"""Unit tests for the clearance-targets publisher script (templates/59-clearance-targets/publisher.yaml): retry on a
dropped connection or 502/503/504, no retry on a refusal. No cluster, no network."""

import http.client
import io
import json
import os
import pathlib
import re
import unittest
import urllib.error
from unittest import mock

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
RAW = (ROOT / "templates/59-clearance-targets/publisher.yaml").read_text()
# the targets JSON token sits alone on a line; give it an indented body, and blank the other tokens
TEXT = re.sub(r"@@\w+@@", "x", re.sub(r"^@@\w+@@$", "    {}", RAW, flags=re.M))
SCRIPT = next(d for d in yaml.safe_load_all(TEXT) if d and d["kind"] == "ConfigMap")["data"]["publish.py"]
OK = {"changed": False, "digest": "d", "seq": None}


def load():
    os.environ["CLEARANCE_URL"] = "http://core.invalid"
    os.environ["TARGETS_SOURCE"] = "src"
    ns = {"__name__": "publish"}
    exec(compile(SCRIPT, "publish.py", "exec"), ns)
    return ns


def http_error(code):
    return urllib.error.HTTPError("http://core.invalid", code, "x", {}, io.BytesIO(b'{"error":"x"}'))


def files(path, *a, **k):
    data = json.dumps({"targets": [{"id": "t"}]}) if "targets.json" in str(path) else "tok\n"
    return io.StringIO(data)


class Publish(unittest.TestCase):
    def run_main(self, outcomes):
        """Run main() with put() yielding each outcome in turn (an exception is raised, a dict returned)."""
        m = load()
        calls = []

        def put(body, token):
            o = outcomes[len(calls)]
            calls.append(token)
            if isinstance(o, BaseException):
                raise o
            return o

        m["put"] = put
        sleeps = []
        with mock.patch("builtins.open", files), mock.patch.object(m["time"], "sleep", sleeps.append):
            rc = m["main"]()
        return rc, calls, sleeps

    def test_success_first_try(self):
        rc, calls, sleeps = self.run_main([OK])
        self.assertEqual((rc, len(calls), sleeps), (0, 1, []))

    def test_retries_remote_disconnected_then_succeeds(self):
        rc, calls, sleeps = self.run_main([http.client.RemoteDisconnected("Remote end closed connection without response"), OK])
        self.assertEqual((rc, len(calls), sleeps), (0, 2, [2]))

    def test_retries_urlerror_reset_and_timeout(self):
        rc, calls, sleeps = self.run_main([urllib.error.URLError(ConnectionResetError(104, "reset")), TimeoutError("t"), OK])
        self.assertEqual((rc, len(calls), sleeps), (0, 3, [2, 5]))

    def test_retries_503_then_succeeds(self):
        rc, calls, _ = self.run_main([http_error(503), http_error(502), http_error(504), OK])
        self.assertEqual((rc, len(calls)), (0, 4))

    def test_gives_up_after_four_attempts(self):
        rc, calls, sleeps = self.run_main([http.client.RemoteDisconnected("x")] * 4)
        self.assertEqual((rc, len(calls), sleeps), (1, 4, [2, 5, 10]))

    def test_refusal_is_not_retried(self):
        for code in (400, 401, 403, 409):
            rc, calls, sleeps = self.run_main([http_error(code), OK])
            self.assertEqual((rc, len(calls), sleeps), (1, 1, []), code)

    def test_retries_incomplete_read_then_succeeds(self):
        rc, calls, sleeps = self.run_main([http.client.IncompleteRead(b"ab", 98), OK])
        self.assertEqual((rc, len(calls), sleeps), (0, 2, [2]))

    def test_unreadable_error_body_does_not_end_the_retry_flow(self):
        class Broken(io.BytesIO):
            def read(self, *a):
                raise http.client.IncompleteRead(b"", 10)

        def broken(code):
            return urllib.error.HTTPError("http://core.invalid", code, "x", {}, Broken())

        rc, calls, sleeps = self.run_main([broken(503), OK])
        self.assertEqual((rc, len(calls), sleeps), (0, 2, [2]))
        rc, calls, sleeps = self.run_main([broken(403), OK])  # a refusal stays final
        self.assertEqual((rc, len(calls), sleeps), (1, 1, []))

    def test_put_sends_fresh_request_with_connection_close(self):
        m = load()
        seen = []

        def urlopen(req, timeout):
            seen.append(req)
            return io.StringIO(json.dumps(OK))

        with mock.patch.object(m["urllib"].request, "urlopen", urlopen):
            self.assertEqual(m["put"]("{}", "tok"), OK)
            m["put"]("{}", "tok")
        self.assertEqual(len({id(r) for r in seen}), 2)
        self.assertEqual(seen[0].get_header("Connection"), "close")
        self.assertEqual(seen[0].get_method(), "PUT")


if __name__ == "__main__":
    unittest.main()
