"""Observe one normal ping0 page without replacing probes or replaying requests."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import time
from collections import deque
from html.parser import HTMLParser
from urllib.parse import parse_qsl, urlsplit

import records

PAGE_URL = "https://ping0.cc/env"
MAX_FRAME_BYTES = 2 * 1024 * 1024
MAX_EVENTS = 4096
MAX_TRANSACTIONS = 256
SITE_HOSTS = {"ping0.cc", "www.ping0.cc", "cdn.ping0.cc"}
ERROR_NAMES = {"Error", "TypeError", "SyntaxError", "ReferenceError", "RangeError", "DOMException"}


class CaptureError(RuntimeError):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def validate_endpoint(endpoint: str) -> str:
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme != "ws"
        or parsed.hostname not in {"127.0.0.1", "::1"}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not re.fullmatch(r"/devtools/browser/[A-Za-z0-9-]{1,100}", parsed.path)
    ):
        raise CaptureError("use_existing_literal_loopback_browser_endpoint")
    try:
        port = parsed.port
    except ValueError:
        raise CaptureError("invalid_cdp_port") from None
    if port is None or not 1 <= port <= 65535:
        raise CaptureError("invalid_cdp_port")
    return endpoint


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise CaptureError("duplicate_protocol_key")
        result[key] = value
    return result


def _constant(_value):
    raise CaptureError("non_finite_protocol_number")


def _protocol_json(data):
    if not isinstance(data, str) or len(data.encode("utf-8")) > MAX_FRAME_BYTES:
        raise CaptureError("protocol_frame_limit")
    try:
        value = json.loads(data, object_pairs_hook=_pairs, parse_constant=_constant)
    except (ValueError, RecursionError):
        raise CaptureError("invalid_protocol_json") from None
    if not isinstance(value, dict):
        raise CaptureError("invalid_protocol_object")
    return value


class CDPClient:
    def __init__(self, endpoint, deadline, *, clock=time.monotonic, connector=None):
        self.endpoint = validate_endpoint(endpoint)
        self.deadline = deadline
        self.clock = clock
        self.connector = connector
        self.socket = None
        self.sequence = 0
        self.responses = {}
        self.expired = set()
        self.late_replies = 0
        self.on_event = None

    def connect(self):
        remaining = self.deadline - self.clock()
        if remaining <= 0:
            raise CaptureError("deadline")
        connector = self.connector
        if connector is None:
            from websockets.sync.client import connect

            connector = connect
        self.socket = connector(
            self.endpoint,
            open_timeout=min(30, remaining),
            close_timeout=1,
            max_size=MAX_FRAME_BYTES,
        )

    def receive(self, timeout):
        try:
            message = _protocol_json(self.socket.recv(timeout=timeout))
        except TimeoutError:
            return False
        if "id" in message:
            ident = message["id"]
            if type(ident) is not int:
                raise CaptureError("invalid_protocol_id")
            if ident in self.expired:
                self.expired.remove(ident)
                self.late_replies += 1
            else:
                if len(self.responses) >= 64:
                    raise CaptureError("protocol_response_limit")
                self.responses[ident] = message
        elif self.on_event is not None:
            self.on_event(message)
        return True

    def call(self, method, params=None, session_id=None, *, timeout=5):
        stop = min(self.deadline, self.clock() + timeout)
        if stop <= self.clock():
            raise CaptureError("deadline")
        self.sequence += 1
        ident = self.sequence
        message = {"id": ident, "method": method, "params": params or {}}
        if session_id is not None:
            message["sessionId"] = session_id
        self.socket.send(json.dumps(message, separators=(",", ":")))
        iterations = 0
        while ident not in self.responses:
            iterations += 1
            if iterations > 1024:
                self.expired.add(ident)
                raise CaptureError("rpc_iteration_limit")
            remaining = stop - self.clock()
            if remaining <= 0:
                self.expired.add(ident)
                raise CaptureError("rpc_timeout")
            self.receive(min(remaining, 0.25))
        reply = self.responses.pop(ident)
        if self.clock() >= stop:
            self.late_replies += 1
            raise CaptureError("rpc_timeout")
        if "error" in reply:
            # Provider error text can contain URLs, page text, or credentials.
            raise CaptureError("rpc_rejected_" + method.replace(".", "_"))
        result = reply.get("result")
        if not isinstance(result, dict):
            raise CaptureError("invalid_protocol_result")
        return result

    def close(self, *, timeout=1):
        if self.socket is None:
            return True
        try:
            self.socket.close_timeout = max(0, min(1, timeout))
            self.socket.close()
            if self.connector is not None:
                return getattr(self.socket, "closed", None) is True
            transport = getattr(self.socket, "socket", None)
            reader = getattr(self.socket, "recv_events_thread", None)
            return transport is not None and transport.fileno() == -1 and reader is not None and not reader.is_alive()
        except Exception:
            return False


class StatusHTML(HTMLParser):
    """Keep only status enums and job tags, never arbitrary ticker/error text."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.phase = "unknown"
        self.jobs = {}
        self.line = None
        self.in_tag = False
        self.in_detail = False
        self.detail = ""
        self.progress = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = set(attrs.get("class", "").split())
        if "ed-status-icon" in classes:
            for phase in ("running", "done", "error"):
                if phase in classes:
                    self.phase = phase
        if "ed-status-detail" in classes:
            self.in_detail = True
        if "ed-ticker-line" in classes:
            self.line = "fail" if "fail" in classes else "ok" if "ok" in classes else "unknown"
        if "ed-ticker-tag" in classes:
            self.in_tag = True

    def handle_endtag(self, tag):
        if tag == "span":
            self.in_tag = False
            self.in_detail = False
        if tag == "div":
            self.line = None

    def handle_data(self, data):
        if self.in_tag and self.line is not None:
            match = re.fullmatch(r"\[(NET|RTC|IDENT|LOCALE|HW|STEALTH|PRIVACY|API|ENGINE|DNS|MULTIGEO|SCORE)\]", data.strip())
            if match:
                name = match.group(1)
                # Ticker is newest first; do not replace a newer terminal observation.
                self.jobs.setdefault(name, self.line)
        if self.in_detail:
            self.detail += data[:80]
            match = re.fullmatch(r"\s*(\d{1,3})\s*/\s*(\d{1,3})\s*", self.detail)
            if match:
                self.progress = {"done": int(match.group(1)), "total": int(match.group(2))}


