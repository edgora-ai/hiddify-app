"""Synthetic protocol tests; never connect to a browser, device, or server."""

import copy
import hashlib
import json
import unittest

import desktop_cdp as cdp
import records

ENDPOINT = "ws://127.0.0.1:12345/devtools/browser/synthetic-fixture"
SCOPE = "run-synthetic"
SOURCES = {
    "https://cdn.ping0.cc/js/envdetect/main.js": "synthetic main source",
    "https://cdn.ping0.cc/js/envdetect/probes/index.js": "synthetic probes source",
    "https://cdn.ping0.cc/js/envdetect/browser-detect.client.js": "synthetic engine source",
}
CONTRACT = {
    "schema_version": 1,
    "contract_id": "synthetic-transport-contract",
    "source_pins": {url: {"sha256": hashlib.sha256(text.encode()).hexdigest(), "required": True} for url, text in SOURCES.items()},
    "network_targets": {"multigeo": ["https://api.ipify.org/?format=json", "https://cstaticdun.126.net"], "engine_endpoints": ["https://ping0.cc/envdetect/probe/engine"]},
}
DOMAINS = ["r-1792300000000-" + str(i) + ".d.ping0.cc" for i in range(50)]


class Clock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        return self.value


class FakeSocket:
    def __init__(self, clock, *, no_submit=False, lost_context_reply=False, unsafe_navigation=False, retained_context=False):
        self.clock = clock
        self.queue = []
        self.methods = []
        self.bodies = {}
        self.closed = False
        self.no_submit = no_submit
        self.lost_context_reply = lost_context_reply
        self.unsafe_navigation = unsafe_navigation
        self.retained_context = retained_context

    def event(self, method, params):
        self.queue.append(json.dumps({"sessionId": "session-1", "method": method, "params": params}))

    def transaction(self, request_id, url, body, post=None):
        request = {"url": url, "method": "POST" if post is not None else "GET", "headers": {"Cookie": "DO_NOT_RETAIN_TEST_SECRET"}}
        if post is not None:
            request["postData"] = json.dumps(post)
        self.event("Network.requestWillBeSent", {"requestId": request_id, "frameId": "frame-1", "request": request})
        self.event("Network.responseReceived", {"requestId": request_id, "response": {"url": url, "status": 200, "headers": {"Set-Cookie": "DO_NOT_RETAIN_TEST_SECRET"}}})
        self.bodies[request_id] = body
        self.event("Network.loadingFinished", {"requestId": request_id})

    def send(self, raw):
        message = json.loads(raw)
        method, params = message["method"], message["params"]
        self.methods.append(method)
        if method == "Target.createBrowserContext" and self.lost_context_reply:
            return
        result = {}
        if method == "Browser.getVersion":
            result = {"product": "Chrome/155.0.0.0"}
        elif method == "Target.createBrowserContext":
            result = {"browserContextId": "context-1"}
        elif method == "Target.createTarget":
            result = {"targetId": "target-1"}
        elif method == "Target.attachToTarget":
            result = {"sessionId": "session-1"}
        elif method == "Page.navigate":
            result = {"frameId": "frame-1", "loaderId": "loader-1"}
        elif method == "Network.getResponseBody":
            result = {"body": self.bodies[params["requestId"]], "base64Encoded": False}
        elif method == "Runtime.evaluate":
            result = {"result": {"type": "string", "value": "visible"}}
        elif method == "DOM.getDocument":
            result = {"root": {"nodeId": 1}}
        elif method == "DOM.querySelector":
            result = {"nodeId": 2 if "status-text" in params["selector"] else 3}
        elif method == "DOM.getOuterHTML":
            result = {"outerHTML": '<span class="ed-status-icon done"></span><span class="ed-status-detail">分数 67</span>' if params["nodeId"] == 2 else '<div class="ed-ticker-line ok"><span class="ed-ticker-tag">[DNS]</span></div>'}
        elif method == "Target.getTargetInfo":
            result = {"targetInfo": {"browserContextId": "context-1", "url": "https://private.invalid/" if self.unsafe_navigation else cdp.PAGE_URL}}
        elif method == "Target.closeTarget":
            result = {"success": True}
        elif method == "Target.getBrowserContexts":
            result = {"browserContextIds": ["context-1"] if self.retained_context else []}
        self.queue.append(json.dumps({"id": message["id"], "result": result}))
        if method == "Page.navigate":
            self.event("Page.frameNavigated", {"frame": {"id": "frame-1", "url": "https://private.invalid/" if self.unsafe_navigation else cdp.PAGE_URL}})
            if self.unsafe_navigation:
                return
            for i, (url, text) in enumerate(SOURCES.items()):
                self.transaction("source." + str(i), url, text)
            self.transaction("dns.1", "https://ping0.cc/envdetect/probe/dnsleak", json.dumps({"resolver_count": 0, "items": []}), {"domains": DOMAINS, "stamp": 1792300000000})
            if not self.no_submit:
                submission = {"dns": {"resolver_count": 0, "resolvers": []}, "locale": {"intl_timezone": "America/Los_Angeles"}, "token": "DO_NOT_RETAIN_TEST_SECRET"}
                self.transaction("submit.1", "https://ping0.cc/envdetect/submit", json.dumps({"score": 67, "level": "yellow", "findings": [{"id": "xc.dns_blackhole", "fail": True, "severity": "warn", "value": "resolver_count=0"}], "evidence": submission}), submission)

    def recv(self, timeout):
        if self.queue:
            return self.queue.pop(0)
        self.clock.value += timeout
        raise TimeoutError

    def close(self):
        self.closed = True