def _url_identity(url):
    if not isinstance(url, str) or len(url) > 4096:
        return None
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except (TypeError, ValueError):
        return None
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        return None
    host = parsed.hostname.lower()
    if len(host) > 253 or len(parsed.path) > 256:
        return None
    origin = parsed.scheme + "://" + host
    if port is not None:
        origin += ":" + str(port)
    # Unknown names can themselves contain identifiers. Preserve their presence,
    # not their spelling, so an unexpected query cannot masquerade as no query.
    try:
        fields = parse_qsl(parsed.query, keep_blank_values=True, max_num_fields=32)
        query_names = sorted({key if key in {"init", "debug", "token", "format"} else "other_parameter" for key, _ in fields})
    except ValueError:
        query_names = ["query_limit"]
    if parsed.query and not query_names:
        query_names = ["other_parameter"]
    return {"origin": origin, "path": parsed.path, "query_names": query_names}


class PageCollector:
    def __init__(self, contract, scope_id, deadline, *, clock=time.monotonic):
        self.contract = contract
        self.scope_id = scope_id
        self.deadline = deadline
        self.clock = clock
        self.started = clock()
        self.synthetic = False
        self.session_id = None
        self.target_id = None
        self.context_id = None
        self.collecting = True
        self.events = 0
        self.transactions = []
        self.active_requests = {}
        self.body_queue = deque()
        self.request_queue = deque()
        self.source_urls = {}
        self.script_digests = []
        self.console = []
        self.snapshots = []
        self.client_submission = None
        self.client_submission_transaction_id = None
        self.site_result = {"state": "pending", "scope_id": scope_id, "transaction_id": None, "response": None}
        self.observation = {
            "scope_id": scope_id,
            "armed_before_navigation": False,
            "source_match": "unknown",
            "deadline_reached": False,
            "truncated": False,
            "late_event_count": 0,
            "required_transaction_kinds": ["dnsleak", "submit"],
            "metadata_only_kinds": ["multigeo", "dns_trigger"],
            "optional_projection_kinds": ["ipinfo", "engine"],
            "end_reason": "starting",
            "foreground_requested": False,
            "foreground_lost": False,
            "foreground_observation": "unknown",
            "submission_gate": "unknown",
            "orphan_api_response_count": 0,
            "ignored_network_events": 0,
            "cleanup_events_ignored": 0,
            "resource_requests_observed": {"started": 0, "finished": 0, "failed": 0},
        }
        self.navigation_started = False
        self.main_navigations = 0
        self.stop_reason = None
        self.source_pins = contract.get("source_pins", {})
        targets = contract.get("network_targets", {})
        self.multigeo_urls = {self.resource_key(url) for url in targets.get("multigeo", [])}
        self.engine_urls = {self.resource_key(url).split("?", 1)[0] for url in targets.get("engine_endpoints", [])}

    @staticmethod
    def resource_key(url):
        parsed = urlsplit(url)
        return parsed._replace(path=parsed.path or "/", fragment="").geturl()

    def kind_for_url(self, url):
        identity = _url_identity(url)
        if identity is None:
            return None
        parsed = urlsplit(url)
        base = parsed.scheme + "://" + parsed.netloc + parsed.path
        if base in self.source_pins:
            return "script"
        host = parsed.hostname.lower()
        own = host == "ping0.cc" or host.endswith(".ping0.cc")
        if identity["origin"] == "https://ping0.cc" and parsed.path == "/envdetect/probe/dnsleak":
            return "dnsleak"
        if identity["origin"] == "https://ping0.cc" and parsed.path == "/envdetect/submit":
            return "submit"
        if own and parsed.path == "/envdetect/ipinfo-cors":
            return "ipinfo"
        if base in self.engine_urls:
            return "engine"
        if self.resource_key(url) in self.multigeo_urls or self.resource_key(base) in self.multigeo_urls:
            return "multigeo"
        if re.fullmatch(r"r-[0-9]{13}-[0-9]{1,16}\.d\.ping0\.cc", host) and parsed.path == "/probe":
            return "dns_trigger"
        return None

    def event(self, message):
        if message.get("sessionId") != self.session_id:
            return
        if not self.collecting:
            self.observation["cleanup_events_ignored"] += 1
            return
        self.events += 1
        if self.events > MAX_EVENTS:
            self.observation["truncated"] = True
            self.stop_reason = "event_limit"
            return
        if self.clock() >= self.deadline:
            self.observation["late_event_count"] += 1
            return
        method, params = message.get("method"), message.get("params", {})
        if not isinstance(params, dict):
            self.stop_reason = "invalid_event"
            return
        if method == "Network.requestWillBeSent":
            self._request(params)
        elif method == "Network.responseReceived":
            tx = self.active_requests.get(params.get("requestId"))
            response = params.get("response", {})
            if isinstance(response, dict) and tx is None:
                if self.kind_for_url(response.get("url", "")) in {"dnsleak", "submit"}:
                    self.observation["orphan_api_response_count"] += 1
                    self.observation["truncated"] = True
                    self.observation["truncation_reason"] = "critical_response_without_request"
            if tx is not None and isinstance(response, dict):
                status = response.get("status")
                tx["response_status"] = status if type(status) is int else None
                tx["response_from_cache"] = bool(response.get("fromDiskCache") or response.get("fromServiceWorker"))
                if tx["kind"] in {"dnsleak", "submit"} and _url_identity(response.get("url")) != tx["url"]:
                    tx["body_state"] = "unavailable"
                    tx["schema_state"] = "invalid"
                    tx["error_kind"] = "response_route_mismatch"
                    self.observation["truncated"] = True
                    self.observation["truncation_reason"] = "critical_response_route_mismatch"
        elif method in {"Network.loadingFinished", "Network.loadingFailed"}:
            self._terminal(method, params)
        elif method == "Runtime.consoleAPICalled":
            self._console(params)
        elif method == "Runtime.exceptionThrown":
            detail = params.get("exceptionDetails", {})
            name = detail.get("exception", {}).get("className") if isinstance(detail, dict) else None
            self._console_record("page_exception", name)
        elif method == "Page.javascriptDialogOpening":
            self.stop_reason = "dialog_blocked"
        elif method == "Page.frameNavigated" and self.navigation_started:
            frame = params.get("frame", {})
            if isinstance(frame, dict) and not frame.get("parentId"):
                self.main_navigations += 1
                url = frame.get("url", "")
                if self.main_navigations > 1 or url not in {PAGE_URL, PAGE_URL + "/"}:
                    self.stop_reason = "unexpected_navigation"

    def _request(self, params):
        request = params.get("request", {})
        if not isinstance(request, dict):
            return
        url, ident = request.get("url", ""), params.get("requestId")
        if not isinstance(url, str) or not isinstance(ident, str):
            return
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", ident):
            self.stop_reason = "invalid_request_id"
            return
        previous = self.active_requests.pop(ident, None)
        if previous is not None:
            # Remove the old binding even when a redirect leaves the allowlist.
            previous["terminal"] = "redirected"
            previous["body_state"] = "unavailable"
            previous["error_kind"] = "redirected"
        kind = self.kind_for_url(url)
        if kind is None:
            self.observation["ignored_network_events"] += 1
            return
        if len(self.transactions) >= MAX_TRANSACTIONS:
            self.observation["truncated"] = True
            self.stop_reason = "transaction_limit"
            return
        tx = {
            "transaction_id": "tx-" + str(len(self.transactions) + 1).zfill(6),
            "request_id": ident[:128],
            "scope_id": self.scope_id,
            "sequence": len(self.transactions) + 1,
            "observed_at_ms": max(0, int((self.clock() - self.started) * 1000)),
            "kind": kind,
            "url": _url_identity(url),
            "method": request.get("method") if request.get("method") in {"GET", "POST", "OPTIONS", "HEAD"} else "other",
            "request_fields": None,
            "response_status": None,
            "body_state": "pending" if kind in {"dnsleak", "submit", "ipinfo", "engine", "script"} else "not_requested",
            "response_fields": None,
            "schema_state": "unknown",
            "terminal": "pending",
            "error_kind": None,
            "late": False,
        }
        self.transactions.append(tx)
        self.active_requests[ident] = tx
        if kind == "script":
            self.source_urls[tx["transaction_id"]] = urlsplit(url)._replace(query="", fragment="").geturl()
        if kind == "dns_trigger":
            self.observation["resource_requests_observed"]["started"] += 1
        if kind in {"dnsleak", "submit"} and tx["method"] == "POST":
            post = request.get("postData")
            if isinstance(post, str):
                self.request_body(tx, post)
            elif request.get("hasPostData"):
                self.request_queue.append(tx)
            else:
                tx["request_body_state"] = "unavailable"

    def request_body(self, tx, raw):
        try:
            value = records.decode(raw)
            projected = records.project_dns_request(value) if tx["kind"] == "dnsleak" else records.project_submission(value)
        except (ValueError, TypeError, RecursionError) as error:
            tx["request_body_state"] = "invalid_or_limited"
            tx["request_error_type"] = type(error).__name__[:40]
            return
        tx["request_fields"] = projected
        tx["request_body_state"] = "captured"
        if tx["kind"] == "submit":
            self.client_submission = projected
            self.client_submission_transaction_id = tx["transaction_id"]

    def _terminal(self, method, params):
        tx = self.active_requests.get(params.get("requestId"))
        if tx is None:
            return
        if tx["terminal"] in {"finished", "failed", "redirected"}:
            tx["duplicate_terminal_event"] = True
            return
        failed = method == "Network.loadingFailed"
        tx["terminal"] = "failed" if failed else "finished"
        if tx["kind"] == "dns_trigger":
            key = "failed" if failed else "finished"
            self.observation["resource_requests_observed"][key] += 1
        if failed:
            error = params.get("errorText", "")
            tx["error_kind"] = error if isinstance(error, str) and re.fullmatch(r"net::ERR_[A-Z0-9_]{1,80}", error) else "network_failed"
            tx["body_state"] = "unavailable"
        elif tx["body_state"] == "pending":
            self.body_queue.append(tx)

    def response_body(self, tx, response):
        body = response.get("body")
        if not isinstance(body, str):
            tx["body_state"] = "unavailable"
            return
        try:
            raw = base64.b64decode(body, validate=True) if response.get("base64Encoded") is True else body.encode("utf-8")
        except (ValueError, UnicodeError):
            tx["body_state"] = "unavailable"
            return
        if len(raw) > MAX_FRAME_BYTES:
            tx["body_state"] = "too_large"
            self.observation["truncated"] = True
            return
        if tx["kind"] == "script":
            source_url = self.source_urls[tx["transaction_id"]]
            self.script_digests.append({"url": source_url, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)})
            tx["body_state"] = "captured"
            tx["schema_state"] = "valid"
            tx["response_fields"] = {"source_bytes": len(raw), "source_sha256": hashlib.sha256(raw).hexdigest()}
            return
        if tx["kind"] == "engine":
            # The encrypted catalog may contain long strings. Keep only structural
            # observations; session keys, nonces, and bitmaps are never serialized.
            try:
                value = _protocol_json(raw.decode("utf-8"))
            except (CaptureError, UnicodeError):
                tx["body_state"] = "invalid_json"
                tx["schema_state"] = "invalid"
                return
            tx["body_state"] = "captured"
            tx["schema_state"] = "valid"
            tx["response_fields"] = {
                "object_response": True,
                "session_material_redacted": True,
                "init_catalog_fields_present": all(key in value for key in ("k", "n", "p")),
                "error_present": bool(value.get("error")),
            }
            return
        try:
            value = records.decode(raw)
        except (ValueError, UnicodeError, RecursionError) as error:
            code = getattr(error, "code", "")
            limited = any(part in str(code).lower() for part in ("limit", "large", "depth", "size"))
            tx["body_state"] = "too_large" if limited else "invalid_json"
            tx["schema_state"] = "invalid"
            if limited:
                self.observation["truncated"] = True
            return
        tx["body_state"] = "captured"
        if tx["kind"] == "dnsleak":
            tx["response_fields"] = records.project_dns_response(value)
            tx["schema_state"] = records.dns_schema_state(value)
            if isinstance(value, dict) and value.get("error"):
                tx["schema_state"] = "invalid"
        elif tx["kind"] == "submit":
            projected = records.project_site_result(value)
            tx["response_fields"] = projected
            tx["schema_state"] = "valid" if isinstance(value, dict) and type(value.get("score")) in {int, float} and isinstance(value.get("findings"), list) and not value.get("error") else "invalid"
            state = "captured" if tx["schema_state"] == "valid" and tx["response_status"] is not None and 200 <= tx["response_status"] < 300 else "error"
            self.site_result = {"state": state, "scope_id": self.scope_id, "transaction_id": tx["transaction_id"], "response": projected}
        elif tx["kind"] == "ipinfo":
            family = "ipv6" if tx["url"]["origin"] == "https://ipv6.ping0.cc" else "ipv4"
            tx["response_fields"] = records.project_submission({"net": {family: value}}).get("net", {}).get(family)
            tx["schema_state"] = "valid" if isinstance(value, dict) else "invalid"
            tx["captcha_required_observed"] = isinstance(value, dict) and value.get("error") == "captcha_required"

    def _console_record(self, label, name=None):
        if len(self.console) < 128:
            self.console.append({"label": label, "error_type": name if name in ERROR_NAMES else "unknown"})

    def _console(self, params):
        args = params.get("args", [])
        first = args[0].get("value") if args and isinstance(args[0], dict) else None
        if isinstance(first, str) and first.startswith("[envdetect.dns]"):
            label = "dns_error" if params.get("type") == "error" else "dns_log"
            name = args[1].get("className") if len(args) > 1 and isinstance(args[1], dict) else None
            self._console_record(label, name)
        elif params.get("type") == "error":
            self._console_record("page_console_error")

    def source_match(self):
        observed = {}
        for item in self.script_digests:
            observed.setdefault(item["url"], set()).add(item["sha256"])
        required = {url: info["sha256"] for url, info in self.source_pins.items() if info.get("required") is True}
        if not required or any(url not in observed for url in required):
            return "unknown"
        return "matched" if all(observed[url] == {sha} for url, sha in required.items()) else "unreviewed"

    def snapshot(self, client):
        try:
            visibility = client.call("Runtime.evaluate", {"expression": "document.visibilityState", "returnByValue": True, "silent": True}, self.session_id, timeout=1)
            value = visibility.get("result", {}).get("value")
            visible = value if value in {"visible", "hidden", "prerender"} else "unknown"
            self.observation["foreground_observation"] = visible
            if visible in {"hidden", "prerender"}:
                self.observation["foreground_lost"] = True
            tree = client.call("DOM.getDocument", {"depth": 0}, self.session_id, timeout=1)
            root = tree.get("root", {}).get("nodeId")
            reader = StatusHTML()
            for selector in ("#envdetect-app .ed-status-text", "#envdetect-app .ed-ticker-track"):
                selected = client.call("DOM.querySelector", {"nodeId": root, "selector": selector}, self.session_id, timeout=1)
                node = selected.get("nodeId")
                if node:
                    fragment = client.call("DOM.getOuterHTML", {"nodeId": node}, self.session_id, timeout=1).get("outerHTML", "")
                    if isinstance(fragment, str) and len(fragment) <= 65536:
                        reader.feed(fragment)
            self.snapshots.append({"phase": reader.phase, "progress": reader.progress, "jobs": reader.jobs, "visibility": visible})
        except (CaptureError, ValueError, TypeError):
            self.snapshots.append({"state": "unavailable"})
        if len(self.snapshots) > 64:
            self.observation["truncated"] = True
            self.stop_reason = "snapshot_limit"

    def capture(self, subject):
        self.observation["source_match"] = self.source_match()
        return {
            "schema_version": 1,
            "synthetic": self.synthetic,
            "contract_id": self.contract.get("contract_id"),
            "subject": subject,
            "facts": {
                "transactions": self.transactions,
                "client_submission": self.client_submission,
                "client_submission_transaction_id": self.client_submission_transaction_id,
                "client_submission_scope_id": self.scope_id,
                "script_digests": self.script_digests,
                "console": self.console,
                "page_snapshots": self.snapshots,
            },
            "observation": self.observation,
            "site_result": self.site_result,
        }