class EndpointTests(unittest.TestCase):
    def test_accepts_only_existing_literal_loopback_ws_shape(self):
        self.assertEqual(cdp.validate_endpoint(ENDPOINT), ENDPOINT)
        self.assertEqual(cdp.validate_endpoint("ws://[::1]:12345/devtools/browser/fixture"), "ws://[::1]:12345/devtools/browser/fixture")

    def test_rejects_remote_credentials_queries_and_http(self):
        for endpoint in ["ws://example.com:12345/devtools/browser/x", "http://127.0.0.1:12345/", "ws://localhost:12345/devtools/browser/x", "ws://u:p@127.0.0.1:12345/devtools/browser/x", ENDPOINT + "?token=secret", ENDPOINT + "#fragment", "ws://127.0.0.1/devtools/browser/x"]:
            with self.subTest(endpoint=endpoint), self.assertRaises(cdp.CaptureError):
                cdp.validate_endpoint(endpoint)

    def test_protocol_rejects_duplicate_keys_nonfinite_and_binary(self):
        for value in ['{"id":1,"id":2}', '{"value":NaN}', b'{}', '[]']:
            with self.subTest(value=value), self.assertRaises(cdp.CaptureError):
                cdp._protocol_json(value)

    def test_manual_consent_wait_stays_inside_the_whole_deadline(self):
        for remaining, expected in ((90, 30), (12, 12)):
            with self.subTest(remaining=remaining):
                clock = Clock()
                options = {}
                socket = FakeSocket(clock)

                def connector(*args, **kwargs):
                    options.update(kwargs)
                    return socket

                client = cdp.CDPClient(ENDPOINT, remaining, clock=clock, connector=connector)
                client.connect()
                self.assertEqual(options["open_timeout"], expected)
                self.assertTrue(client.close())

    def test_transport_close_uses_only_the_remaining_cleanup_budget(self):
        clock = Clock()

        class SlowClosingSocket(FakeSocket):
            def close(self):
                clock.value += self.close_timeout
                super().close()

        socket = SlowClosingSocket(clock)
        client = cdp.CDPClient(ENDPOINT, 90, clock=clock, connector=lambda *args, **kwargs: socket)
        client.connect()
        clock.value = 4.75
        self.assertTrue(client.close(timeout=0.25))
        self.assertEqual(socket.close_timeout, 0.25)
        self.assertEqual(clock.value, 5)

    def test_close_return_without_closed_state_is_not_cleanup_proof(self):
        clock = Clock()

        class UnclosedSocket(FakeSocket):
            def close(self):
                pass

        socket = UnclosedSocket(clock)
        client = cdp.CDPClient(ENDPOINT, 90, clock=clock, connector=lambda *args, **kwargs: socket)
        client.connect()
        self.assertFalse(client.close())

    def test_url_projection_drops_secret_values_but_keeps_unknown_query_presence(self):
        projected = cdp._url_identity("https://ping0.cc/envdetect/probe/dnsleak?token=DO_NOT_RETAIN_TEST_SECRET&unknown_key=hidden")
        self.assertNotIn("DO_NOT_RETAIN_TEST_SECRET", json.dumps(projected))
        self.assertIn("token", projected["query_names"])
        self.assertIn("other_parameter", projected["query_names"])


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.state = cdp.PageCollector(copy.deepcopy(CONTRACT), SCOPE, 90, clock=self.clock)
        self.state.session_id = "session-1"

    def emit(self, method, params, session="session-1"):
        self.state.event({"sessionId": session, "method": method, "params": params})

    def request(self, ident="dns.1", url="https://ping0.cc/envdetect/probe/dnsleak"):
        self.emit("Network.requestWillBeSent", {"requestId": ident, "request": {"url": url, "method": "POST", "postData": json.dumps({"domains": DOMAINS, "stamp": 1792300000000})}})
        return self.state.transactions[-1]

    def test_unrelated_session_never_enters_facts(self):
        self.emit("Network.requestWillBeSent", {"requestId": "other", "request": {"url": "https://ping0.cc/envdetect/probe/dnsleak", "method": "POST"}}, session="other-session")
        self.assertEqual(self.state.transactions, [])

    def test_dns_route_is_exact_not_an_arbitrary_200_kind(self):
        self.assertIsNone(self.state.kind_for_url("https://unrelated.ping0.cc/envdetect/probe/dnsleak"))
        self.assertIsNone(self.state.kind_for_url("http://ping0.cc/envdetect/probe/dnsleak"))
        self.assertEqual(self.state.kind_for_url("https://ping0.cc/envdetect/probe/dnsleak"), "dnsleak")

    def test_redirect_outside_allowlist_does_not_reuse_old_api_identity(self):
        previous = self.request()
        self.emit("Network.requestWillBeSent", {"requestId": "dns.1", "redirectResponse": {"status": 302}, "request": {"url": "https://unrelated.invalid/count", "method": "GET"}})
        self.emit("Network.responseReceived", {"requestId": "dns.1", "response": {"status": 200}})
        self.emit("Network.loadingFinished", {"requestId": "dns.1"})
        self.assertEqual(previous["terminal"], "redirected")
        self.assertIsNone(previous["response_status"])
        self.assertEqual(len(self.state.body_queue), 0)

    def test_placeholder_success_without_body_is_unavailable(self):
        tx = self.request()
        self.state.response_body(tx, {"resource": {"success": True}})
        self.assertEqual(tx["body_state"], "unavailable")
        self.assertIsNone(tx["response_fields"])

    def test_failed_then_finished_does_not_wash_failure(self):
        tx = self.request()
        self.emit("Network.loadingFailed", {"requestId": "dns.1", "errorText": "net::ERR_NAME_NOT_RESOLVED"})
        self.emit("Network.loadingFinished", {"requestId": "dns.1"})
        self.assertEqual(tx["terminal"], "failed")
        self.assertEqual(len(self.state.body_queue), 0)

    def test_orphan_critical_response_marks_capture_incomplete(self):
        self.emit("Network.responseReceived", {"requestId": "missing", "response": {"url": "https://ping0.cc/envdetect/probe/dnsleak", "status": 200}})
        self.assertEqual(self.state.observation["orphan_api_response_count"], 1)
        self.assertTrue(self.state.observation["truncated"])
        self.assertEqual(self.state.transactions, [])

    def test_critical_response_route_mismatch_cannot_supply_a_body(self):
        tx = self.request()
        self.emit("Network.responseReceived", {"requestId": "dns.1", "response": {"url": "https://ping0.cc/envdetect/submit", "status": 200}})
        self.emit("Network.loadingFinished", {"requestId": "dns.1"})
        self.assertEqual(tx["error_kind"], "response_route_mismatch")
        self.assertEqual(tx["body_state"], "unavailable")
        self.assertTrue(self.state.observation["truncated"])
        self.assertEqual(len(self.state.body_queue), 0)

    def test_dns_schema_is_the_same_in_capture_and_replay(self):
        for value in [{"resolver_count": 0}, {"resolver_count": 0, "items": []}, {"resolver_count": False, "items": []}, {"resolver_count": 1, "items": [{"ip": "192.168.1.1"}]}, {"resolver_count": 1, "items": [{"ip": "8.8.8.8"}]}]:
            with self.subTest(value=value):
                tx = self.request(ident="dns." + str(len(self.state.transactions)))
                self.state.response_body(tx, {"body": json.dumps(value), "base64Encoded": False})
                self.assertEqual(tx["schema_state"], records.dns_schema_state(value))
        tx = self.request(ident="dns.error")
        self.state.response_body(tx, {"body": json.dumps({"resolver_count": 0, "items": [], "error": "denied"}), "base64Encoded": False})
        self.assertEqual(tx["schema_state"], "invalid")

    def test_full_fifty_domain_batch_survives_capture_and_replay_projection(self):
        tx = self.request()
        projected = tx["request_fields"]
        self.assertEqual(len(projected["domains"]), 50)
        self.assertEqual(projected["domains"], DOMAINS)
        self.assertNotIn("_projection_truncated", projected)
        self.assertEqual(records.project_dns_request(projected), projected)

    def test_source_conflict_cannot_be_hidden_by_last_matching_digest(self):
        for url, text in SOURCES.items():
            self.state.script_digests.append({"url": url, "sha256": hashlib.sha256(text.encode()).hexdigest(), "bytes": len(text)})
        self.assertEqual(self.state.source_match(), "matched")
        self.state.script_digests.insert(0, {"url": next(iter(SOURCES)), "sha256": "0" * 64, "bytes": 1})
        self.assertEqual(self.state.source_match(), "unreviewed")

    def test_long_engine_session_material_is_not_persisted(self):
        tx = self.request(ident="engine.1", url="https://ping0.cc/envdetect/probe/engine?init=1")
        self.state.response_body(tx, {"body": json.dumps({"sid": "DO_NOT_RETAIN_TEST_SECRET", "k": "x", "n": "y", "p": "z" * 70000}), "base64Encoded": False})
        self.assertEqual(tx["body_state"], "captured")
        self.assertNotIn("DO_NOT_RETAIN_TEST_SECRET", json.dumps(tx))
        self.assertNotIn("z" * 20, json.dumps(tx))

    def test_multigeo_empty_path_normalizes_to_slash(self):
        self.assertEqual(self.state.kind_for_url("https://cstaticdun.126.net/"), "multigeo")

    def test_status_html_records_only_fixed_status_and_tag(self):
        parser = cdp.StatusHTML()
        parser.feed('<span class="ed-status-icon running"></span><span class="ed-status-detail">11 / 11</span><div class="ed-ticker-line fail"><span class="ed-ticker-tag">[DNS]</span><span class="ed-ticker-msg">DO_NOT_RETAIN_TEST_SECRET</span></div>')
        self.assertEqual(parser.phase, "running")
        self.assertEqual(parser.jobs, {"DNS": "fail"})
        self.assertEqual(parser.progress, {"done": 11, "total": 11})
        self.assertNotIn("DO_NOT_RETAIN_TEST_SECRET", json.dumps({"phase": parser.phase, "jobs": parser.jobs, "progress": parser.progress}))