def collect(endpoint, contract, scope_id, *, checkpoint, deadline_seconds=90, clock=time.monotonic, connector=None):
    if deadline_seconds != 90:
        raise CaptureError("approved_deadline_is_90_seconds")
    started = clock()
    deadline = started + deadline_seconds
    client = CDPClient(endpoint, deadline, clock=clock, connector=connector)
    state = PageCollector(contract, scope_id, deadline, clock=clock)
    state.synthetic = connector is not None or clock is not time.monotonic
    client.on_event = state.event
    subject = {"kind": "desktop-cdp", "scope_id": scope_id, "context": "owned_temporary_browser_context", "not_an_iPad_result": True}
    cleanup = {"session_detached": False, "target_closed": False, "context_disposed": False, "transport_closed": False}
    context_id = target_id = session_id = None
    context_attempted = target_attempted = session_attempted = False

    def identity(value):
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", value):
            raise CaptureError("invalid_resource_identity")
        return value

    try:
        client.connect()
        version = client.call("Browser.getVersion")
        product = version.get("product")
        subject["product"] = product if isinstance(product, str) and re.fullmatch(r"(?:Headless)?Chrome/[0-9.]{1,40}", product) else "unknown"
        context_attempted = True
        context_id = identity(client.call("Target.createBrowserContext", {"disposeOnDetach": False}).get("browserContextId"))
        state.context_id = context_id
        checkpoint("context_created", {"context_id": context_id})
        client.call("Browser.setDownloadBehavior", {"behavior": "deny", "browserContextId": context_id})
        state.observation["downloads_denied_in_owned_context"] = True
        target_attempted = True
        target_id = identity(client.call("Target.createTarget", {"url": "about:blank", "browserContextId": context_id, "background": False}).get("targetId"))
        state.target_id = target_id
        checkpoint("target_created", {"target_id": target_id, "context_id": context_id})
        session_attempted = True
        session_id = identity(client.call("Target.attachToTarget", {"targetId": target_id, "flatten": True}).get("sessionId"))
        state.session_id = session_id
        subject.update({"target_id": target_id, "session_id": session_id})
        for method, params in (
            ("Page.enable", {}),
            ("Runtime.enable", {}),
            ("DOM.enable", {}),
            ("Network.enable", {"maxTotalBufferSize": 4 * 1024 * 1024, "maxResourceBufferSize": MAX_FRAME_BYTES, "maxPostDataSize": 262144}),
        ):
            client.call(method, params, session_id)
        client.call("Page.bringToFront", session_id=session_id)
        state.observation["foreground_requested"] = True
        state.observation["armed_before_navigation"] = True
        checkpoint("navigation_claim", {"url": PAGE_URL, "navigation_count": 1, "scope_id": scope_id})
        state.navigation_started = True
        reply = client.call("Page.navigate", {"url": PAGE_URL}, session_id)
        if reply.get("errorText"):
            raise CaptureError("navigation_failed")
        next_snapshot = clock() + 1
        while clock() < deadline:
            if state.stop_reason:
                state.observation["end_reason"] = state.stop_reason
                break
            if state.request_queue:
                tx = state.request_queue.popleft()
                try:
                    body = client.call("Network.getRequestPostData", {"requestId": tx["request_id"]}, session_id)
                    post = body.get("postData")
                    if isinstance(post, str):
                        state.request_body(tx, post)
                    else:
                        tx["request_body_state"] = "unavailable"
                except CaptureError:
                    tx["request_body_state"] = "unavailable"
                continue
            if state.body_queue:
                tx = state.body_queue.popleft()
                try:
                    body = client.call("Network.getResponseBody", {"requestId": tx["request_id"]}, session_id)
                    state.response_body(tx, body)
                except CaptureError as error:
                    tx["body_state"] = "unavailable"
                    tx["body_error_kind"] = error.code
                continue
            if state.site_result["state"] in {"captured", "error"}:
                state.snapshot(client)
                state.observation["end_reason"] = "site_result_captured" if state.site_result["state"] == "captured" else "site_result_error"
                break
            if clock() >= next_snapshot:
                state.snapshot(client)
                next_snapshot = clock() + 2
                continue
            client.receive(min(0.2, max(0.001, deadline - clock())))
        else:
            state.observation["deadline_reached"] = True
            state.observation["end_reason"] = "deadline"
        if clock() >= deadline and state.observation["end_reason"] == "starting":
            state.observation["deadline_reached"] = True
            state.observation["end_reason"] = "deadline"
    except KeyboardInterrupt:
        state.observation["end_reason"] = "cancelled"
    except Exception as error:
        code = error.code if isinstance(error, CaptureError) else type(error).__name__
        state.observation["error_kind"] = code[:100]
        state.observation["end_reason"] = "deadline" if clock() >= deadline else "blocked" if target_id is None else "error"
        state.observation["deadline_reached"] = clock() >= deadline
    finally:
        state.collecting = False
        cleanup_started = clock()
        cleanup_deadline = cleanup_started + 5
        # Reserve the last second for closing this transport, not another RPC.
        client.deadline = cleanup_deadline - 1
        safe_context = True
        if session_id:
            try:
                client.call("Target.detachFromTarget", {"sessionId": session_id}, timeout=1)
                cleanup["session_detached"] = True
            except Exception:
                cleanup["session_detached"] = False
        elif not session_attempted:
            cleanup["session_detached"] = True
        if target_id:
            try:
                info = client.call("Target.getTargetInfo", {"targetId": target_id}, timeout=1)["targetInfo"]
                safe_context = info.get("browserContextId") == context_id and info.get("url") in {"about:blank", PAGE_URL, PAGE_URL + "/"}
                if safe_context:
                    cleanup["target_closed"] = client.call("Target.closeTarget", {"targetId": target_id}, timeout=1).get("success") is True
            except Exception:
                safe_context = False
        elif not target_attempted:
            cleanup["target_closed"] = True
        if context_id and safe_context:
            try:
                client.call("Target.disposeBrowserContext", {"browserContextId": context_id}, timeout=1)
                contexts = client.call("Target.getBrowserContexts", timeout=1).get("browserContextIds")
                cleanup["context_disposed"] = isinstance(contexts, list) and context_id not in contexts
                if cleanup["context_disposed"]:
                    # A verified absent owned namespace also covers a creation
                    # whose individual reply was lost; no unknown ID is adopted.
                    cleanup["target_closed"] = True
                    cleanup["session_detached"] = True
            except Exception:
                cleanup["context_disposed"] = False
        elif not context_attempted:
            cleanup["context_disposed"] = True
        state.observation["creation_delivery"] = {
            "context": "identified" if context_id else "unknown" if context_attempted else "not_attempted",
            "target": "identified" if target_id else "unknown" if target_attempted else "not_attempted",
            "session": "identified" if session_id else "unknown" if session_attempted else "not_attempted",
        }
        cleanup["transport_closed"] = client.close(timeout=max(0, cleanup_deadline - clock()))
        cleanup_overrun = clock() > cleanup_deadline
        if cleanup_overrun:
            cleanup["transport_closed"] = False
        state.observation["cleanup_deadline_reached"] = cleanup_overrun
        state.observation["cleanup_elapsed_seconds"] = round(clock() - cleanup_started, 3)
        state.observation["cleanup"] = cleanup
        state.observation["late_event_count"] += client.late_replies
        state.observation["elapsed_seconds"] = round(clock() - started, 3)
        state.observation["navigation_count"] = 1 if state.navigation_started else 0
        state.observation["scope"] = "selected API projections, loaded-source hashes, and status only; not physical DNS/STUN capture"
    return state.capture(subject)