class ProtocolScenarioTests(unittest.TestCase):
    def run_scenario(self, **options):
        clock = Clock()
        socket = FakeSocket(clock, **options)
        checkpoints = []
        capture = cdp.collect(ENDPOINT, copy.deepcopy(CONTRACT), SCOPE, checkpoint=lambda kind, details: checkpoints.append((kind, details)), clock=clock, connector=lambda *args, **kwargs: socket)
        return capture, socket, checkpoints

    def test_single_navigation_prearmed_synthetic_scenario(self):
        capture, socket, checkpoints = self.run_scenario()
        self.assertTrue(capture["synthetic"])
        self.assertEqual(capture["observation"]["end_reason"], "site_result_captured")
        self.assertTrue(capture["observation"]["armed_before_navigation"])
        self.assertEqual(capture["observation"]["source_match"], "matched")
        self.assertTrue(all(capture["observation"]["cleanup"].values()))
        self.assertEqual(socket.methods.count("Page.navigate"), 1)
        self.assertLess(socket.methods.index("Network.enable"), socket.methods.index("Page.navigate"))
        self.assertNotIn("Page.reload", socket.methods)
        self.assertTrue(socket.closed)
        self.assertNotIn("DO_NOT_RETAIN_TEST_SECRET", records.canonical(capture).decode())
        self.assertEqual(checkpoints[-1][0], "navigation_claim")

    def test_no_submit_deadline_is_not_a_zero_result_or_another_round(self):
        capture, socket, _ = self.run_scenario(no_submit=True)
        self.assertEqual(capture["observation"]["end_reason"], "deadline")
        self.assertTrue(capture["observation"]["deadline_reached"])
        self.assertEqual(capture["site_result"]["state"], "pending")
        self.assertEqual(socket.methods.count("Page.navigate"), 1)
        self.assertTrue(all(capture["observation"]["cleanup"].values()))

    def test_unknown_context_creation_is_not_reported_clean(self):
        capture, socket, _ = self.run_scenario(lost_context_reply=True)
        self.assertEqual(capture["observation"]["creation_delivery"]["context"], "unknown")
        self.assertFalse(capture["observation"]["cleanup"]["context_disposed"])
        self.assertNotIn("Page.navigate", socket.methods)
        self.assertNotIn("Target.getBrowserContexts", socket.methods)
        self.assertEqual(socket.methods.count("Target.createBrowserContext"), 1)

    def test_retained_context_after_dispose_is_not_reported_clean(self):
        capture, _, _ = self.run_scenario(retained_context=True)
        self.assertFalse(capture["observation"]["cleanup"]["context_disposed"])

    def test_unexpected_navigation_is_not_closed_as_if_still_our_test(self):
        capture, socket, _ = self.run_scenario(unsafe_navigation=True)
        self.assertEqual(capture["observation"]["end_reason"], "unexpected_navigation")
        self.assertFalse(capture["observation"]["cleanup"]["context_disposed"])
        self.assertNotIn("Target.disposeBrowserContext", socket.methods)
        self.assertNotIn("Target.closeTarget", socket.methods)


if __name__ == "__main__":
    unittest.main()
