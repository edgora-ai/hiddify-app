"""Synthetic, offline tests for records.py only; no CLI, browser, or device use."""

import ast
import builtins
import copy
import json
import math
from pathlib import Path
import unittest

import records


_MISSING = object()
_SCOPE = "run-synthetic-001"
_DOMAIN = "r-1760779480123-42.d.ping0.cc"


def contract_stub():
    return {
        "schema_version": 1,
        "contract_id": records.CONTRACT_ID,
        "source_pins": {url: {"sha256": digest, "required": True, "role": "synthetic"}
                        for url, digest in records.EXPECTED_SOURCE_PINS.items()},
    }


def dns_response(count=0, items=None):
    result = {"items": [] if items is None else items}
    if count is not _MISSING:
        result["resolver_count"] = count
    return result


def dns_transaction(count=0, sequence=1, **changes):
    result = {
        "transaction_id": f"tx-{sequence:06d}", "request_id": f"request-{sequence}",
        "scope_id": _SCOPE, "sequence": sequence, "kind": "dnsleak",
        "url": {"origin": "https://ping0.cc", "path": "/envdetect/probe/dnsleak", "query_names": []},
        "method": "POST", "request_fields": {"domains": [_DOMAIN], "stamp": 1760779480123},
        "response_status": 200, "body_state": "captured", "schema_state": "valid",
        "response_fields": dns_response(count), "terminal": "finished", "error_kind": None,
        "late": False,
    }
    result.update(changes)
    return result


def capture_stub(count=0, submitted=_MISSING, finding_fail=False):
    if submitted is _MISSING:
        submitted = count
    submission = {
        "dns": dns_response(submitted),
        "net": {"ipv4": {"ip": "1.1.1.1", "country_code": "US"}, "needCaptcha": False},
        "rtc": {"public_ip": "1.1.1.1", "public_ip_v6": None, "disabled": False, "mdns": True},
        "locale": {"intl_timezone": "America/Los_Angeles", "tz_offset": 420,
                   "fonts_cn": ["PingFang SC"], "language": "en-US",
                   "languages": ["en-US", "zh-CN"], "intl_locale": "en-US", "region": "US"},
    }
    site = {"score": 100, "level": "PASS", "id": "synthetic-result",
            "findings": [{"id": "xc.dns_blackhole", "fail": finding_fail,
                          "severity": "high", "value": {"resolver_count": submitted}}]}
    submit = {
        "transaction_id": "tx-000002", "request_id": "request-2", "scope_id": _SCOPE,
        "sequence": 2, "kind": "submit",
        "url": {"origin": "https://ping0.cc", "path": "/envdetect/submit", "query_names": []},
        "method": "POST", "request_fields": copy.deepcopy(submission),
        "response_status": 200, "body_state": "captured", "schema_state": "valid",
        "response_fields": copy.deepcopy(site), "terminal": "finished", "error_kind": None,
        "late": False,
    }
    return {
        "schema_version": 1, "synthetic": True, "contract_id": records.CONTRACT_ID,
        "subject": {"kind": "desktop-cdp", "scope_id": _SCOPE,
                    "target_id": "synthetic-target", "session_id": "synthetic-session"},
        "facts": {"transactions": [dns_transaction(count), submit],
                  "client_submission": submission, "client_submission_transaction_id": "tx-000002",
                  "client_submission_scope_id": _SCOPE,
                  "script_digests": [{"url": url, "sha256": digest, "bytes": 100}
                                     for url, digest in records.EXPECTED_SOURCE_PINS.items()],
                  "console": [], "page_snapshots": []},
        "observation": {"scope_id": _SCOPE, "armed_before_navigation": True,
                        "source_match": "matched", "deadline_reached": False,
                        "truncated": False, "late_event_count": 0,
                        "end_reason": "site_result_captured", "submission_gate": "unknown",
                        "cleanup": {"session_detached": True, "target_closed": True,
                                    "context_disposed": True, "transport_closed": True}},
        "site_result": {"state": "captured", "transaction_id": "tx-000002",
                        "scope_id": _SCOPE, "response": site},
    }


def polling_capture(counts, submitted=_MISSING):
    capture = capture_stub(counts[-1], submitted=submitted)
    submit = capture["facts"]["transactions"][1]
    sequence = len(counts) + 1
    identifier = f"tx-{sequence:06d}"
    submit.update(sequence=sequence, transaction_id=identifier, request_id=f"request-{sequence}")
    capture["facts"]["transactions"] = [dns_transaction(count, sequence=index + 1)
                                          for index, count in enumerate(counts)] + [submit]
    capture["facts"]["client_submission_transaction_id"] = identifier
    capture["site_result"]["transaction_id"] = identifier
    return capture


def diagnose(capture):
    return records.diagnose(capture, contract_stub())


def without_submission(capture):
    capture["facts"]["transactions"] = [t for t in capture["facts"]["transactions"] if t["kind"] != "submit"]
    capture["facts"]["client_submission"] = None
    capture["facts"]["client_submission_transaction_id"] = None
    capture["facts"]["client_submission_scope_id"] = None
    capture["site_result"] = {"state": "pending", "transaction_id": None,
                              "scope_id": _SCOPE, "response": None}
    return capture


class JsonTests(unittest.TestCase):
    def test_strict_round_trip_and_canonical_newline(self):
        value = {"z": [False, None, "0", 0], "中文": "合成", "a": 1.0}
        encoded = records.canonical(value)
        self.assertEqual(encoded, '{"a":1.0,"z":[false,null,"0",0],"中文":"合成"}\n'.encode())
        self.assertEqual(records.decode(encoded), value)
        self.assertEqual(records.canonical(dict(reversed(list(value.items())))), encoded)

    def test_scalar_json_types_are_not_coerced(self):
        for text, value, kind in [("0", 0, int), ("false", False, bool), ("null", None, type(None)),
                                  ('"0"', "0", str), ("0.0", 0.0, float)]:
            with self.subTest(text=text):
                actual = records.decode(text)
                self.assertEqual(actual, value)
                self.assertIs(type(actual), kind)

    def test_duplicate_keys_rejected_at_every_depth(self):
        for payload in ['{"x":1,"x":2}', '{"nested":{"token":"x","token":"y"}}',
                        '{"x":0,"\\u0078":1}']:
            with self.subTest(payload=payload):
                with self.assertRaises(records.ValidationError) as error:
                    records.decode(payload)
                self.assertEqual(error.exception.code, "json_duplicate_key")
                self.assertEqual(str(error.exception), "json_duplicate_key")

    def test_nonfinite_json_rejected(self):
        for payload in ["NaN", "Infinity", "-Infinity", "1e9999", '{"resolver_count":NaN}']:
            with self.subTest(payload=payload):
                with self.assertRaises(records.ValidationError) as error:
                    records.decode(payload)
                self.assertEqual(error.exception.code, "json_nonfinite_number")

    def test_bad_json_has_fixed_error_and_no_input(self):
        for payload in ['{"secret":"DO-NOT-LOG",}', "", "[", "{} trailing", b"\xff"]:
            with self.subTest(payload=payload):
                with self.assertRaises(records.ValidationError) as error:
                    records.decode(payload)
                self.assertNotIn("DO-NOT-LOG", str(error.exception))
                self.assertTrue(error.exception.code.startswith("json_"))

    def test_invalid_unicode_is_rejected(self):
        for payload in ['"\\ud800"', '"\\udfff"', "\ud800"]:
            with self.subTest(payload=repr(payload)):
                with self.assertRaises(records.ValidationError):
                    records.decode(payload)
        with self.assertRaises(records.ValidationError):
            records.canonical({"bad": "\ud800"})

    def test_decode_limits(self):
        cases = [
            (b" " * (records.MAX_JSON_BYTES + 1), "json_byte_limit"),
            ('"' + "x" * (records.MAX_STRING_LENGTH + 1) + '"', "json_string_limit"),
            ("[" * (records.MAX_JSON_DEPTH + 1) + "0" + "]" * (records.MAX_JSON_DEPTH + 1), "json_structure_limit"),
            ("[" + ",".join("0" for _ in range(records.MAX_JSON_NODES)) + "]", "json_structure_limit"),
            ("9" * 78, "json_number_limit"),
        ]
        for payload, code in cases:
            with self.subTest(code=code):
                with self.assertRaises(records.ValidationError) as error:
                    records.decode(payload)
                self.assertEqual(error.exception.code, code)

    def test_decode_multibyte_byte_budget(self):
        payload = "界" * (records.MAX_JSON_BYTES // 3 + 1)
        with self.assertRaises(records.ValidationError) as error:
            records.decode(payload)
        self.assertEqual(error.exception.code, "json_byte_limit")

    def test_canonical_rejects_non_json_values(self):
        for value in [float("nan"), float("inf"), {0: "value"}, {"x": (1, 2)}, object(), 1 << 257]:
            with self.subTest(kind=type(value).__name__):
                with self.assertRaises(records.ValidationError):
                    records.canonical(value)

    def test_canonical_cycle_is_bounded(self):
        value = []
        value.append(value)
        with self.assertRaises(records.ValidationError) as error:
            records.canonical(value)
        self.assertEqual(error.exception.code, "json_structure_limit")

    def test_wrong_decode_input_is_rejected(self):
        for value in [None, 0, bytearray(b"{}"), {}]:
            with self.subTest(value=value):
                with self.assertRaises(records.ValidationError) as error:
                    records.decode(value)
                self.assertEqual(error.exception.code, "json_input_type")


class ProjectionTests(unittest.TestCase):
    def test_count_preserves_missing_null_boolean_string_and_negative(self):
        self.assertNotIn("resolver_count", records.project_dns_response(dns_response(_MISSING)))
        for raw in [0, 0.0, None, False, True, "0", -1, "", "-1"]:
            with self.subTest(raw=repr(raw)):
                projected = records.project_dns_response(dns_response(raw))
                self.assertEqual(projected["resolver_count"], raw)
                self.assertIs(type(projected["resolver_count"]), type(raw))
        for raw in [{"secret": "value"}, [0], "private-secret-value" * 1000, math.nan, math.inf]:
            with self.subTest(kind=type(raw).__name__):
                projected = records.project_dns_response(dns_response(raw))
                self.assertIs(projected["resolver_count"]["_redacted"], True)
                records.canonical(projected)

    def test_dns_schema_count_types(self):
        for count in [0, 0.0, 1, 12, 12.0]:
            with self.subTest(valid=count):
                self.assertEqual(records.dns_schema_state(dns_response(count)), "valid")
        for count in [None, False, True, "0", -1, 0.5, math.nan, math.inf, 1 << 4000]:
            with self.subTest(invalid=type(count).__name__):
                self.assertEqual(records.dns_schema_state(dns_response(count)), "invalid")
        self.assertEqual(records.dns_schema_state(dns_response(_MISSING)), "invalid")

    def test_dns_items_count_not_derived_from_array_length(self):
        items = [{"ip": "8.8.8.8", "cc": "US", "country": "United States", "foreign": True}]
        for count, values in [(0, items), (7, []), (1, items * 2)]:
            with self.subTest(count=count):
                projected = records.project_dns_response(dns_response(count, values))
                self.assertEqual(projected["resolver_count"], count)
                self.assertEqual(len(projected["items"]), len(values))
                self.assertEqual(records.dns_schema_state(projected), "valid")

    def test_missing_or_wrong_items_is_not_synthesized(self):
        self.assertNotIn("items", records.project_dns_response({"resolver_count": 0}))
        for items in [None, False, "0", {}, [None], [{}]]:
            with self.subTest(items=items):
                result = records.project_dns_response({"resolver_count": 0, "items": items})
                self.assertEqual(records.dns_schema_state(result), "invalid")

    def test_dns_projection_removes_secrets_and_unrelated_fields(self):
        raw = dns_response(2, [{"ip": "8.8.8.8", "cc": "US", "country": "United States", "foreign": False,
                                "Authorization": "AUTH-SECRET", "token": "TOKEN-SECRET", "org": "UNRELATED"}])
        raw.update({"Cookie": "COOKIE-SECRET", "password": "PASSWORD-SECRET", "internal": "UNRELATED"})
        output = records.canonical(records.project_dns_response(raw)).decode()
        for forbidden in ["AUTH-SECRET", "TOKEN-SECRET", "COOKIE-SECRET", "PASSWORD-SECRET", "UNRELATED", "Authorization", "Cookie", "internal"]:
            self.assertNotIn(forbidden, output)
        self.assertIn('"resolver_count":2', output)

    def test_private_dns_addresses_redacted(self):
        private = ["192.168.1.1", "10.0.0.1", "172.16.0.1", "100.64.0.1", "127.0.0.1",
                   "169.254.1.2", "::1", "fe80::1", "fd12::1", "224.0.0.1", "203.0.113.1"]
        raw = dns_response(0, [{"ip": address} for address in private])
        result = records.project_dns_response(raw)
        output = records.canonical(result).decode()
        for address in private:
            self.assertNotIn('"' + address + '"', output)
        self.assertEqual(records.dns_schema_state(result), "invalid")

    def test_request_domain_allowlist_preserves_order_and_duplicates(self):
        second = "r-1760779480124-1234567890123456.d.ping0.cc"
        domains = [_DOMAIN, second, _DOMAIN]
        result = records.project_dns_request({"domains": domains, "stamp": "1760779480123"})
        self.assertEqual(result, {"domains": domains, "stamp": "1760779480123"})

    def test_request_never_keeps_arbitrary_domain_url_or_token(self):
        invalid = ["private.example", "https://" + _DOMAIN, _DOMAIN + "/path", _DOMAIN + ".evil",
                   "r-176077948012-42.d.ping0.cc", "r-1760779480123-12345678901234567.d.ping0.cc",
                   "r-secret-42.d.ping0.cc", "http://192.168.1.2", None, False]
        result = records.project_dns_request({"domains": invalid, "stamp": "STAMP-SECRET",
                                               "url": "https://secret.example", "token": "TOKEN-SECRET"})
        self.assertTrue(all(type(item) is dict and item["_redacted"] for item in result["domains"]))
        output = records.canonical(result).decode()
        for forbidden in ["private.example", "https://", "secret", "STAMP-SECRET", "TOKEN-SECRET", "192.168.1.2"]:
            self.assertNotIn(forbidden, output)

    def test_request_missing_values_stay_missing(self):
        self.assertEqual(records.project_dns_request({}), {})
        result = records.project_dns_request({"stamp": None, "domains": None})
        self.assertIsNone(result["stamp"])
        self.assertEqual(result["domains"]["_type"], "null")

    def test_request_and_response_projection_bounds_are_visible(self):
        request = records.project_dns_request({"domains": [_DOMAIN] * (records.MAX_DOMAINS + 1), "stamp": 1})
        response = records.project_dns_response(dns_response(0, [{"ip": "8.8.8.8"}] * (records.MAX_DNS_ITEMS + 1)))
        self.assertTrue(request["_projection_truncated"])
        self.assertEqual(len(request["domains"]), records.MAX_DOMAINS)
        self.assertTrue(response["_projection_truncated"])
        self.assertEqual(len(response["items"]), records.MAX_DNS_ITEMS)
        self.assertEqual(records.dns_schema_state(response), "invalid")

    def test_submission_retains_only_diagnostic_namespaces(self):
        raw = capture_stub()["facts"]["client_submission"]
        raw.update({"token": "TOKEN-SECRET", "engine": {"sid": "SID-SECRET", "k": "K-SECRET", "n": "N-SECRET", "p": "P-SECRET", "b": "B-SECRET"},
                    "canvas": {"hash": "UNRELATED-FINGERPRINT"}, "Authorization": "BEARER-SECRET"})
        result = records.project_submission(raw)
        self.assertEqual(set(result), {"dns", "net", "rtc", "locale"})
        self.assertEqual(result["locale"]["intl_timezone"], "America/Los_Angeles")
        self.assertEqual(result["locale"]["fonts_cn"], ["PingFang SC"])
        self.assertEqual(result["locale"]["languages"], ["en-US", "zh-CN"])
        output = records.canonical(result).decode()
        for forbidden in ["SECRET", "UNRELATED-FINGERPRINT", "engine", "canvas", "token", "Authorization"]:
            self.assertNotIn(forbidden, output)

    def test_flat_locale_fields_and_i18n_namespace(self):
        fields = {"intl_timezone": "Asia/Shanghai", "tz_offset": -480,
                  "fonts_cn": 3, "language": "zh-CN", "languages": ["zh-CN"],
                  "intl_locale": "zh-CN", "region": "CN"}
        self.assertEqual(records.project_submission(fields), fields)
        self.assertEqual(records.project_submission({"i18n": fields}), {"i18n": fields})

    def test_locale_rejects_unbounded_or_sensitive_values(self):
        raw = {"locale": {"language": "LANGUAGE-SECRET", "languages": ["en-US", "SECRET-LONG-123456789"],
                           "intl_timezone": "https://secret.example", "fonts_cn": ["PRIVATE-FONT-NAME"],
                           "region": "PRIVATE-REGION"}, "token": "en-US"}
        output = records.canonical(records.project_submission(raw)).decode()
        for forbidden in ["LANGUAGE-SECRET", "SECRET-LONG", "https://", "PRIVATE-FONT", "PRIVATE-REGION", "en-US"]:
            self.assertNotIn(forbidden, output)

    def test_net_public_addresses_country_capabilities_and_captcha_flag(self):
        raw = {"net": {"ipv4": {"ip": "1.1.1.1", "country_code": "US", "asn": "AS13335", "org": "PUBLIC-ORG"},
                       "ipv6": {"ip": "2606:4700:4700::1111", "country": "United States"},
                       "国家": "美国", "needCaptcha": True, "risk": "low", "udp": False,
                       "captchaToken": "CAPTCHA-SECRET", "headers": {"Cookie": "COOKIE-SECRET"}}}
        result = records.project_submission(raw)["net"]
        self.assertEqual(result["ipv4"]["ip"], "1.1.1.1")
        self.assertEqual(result["ipv6"]["ip"], "2606:4700:4700::1111")
        self.assertEqual(result["ipv4"]["asn"], "AS13335")
        self.assertIs(result["needCaptcha"], True)
        self.assertIs(result["udp"], False)
        output = records.canonical(result).decode()
        for forbidden in ["PUBLIC-ORG", "CAPTCHA-SECRET", "COOKIE-SECRET", "headers", "captchaToken"]:
            self.assertNotIn(forbidden, output)

    def test_rtc_retains_public_and_only_mdns_presence(self):
        raw = {"rtc": {"public_ip": ["1.1.1.1", "192.168.1.2"],
                       "public_ip_v6": ["2606:4700:4700::1111", "fd12::1234", "fe80::1%en0"],
                       "disabled": False, "mdns": ["device-secret.local"],
                       "local_ip": "10.0.0.1", "candidates": "candidate PRIVATE-CANDIDATE"}}
        result = records.project_submission(raw)["rtc"]
        self.assertEqual(result["public_ip"][0], "1.1.1.1")
        self.assertEqual(result["public_ip_v6"][0], "2606:4700:4700::1111")
        self.assertEqual(result["mdns"], {"present": True, "_type": "array"})
        output = records.canonical(result).decode()
        for forbidden in ["192.168.1.2", "fd12::1234", "fe80::1", "en0", "device-secret.local", "10.0.0.1", "PRIVATE-CANDIDATE", "local_ip", "candidates"]:
            self.assertNotIn(forbidden, output)

    def test_site_result_preserves_whitelisted_findings_and_no_secrets(self):
        raw = {"score": 39, "level": "FAIL", "id": "synthetic-id", "token": "SECRET-REPEATED",
               "Cookie": "COOKIE-SECRET", "raw_payload": "UNRELATED",
               "findings": [{"id": "xc.dns_blackhole", "fail": True, "severity": "high",
                             "value": {"resolver_count": 2, "actual": "SECRET-REPEATED", "token": "TOKEN-SECRET"},
                             "evidence": {"ip": "192.168.1.2", "public_ip": "1.1.1.1", "Authorization": "AUTH-SECRET", "unrelated": "UNRELATED"}},
                            {"id": "arbitrary-secret-id", "value": "OTHER-SECRET"},
                            {"id": "xc.ip_fonts_cn", "fail": False, "evidence": {"fonts_cn": ["PingFang SC"]}}]}
        result = records.project_site_result(raw)
        self.assertEqual(result["score"], 39)
        self.assertEqual(result["_omitted_findings"], 1)
        self.assertEqual([row["id"] for row in result["findings"]], ["xc.dns_blackhole", "xc.ip_fonts_cn"])
        output = records.canonical(result).decode()
        for forbidden in ["SECRET-REPEATED", "COOKIE-SECRET", "TOKEN-SECRET", "AUTH-SECRET", "OTHER-SECRET", "UNRELATED", "192.168.1.2", "arbitrary-secret-id", "Authorization", "Cookie"]:
            self.assertNotIn(forbidden, output)

    def test_all_reviewed_cross_layer_ids_retained(self):
        self.assertEqual(len(records.FINDING_IDS), 18)
        result = records.project_site_result({"findings": [{"id": identifier, "fail": False} for identifier in sorted(records.FINDING_IDS)]})
        self.assertEqual({row["id"] for row in result["findings"]}, records.FINDING_IDS)

    def test_reviewed_findings_after_ordinary_rows_are_not_cut_off(self):
        ordinary = [{"id": "unreviewed-row", "value": "UNRELATED-SECRET"} for _ in range(136)]
        reviewed = [{"id": identifier, "fail": False} for identifier in sorted(records.FINDING_IDS)]
        result = records.project_site_result({"score": 67, "findings": ordinary + reviewed})
        self.assertEqual(len(ordinary + reviewed), 154)
        self.assertEqual({row["id"] for row in result["findings"]}, records.FINDING_IDS)
        self.assertEqual(result["_omitted_findings"], 136)
        self.assertNotIn("_projection_truncated", result)
        self.assertNotIn("UNRELATED-SECRET", records.canonical(result).decode())
        self.assertEqual(records.project_site_result(result), result)

    def test_finding_scan_and_retained_bounds_still_report_loss(self):
        cases = [
            [{"id": "unreviewed-row"}] * records.MAX_FINDING_SCAN + [{"id": "xc.dns_blackhole"}],
            [{"id": "xc.dns_blackhole"}] * (records.MAX_FINDINGS + 1),
        ]
        for findings in cases:
            with self.subTest(count=len(findings)):
                result = records.project_site_result({"findings": findings})
                self.assertIs(result["_projection_truncated"], True)
                self.assertLessEqual(len(result["findings"]), records.MAX_FINDINGS)
                self.assertEqual(records.project_site_result(result), result)

    def test_server_evidence_is_separate_and_redacts_outer_secrets(self):
        raw = {"score": 67, "token": "8.8.8.8", "evidence": {
            "dns": {"resolver_count": 1, "items": [{"ip": "1.1.1.1"}]},
            "rtc": {"public_ip": "8.8.8.8", "local_ip": "192.168.1.1"},
            "hardware": {"unrelated": "UNRELATED-SECRET"},
        }}
        result = records.project_site_result(raw)
        self.assertEqual(result["evidence"]["dns"]["resolver_count"], 1)
        self.assertEqual(result["evidence"]["dns"]["items"][0]["ip"], "1.1.1.1")
        output = records.canonical(result).decode()
        for secret in ("8.8.8.8", "192.168.1.1", "UNRELATED-SECRET", "token", "hardware"):
            self.assertNotIn(secret, output)
        self.assertEqual(records.project_site_result(result), result)

    def test_previously_truncated_findings_cannot_be_recovered_by_replay(self):
        retained = {"score": 0, "findings": [], "_omitted_findings": 154, "_projection_truncated": True}
        self.assertEqual(records.project_site_result(retained), retained)
        capture = capture_stub()
        capture["facts"]["transactions"][1]["response_fields"] = retained
        capture["site_result"]["response"] = copy.deepcopy(retained)
        report = diagnose(capture)
        self.assertEqual(report["status"], "incomplete")
        self.assertIn("projection_truncated", report["reasons"])
        self.assertIsNone(report["direct_backend_observation"]["selected"])

    def test_site_boolean_types_not_coerced(self):
        for value in [None, False, True, 0, "false", [], {}]:
            with self.subTest(value=value):
                result = records.project_site_result({"findings": [{"id": "xc.dns_blackhole", "fail": value}]})
                retained = result["findings"][0]["fail"]
                if value is None or type(value) is bool:
                    self.assertIs(retained, value)
                else:
                    self.assertIs(retained["_redacted"], True)

    def test_projection_idempotence(self):
        values = [
            (records.project_dns_request, {"domains": [_DOMAIN, "secret.example"], "stamp": "secret"}),
            (records.project_dns_response, dns_response("secret", [{"ip": "192.168.1.2"}])),
            (records.project_submission, {"dns": dns_response("secret"), "rtc": {"public_ip": "192.168.1.2"}}),
            (records.project_site_result, {"score": "secret", "findings": [{"id": "not-reviewed"}]}),
        ]
        for function, value in values:
            with self.subTest(function=function.__name__):
                once = function(value)
                twice = function(once)
                self.assertEqual(once, twice)

    def test_sensitive_text_cannot_impersonate_locale_timezone_or_result_id(self):
        submission = records.project_submission({"locale": {"language": "en-secret", "intl_timezone": "Cookie/value"}})
        site = records.project_site_result({"id": "result-token-value", "findings": [
            {"id": "xc.ip_tz", "value": "Authorization/value", "evidence": {"actual": "Secret/value"}}
        ]})
        output = records.canonical({"submission": submission, "site": site}).decode()
        for value in ["en-secret", "Cookie/value", "result-token-value", "Authorization/value", "Secret/value"]:
            self.assertNotIn(value, output)

    def test_api_keys_and_nested_credentials_are_redacted_before_projection(self):
        for key in ["api_key", "x-api-key", "private_key", "auth", "user_password", "access_token", "session_id"]:
            with self.subTest(key=key):
                raw = {"country": "US", key: "US"}
                result = records.project_submission({"net": raw})
                self.assertTrue(result["net"]["country"]["_redacted"])
                self.assertNotIn('"US"', records.canonical(result).decode())
                self.assertNotIn(key, records.canonical(result).decode())

    def test_numeric_secret_values_are_not_echoed_in_diagnostic_fields(self):
        raw = {"resolver_count": 123456789, "items": [], "token": 123456789}
        result = records.project_dns_response(raw)
        self.assertTrue(result["resolver_count"]["_redacted"])
        self.assertNotIn("123456789", records.canonical(result).decode())
        self.assertEqual(records.dns_schema_state(result), "invalid")

    def test_presence_and_truncation_markers_are_idempotent(self):
        raw = {"net": {"org": "DO-NOT-RETAIN", "asnname": "DO-NOT-RETAIN"},
               "rtc": {"mdns": ["private.local"], "public_ip": ["1.1.1.1"] * 17},
               "locale": {"fonts_cn": ["PingFang SC"] * 33, "languages": ["en-US"] * 17}}
        once = records.project_submission(raw)
        twice = records.project_submission(once)
        self.assertEqual(once, twice)
        self.assertNotIn("DO-NOT-RETAIN", records.canonical(twice).decode())
        self.assertTrue(twice["rtc"]["public_ip"]["_projection_truncated"])
        self.assertTrue(twice["locale"]["fonts_cn"]["_projection_truncated"])

    def test_redacted_country_string_does_not_change_numeric_count_schema(self):
        result = records.project_dns_response(dns_response(2, [{"ip": "8.8.8.8", "country": "COUNTRY-NOT-IN-LABEL-LIST"}]))
        self.assertTrue(result["items"][0]["country"]["_redacted"])
        self.assertEqual(records.dns_schema_state(result), "valid")
        self.assertEqual(result["resolver_count"], 2)

    def test_malformed_marker_and_finding_fields_do_not_raise(self):
        raw = {"resolver_count": {"_redacted": True, "_type": []}, "items": []}
        self.assertEqual(records.dns_schema_state(records.project_dns_response(raw)), "invalid")
        result = records.project_site_result({"findings": [{"id": []}, {"id": {}}]})
        self.assertEqual(result["findings"], [])
        self.assertEqual(result["_omitted_findings"], 2)

    def test_wrong_root_types_are_marked_not_defaulted(self):
        for function in [records.project_dns_request, records.project_dns_response,
                         records.project_submission, records.project_site_result]:
            for value in [None, False, 0, "0", [], ["SECRET"]]:
                with self.subTest(function=function.__name__, kind=type(value).__name__):
                    result = function(value)
                    self.assertIs(result["_redacted"], True)
                    self.assertNotIn("resolver_count", result)


class DiagnosisTests(unittest.TestCase):
    def test_explicit_zero_and_positive_complete_rounds(self):
        for count, state in [(0, "backend_zero"), (0.0, "backend_zero"), (1, "backend_positive"), (17, "backend_positive")]:
            with self.subTest(count=count):
                result = diagnose(capture_stub(count))
                self.assertEqual(result["status"], state)
                self.assertIs(result["complete"], True)
                self.assertEqual(result["direct_backend_observation"]["status"], state)
                self.assertNotIn("pass", result)

    def test_invalid_or_missing_count_never_becomes_zero(self):
        for count in [_MISSING, None, False, True, "0", -1, 0.5, "SECRET" * 100]:
            with self.subTest(count=repr(count)):
                capture = capture_stub()
                capture["facts"]["transactions"][0]["response_fields"] = dns_response(count)
                result = diagnose(capture)
                self.assertEqual(result["status"], "incomplete")
                self.assertEqual(result["direct_backend_observation"]["status"], "incomplete")
                self.assertNotEqual(result["status"], "probe_error")

    def test_count_items_mismatch_not_inferred_from_length(self):
        for count, items, state in [(0, [{"ip": "8.8.8.8"}], "backend_zero"), (9, [], "backend_positive"),
                                    (1, [{"ip": "8.8.8.8"}] * 2, "backend_positive")]:
            with self.subTest(count=count):
                capture = capture_stub(count)
                capture["facts"]["transactions"][0]["response_fields"] = dns_response(count, items)
                result = diagnose(capture)
                self.assertEqual(result["status"], state)
                row = result["direct_backend_observation"]["transactions"][0]
                self.assertEqual(row["resolver_count"], count)
                self.assertFalse(row["items_length_used_as_count"])
                self.assertIn("items_deduplication_unknown", result["limits"])

    def test_http_500_with_zero_is_actual_error(self):
        capture = capture_stub()
        capture["facts"]["transactions"][0]["response_status"] = 500
        result = diagnose(capture)
        self.assertEqual(result["status"], "probe_error")
        self.assertEqual(result["direct_backend_observation"]["transactions"][0]["reason"], "http_error")

    def test_request_failure_and_invalid_json_are_actual_errors(self):
        for changes, reason in [({"terminal": "failed", "error_kind": "request_failed"}, "request_failed"),
                                ({"body_state": "invalid_json", "response_fields": None}, "invalid_json")]:
            with self.subTest(reason=reason):
                capture = capture_stub()
                capture["facts"]["transactions"][0].update(changes)
                result = diagnose(capture)
                self.assertEqual(result["status"], "probe_error")
                self.assertEqual(result["direct_backend_observation"]["transactions"][0]["reason"], reason)

    def test_unreviewed_or_conflicting_error_metadata_cannot_be_zero(self):
        for error_kind in ["UNREVIEWED-ERROR-DETAIL", "request_failed", "timeout", False, 0, [], {}]:
            with self.subTest(error_kind=error_kind):
                capture = capture_stub()
                capture["facts"]["transactions"][0]["error_kind"] = error_kind
                result = diagnose(capture)
                self.assertEqual(result["status"], "incomplete")
                self.assertNotEqual(result["status"], "probe_error")
                self.assertIn("transaction_error_metadata_unreviewed_or_conflicting", result["reasons"])
                self.assertNotIn("UNREVIEWED-ERROR-DETAIL", records.canonical(result).decode())

    def test_actual_request_failure_does_not_depend_on_error_text(self):
        capture = capture_stub()
        capture["facts"]["transactions"][0].update(terminal="failed", error_kind="UNREVIEWED-ERROR-DETAIL")
        result = diagnose(capture)
        self.assertEqual(result["status"], "probe_error")
        self.assertNotIn("UNREVIEWED-ERROR-DETAIL", records.canonical(result).decode())

    def test_unbound_scope_or_colliding_identity_keeps_values_without_zero_label(self):
        capture = capture_stub()
        capture["facts"]["transactions"][0]["scope_id"] = "run-other-page"
        result = diagnose(capture)
        direct = result["direct_backend_observation"]["transactions"][0]
        self.assertEqual(direct["resolver_count"], 0)
        self.assertEqual(direct["status"], "incomplete")
        self.assertFalse(direct["scope_match"])
        self.assertEqual(result["direct_backend_observation"]["status"], "incomplete")
        capture = capture_stub()
        capture["facts"]["transactions"][1]["request_id"] = "request-1"
        result = diagnose(capture)
        direct = result["direct_backend_observation"]["transactions"][0]
        self.assertEqual(direct["resolver_count"], 0)
        self.assertEqual(direct["status"], "incomplete")
        self.assertFalse(direct["identity_unique"])

    def test_capture_gaps_are_not_actual_request_failures(self):
        mutations = [
            ("body_state", "pending"), ("body_state", "unavailable"), ("body_state", "too_large"),
            ("body_state", "not_requested"), ("terminal", "pending"), ("response_fields", None),
            ("response_status", None), ("response_status", "500"), ("schema_state", "unknown"),
            ("schema_state", "invalid"), ("response_fields", {}),
        ]
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                capture = capture_stub()
                capture["facts"]["transactions"][0][field] = value
                result = diagnose(capture)
                self.assertEqual(result["status"], "incomplete")
                self.assertEqual(result["direct_backend_observation"]["transactions"][0]["status"], "incomplete")

    def test_observation_flags_fail_closed(self):
        for field, value, state in [("armed_before_navigation", False, "unknown"),
                                    ("source_match", "unreviewed", "unknown"),
                                    ("source_match", "unknown", "unknown"),
                                    ("deadline_reached", True, "incomplete"),
                                    ("truncated", True, "incomplete"),
                                    ("late_event_count", 1, "incomplete"),
                                    ("late_event_count", False, "incomplete"),
                                    ("end_reason", "cancelled", "incomplete")]:
            with self.subTest(field=field, value=value):
                capture = capture_stub()
                capture["observation"][field] = value
                result = diagnose(capture)
                self.assertEqual(result["status"], state)
                self.assertFalse(result["complete"])
                self.assertEqual(result["direct_backend_observation"]["status"], "backend_zero")

    def test_missing_observation_flags_fail_closed(self):
        for field in ["armed_before_navigation", "source_match", "deadline_reached", "truncated",
                      "late_event_count", "end_reason", "cleanup"]:
            with self.subTest(field=field):
                capture = capture_stub()
                del capture["observation"][field]
                self.assertIn(diagnose(capture)["status"], {"unknown", "incomplete"})

    def test_each_cleanup_failure_blocks_complete_round(self):
        for field in ["session_detached", "target_closed", "context_disposed", "transport_closed"]:
            for value in [False, None, "true", 1]:
                with self.subTest(field=field, value=value):
                    capture = capture_stub()
                    capture["observation"]["cleanup"][field] = value
                    result = diagnose(capture)
                    self.assertEqual(result["status"], "incomplete")
                    self.assertIn("cleanup_incomplete", result["reasons"])

    def test_late_transaction_never_washes_round_green(self):
        for value in [True, None, "false", 0]:
            with self.subTest(value=value):
                capture = capture_stub()
                capture["facts"]["transactions"][0]["late"] = value
                result = diagnose(capture)
                self.assertEqual(result["status"], "incomplete")
                self.assertIn("late_transaction_or_unknown", result["reasons"])

    def test_source_mismatch_preserves_direct_backend_fact(self):
        capture = capture_stub(3)
        capture["facts"]["script_digests"][0]["sha256"] = "0" * 64
        result = diagnose(capture)
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(result["direct_backend_observation"]["status"], "backend_positive")
        self.assertIn("source_digest_mismatch", result["reasons"])

    def test_source_absence_and_duplicate_conflicting_digest(self):
        for mode in ["absent", "bytes_missing", "conflicting"]:
            with self.subTest(mode=mode):
                capture = capture_stub()
                if mode == "absent":
                    capture["facts"]["script_digests"].pop()
                elif mode == "bytes_missing":
                    capture["facts"]["script_digests"][0].pop("bytes")
                else:
                    conflicting = copy.deepcopy(capture["facts"]["script_digests"][0])
                    conflicting["sha256"] = "f" * 64
                    capture["facts"]["script_digests"].append(conflicting)
                self.assertEqual(diagnose(capture)["status"], "unknown")

    def test_contract_identity_and_pins_mandatory(self):
        for mode in ["id", "schema", "pins", "hash", "required"]:
            with self.subTest(mode=mode):
                contract = contract_stub()
                first = next(iter(records.EXPECTED_SOURCE_PINS))
                if mode == "id":
                    contract["contract_id"] = "unreviewed-contract"
                elif mode == "schema":
                    contract["schema_version"] = True
                elif mode == "pins":
                    contract.pop("source_pins")
                elif mode == "hash":
                    contract["source_pins"][first]["sha256"] = "f" * 64
                else:
                    contract["source_pins"][first]["required"] = False
                result = records.diagnose(capture_stub(), contract)
                self.assertEqual(result["status"], "unknown")

    def test_scope_missing_or_wrong_never_reuses_request_id(self):
        for path in ["subject", "observation", "transaction", "response_scope", "target", "session"]:
            with self.subTest(path=path):
                capture = capture_stub()
                if path in {"subject", "observation"}:
                    capture[path].pop("scope_id")
                elif path == "transaction":
                    capture["facts"]["transactions"][0]["scope_id"] = "run-another-page"
                elif path == "response_scope":
                    capture["facts"]["transactions"][0]["response_scope_id"] = "run-another-page"
                else:
                    capture["facts"]["transactions"][0][path + "_id"] = "another-page"
                result = diagnose(capture)
                self.assertEqual(result["status"], "unknown")
                self.assertFalse(result["complete"])

    def test_same_request_id_across_pages_is_not_associated(self):
        capture = capture_stub()
        other = dns_transaction(8, sequence=3, scope_id="run-another-page", request_id="request-1")
        capture["facts"]["transactions"].append(other)
        result = diagnose(capture)
        self.assertEqual(result["status"], "unknown")
        self.assertIn("transaction_identity_collision", result["reasons"])
        self.assertIn("transaction_scope_mismatch", result["reasons"])
        self.assertEqual(len(result["direct_backend_observation"]["transactions"]), 2)

    def test_duplicate_transaction_or_sequence_fails_closed(self):
        for field in ["transaction_id", "request_id", "sequence"]:
            with self.subTest(field=field):
                capture = capture_stub()
                capture["facts"]["transactions"][1][field] = capture["facts"]["transactions"][0][field]
                result = diagnose(capture)
                self.assertEqual(result["status"], "unknown")
                self.assertIn("transaction_identity_collision", result["reasons"])

    def test_boolean_sequence_is_not_identity(self):
        capture = capture_stub()
        capture["facts"]["transactions"][0]["sequence"] = True
        self.assertEqual(diagnose(capture)["status"], "unknown")

    def test_poll_sequence_preserved_positive_then_zero(self):
        capture = polling_capture([2, 1, 0])
        capture["facts"]["transactions"].reverse()
        result = diagnose(capture)
        self.assertEqual(result["status"], "backend_zero")
        self.assertEqual(result["direct_backend_observation"]["status"], "mixed")
        rows = result["direct_backend_observation"]["transactions"]
        self.assertEqual([row["sequence"] for row in rows], [1, 2, 3])
        self.assertEqual([row["resolver_count"] for row in rows], [2, 1, 0])
        self.assertEqual(result["direct_backend_observation"]["selected"]["resolver_count"], 0)

    def test_valid_mixed_poll_sequences_select_final_source_bound_response(self):
        # The probe's own polling deadline is distinct from a truncated capture deadline.
        for counts, state in [([0, 1, 1], "backend_positive"), ([1, 0], "backend_zero"),
                              ([1, 0, 1], "backend_positive")]:
            with self.subTest(counts=counts):
                result = diagnose(polling_capture(counts))
                self.assertEqual(result["status"], state)
                self.assertTrue(result["complete"])
                self.assertEqual(result["client_submission_comparison"]["status"], "consistent")
                direct = result["direct_backend_observation"]
                self.assertEqual(direct["status"], "mixed")
                self.assertEqual([row["resolver_count"] for row in direct["transactions"]], counts)
                self.assertEqual(direct["final_observed"]["status"], state)
                self.assertEqual(direct["selected"]["status"], state)
                self.assertEqual(direct["selected"]["resolver_count"], counts[-1])
                self.assertEqual(direct["selected"]["sequence"], len(counts))
                self.assertEqual(direct["selection_basis"], "source_bound_last_completed_valid_dns_response")
                self.assertIn("no_system_dns_causality_claim", result["limits"])
                markdown = records.render_markdown(result)
                self.assertIn("history_status: `mixed`", markdown)
                self.assertIn("selected_status: `" + state + "`", markdown)
                self.assertIn("source_bound_last_completed_valid_dns_response", markdown)

    def test_client_divergence_uses_final_response_not_historical_positive(self):
        cases = [([1, 0], 0, "backend_zero"), ([0, 1, 1], 0, "client_submission_divergence"),
                 ([1, 0, 1], 0, "client_submission_divergence")]
        for counts, submitted, expected in cases:
            with self.subTest(counts=counts):
                result = diagnose(polling_capture(counts, submitted=submitted))
                self.assertEqual(result["status"], expected)
                self.assertEqual(result["direct_backend_observation"]["selected"]["resolver_count"], counts[-1])
                if counts[-1] == 0:
                    self.assertEqual(result["client_submission_comparison"]["status"], "consistent")
                    self.assertNotIn("divergence_transaction_ids", result["client_submission_comparison"])
                else:
                    self.assertEqual(result["client_submission_comparison"]["status"], "client_submission_divergence")

    def test_cross_nonce_or_domains_poll_history_is_unknown(self):
        changes = [{"stamp": 1760779480124},
                   {"domains": ["r-1760779480123-43.d.ping0.cc"]},
                   {"domains": [_DOMAIN, _DOMAIN]}]
        for change in changes:
            with self.subTest(change=change):
                capture = polling_capture([1, 0, 1], submitted=0)
                capture["facts"]["transactions"][1]["request_fields"].update(change)
                result = diagnose(capture)
                self.assertEqual(result["status"], "unknown")
                self.assertIn("dns_polling_request_identity_mismatch", result["reasons"])
                self.assertEqual(result["direct_backend_observation"]["status"], "mixed")
                self.assertIsNone(result["direct_backend_observation"]["selected"])
                self.assertEqual(result["client_submission_comparison"]["status"], "unknown")

    def test_mixed_valid_history_with_unknown_source_or_capture_bounds_is_not_selected(self):
        for field, value in [("source_match", "unknown"), ("armed_before_navigation", False),
                             ("deadline_reached", True), ("truncated", True),
                             ("end_reason", "unknown"), ("late_event_count", 1)]:
            with self.subTest(field=field):
                capture = polling_capture([1, 0, 1])
                capture["observation"][field] = value
                result = diagnose(capture)
                self.assertIn(result["status"], {"unknown", "incomplete"})
                self.assertEqual(result["direct_backend_observation"]["status"], "mixed")
                self.assertIsNone(result["direct_backend_observation"]["selected"])
                self.assertEqual(result["client_submission_comparison"]["status"], "unknown")

    def test_mixed_poll_history_missing_schema_late_or_wrong_scope_is_not_selected(self):
        for changes in [{"schema_state": "unknown"}, {"response_fields": None},
                        {"late": True}, {"scope_id": "run-other-page"}]:
            with self.subTest(changes=changes):
                capture = polling_capture([1, 0, 1])
                capture["facts"]["transactions"][1].update(changes)
                result = diagnose(capture)
                self.assertIn(result["status"], {"unknown", "incomplete"})
                self.assertIsNone(result["direct_backend_observation"]["selected"])
                self.assertEqual(result["client_submission_comparison"]["status"], "unknown")

    def test_dns_poll_after_selected_submission_cannot_rewrite_result(self):
        capture = capture_stub(1)
        capture["facts"]["transactions"].append(dns_transaction(0, sequence=3))
        result = diagnose(capture)
        self.assertEqual(result["status"], "incomplete")
        self.assertIn("dns_poll_after_selected_submission", result["reasons"])
        self.assertEqual(result["direct_backend_observation"]["status"], "mixed")
        self.assertEqual(result["direct_backend_observation"]["final_observed"]["resolver_count"], 0)
        self.assertIsNone(result["direct_backend_observation"]["selected"])
        self.assertEqual(result["client_submission_comparison"]["status"], "unknown")

    def test_prior_error_survives_later_positive(self):
        capture = polling_capture([2, 2])
        capture["facts"]["transactions"][0]["response_status"] = 500
        result = diagnose(capture)
        self.assertEqual(result["status"], "probe_error")
        direct = result["direct_backend_observation"]
        self.assertEqual([row["status"] for row in direct["transactions"]], ["probe_error", "backend_positive"])
        self.assertEqual(direct["final_observed"]["status"], "backend_positive")
        self.assertIsNone(direct["selected"])

    def test_last_error_survives_prior_positive_or_zero(self):
        for first in [0, 2]:
            for changes in [{"terminal": "failed"}, {"response_status": 500},
                            {"body_state": "invalid_json", "response_fields": None}]:
                with self.subTest(first=first, changes=changes):
                    capture = polling_capture([first, 0], submitted=first)
                    capture["facts"]["transactions"][1].update(changes)
                    result = diagnose(capture)
                    self.assertEqual(result["status"], "probe_error")
                    direct = result["direct_backend_observation"]
                    self.assertEqual(direct["final_observed"]["status"], "probe_error")
                    self.assertIsNone(direct["selected"])

    def test_pending_poll_survives_later_success(self):
        capture = polling_capture([1, 1])
        capture["facts"]["transactions"][0]["terminal"] = "pending"
        result = diagnose(capture)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["direct_backend_observation"]["status"], "incomplete")
        self.assertIsNone(result["direct_backend_observation"]["selected"])

    def test_dns_request_gaps_block_overall_zero(self):
        for request in [None, {}, {"domains": [], "stamp": 0}, {"domains": ["unrelated.example"], "stamp": 0},
                        {"domains": [_DOMAIN]}, {"domains": [_DOMAIN], "stamp": False}]:
            with self.subTest(request=request):
                capture = capture_stub()
                capture["facts"]["transactions"][0]["request_fields"] = request
                result = diagnose(capture)
                self.assertEqual(result["status"], "incomplete")
                self.assertIn("dns_request_evidence_incomplete", result["reasons"])

    def test_only_exact_reviewed_dns_and_submit_routes_qualify(self):
        for index in [0, 1]:
            for field, value in [("origin", "https://unrelated.example"), ("path", "/not-dns"),
                                 ("query_names", ["token"]), ("method", "GET")]:
                with self.subTest(index=index, field=field):
                    capture = capture_stub()
                    transaction = capture["facts"]["transactions"][index]
                    if field == "method":
                        transaction[field] = value
                    else:
                        transaction["url"][field] = value
                    result = diagnose(capture)
                    self.assertEqual(result["status"], "unknown")
                    self.assertIn("transaction_route_mismatch", result["reasons"])
                    self.assertNotIn("unrelated.example", records.canonical(result).decode())
                    if index == 0:
                        self.assertEqual(result["direct_backend_observation"]["status"], "incomplete")

    def test_missing_subject_target_binding_blocks_round_claim(self):
        for key in ["target_id", "session_id"]:
            with self.subTest(key=key):
                capture = capture_stub()
                capture["subject"].pop(key)
                result = diagnose(capture)
                self.assertEqual(result["status"], "unknown")
                self.assertIn("subject_target_binding_missing", result["reasons"])

    def test_projection_truncation_cannot_be_laundered_by_reprojection(self):
        capture = capture_stub()
        capture["facts"]["client_submission"]["locale"]["fonts_cn"] = ["PingFang SC"] * 33
        capture["facts"]["transactions"][1]["request_fields"] = copy.deepcopy(capture["facts"]["client_submission"])
        capture["facts"]["client_submission"] = records.project_submission(capture["facts"]["client_submission"])
        capture["facts"]["transactions"][1]["request_fields"] = records.project_submission(capture["facts"]["transactions"][1]["request_fields"])
        result = diagnose(capture)
        self.assertEqual(result["status"], "incomplete")
        self.assertIn("projection_truncated", result["reasons"])

    def test_metadata_only_failures_do_not_replace_complete_dns_scope(self):
        for kind in ["multigeo", "dns_trigger"]:
            with self.subTest(kind=kind):
                capture = capture_stub()
                capture["facts"]["transactions"].append(dns_transaction(
                    0, sequence=3, kind=kind, terminal="failed", body_state="not_requested",
                    response_status=503, response_fields=None, request_fields=None))
                result = diagnose(capture)
                self.assertEqual(result["status"], "backend_zero")
                self.assertTrue(result["complete"])
                self.assertEqual(result["optional_probe_issues"][0]["kind"], kind)
                self.assertEqual(result["optional_probe_issues"][0]["issue"], "request_failed")
                self.assertIn("not_full_network_acceptance", result["limits"])

    def test_metadata_only_body_not_requested_is_intentional(self):
        capture = capture_stub()
        capture["facts"]["transactions"].append(dns_transaction(
            0, sequence=3, kind="multigeo", body_state="not_requested", response_fields=None, request_fields=None))
        result = diagnose(capture)
        self.assertEqual(result["status"], "backend_zero")
        self.assertEqual(result["optional_probe_issues"], [])

    def test_optional_ipinfo_engine_failures_remain_separate(self):
        for kind in ["ipinfo", "engine"]:
            with self.subTest(kind=kind):
                capture = capture_stub(2)
                capture["facts"]["transactions"].append(dns_transaction(
                    0, sequence=3, kind=kind, body_state="invalid_json", response_fields=None))
                result = diagnose(capture)
                self.assertEqual(result["status"], "backend_positive")
                self.assertTrue(result["complete"])
                self.assertEqual(result["optional_probe_issues"][0]["issue"], "invalid_json")

    def test_caller_scope_metadata_cannot_downgrade_dns_requirements(self):
        capture = capture_stub()
        capture["observation"]["required_transaction_kinds"] = []
        capture["observation"]["metadata_only_kinds"] = ["dnsleak", "submit"]
        capture["facts"]["transactions"][0]["body_state"] = "not_requested"
        self.assertEqual(diagnose(capture)["status"], "incomplete")

    def test_submit_failure_history_survives_later_success(self):
        capture = capture_stub(1)
        failed = copy.deepcopy(capture["facts"]["transactions"][1])
        failed.update(transaction_id="tx-000003", request_id="request-3", sequence=3,
                      terminal="failed", response_fields=None, body_state="unavailable")
        capture["facts"]["transactions"].insert(0, failed)
        result = diagnose(capture)
        self.assertEqual(result["status"], "incomplete")
        self.assertIn("submit_history_incomplete_or_error", result["reasons"])
        self.assertEqual(len(result["client_submission_history"]), 2)

    def test_prior_submission_does_not_replace_selected_current_comparison(self):
        capture = capture_stub(2, submitted=0)
        healthy = copy.deepcopy(capture["facts"]["transactions"][1])
        healthy.update(transaction_id="tx-000003", request_id="request-3", sequence=3)
        healthy["request_fields"]["dns"]["resolver_count"] = 2
        capture["facts"]["transactions"].append(healthy)
        capture["facts"]["client_submission"] = copy.deepcopy(healthy["request_fields"])
        capture["facts"]["client_submission_transaction_id"] = "tx-000003"
        capture["site_result"]["transaction_id"] = "tx-000003"
        result = diagnose(capture)
        self.assertEqual(result["status"], "backend_positive")
        self.assertEqual(result["client_submission_comparison"]["status"], "consistent")
        self.assertEqual(result["client_submission_comparison"]["resolver_count"], 2)
        self.assertNotIn("divergence_transaction_ids", result["client_submission_comparison"])
        self.assertEqual([row["resolver_count"] for row in result["client_submission_history"]], [0, 2])
        self.assertEqual(result["facts"]["client_submission"]["dns"]["resolver_count"], 2)

    def test_ambiguous_count_alias_does_not_use_boolean_as_zero(self):
        capture = capture_stub()
        capture["facts"]["client_submission"]["dns"]["count"] = False
        capture["facts"]["transactions"][1]["request_fields"]["dns"]["count"] = False
        result = diagnose(capture)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["client_submission_comparison"]["status"], "unknown")

    def test_positive_to_submission_zero_is_divergence_not_cause(self):
        result = diagnose(capture_stub(3, submitted=0))
        self.assertEqual(result["status"], "client_submission_divergence")
        self.assertEqual(result["client_submission_comparison"]["resolver_count"], 0)
        self.assertEqual(result["client_submission_comparison"]["reason"], "conversion_fallback_or_assembly_possible_cause_unknown")
        self.assertEqual(result["direct_backend_observation"]["status"], "backend_positive")

    def test_nonzero_submission_and_blackhole_finding_is_server_divergence(self):
        result = diagnose(capture_stub(3, finding_fail=True))
        self.assertEqual(result["status"], "server_finding_divergence")
        self.assertEqual(result["server_finding_comparison"]["reason"], "server_rules_unknown")
        self.assertEqual(result["facts"]["client_submission"]["dns"]["resolver_count"], 3)

    def test_incomplete_round_never_uses_cross_layer_divergence(self):
        capture = capture_stub(3, submitted=0)
        capture["observation"]["truncated"] = True
        result = diagnose(capture)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["client_submission_comparison"]["status"], "unknown")

    def test_site_result_does_not_overwrite_client_submission(self):
        capture = capture_stub(3, submitted=0)
        capture["site_result"]["response"]["dns"] = {"resolver_count": 3}
        capture["facts"]["transactions"][1]["response_fields"]["dns"] = {"resolver_count": 3}
        result = diagnose(capture)
        self.assertEqual(result["status"], "client_submission_divergence")
        self.assertEqual(result["facts"]["client_submission"]["dns"]["resolver_count"], 0)
        self.assertEqual(result["facts"]["transactions"][1]["request_fields"]["dns"]["resolver_count"], 0)

    def test_submission_wrong_id_scope_or_payload_is_unknown(self):
        for mode in ["id", "scope", "payload", "missing_id"]:
            with self.subTest(mode=mode):
                capture = capture_stub(1)
                if mode == "id":
                    capture["facts"]["client_submission_transaction_id"] = "tx-999999"
                elif mode == "scope":
                    capture["facts"]["client_submission_scope_id"] = "run-another-page"
                elif mode == "payload":
                    capture["facts"]["client_submission"]["dns"]["resolver_count"] = 0
                else:
                    capture["facts"].pop("client_submission_transaction_id")
                result = diagnose(capture)
                self.assertEqual(result["client_submission_comparison"]["status"], "unknown")
                self.assertIn(result["status"], {"unknown", "incomplete"})

    def test_site_result_wrong_id_scope_or_payload_is_unknown(self):
        for mode in ["id", "scope", "payload"]:
            with self.subTest(mode=mode):
                capture = capture_stub(1)
                if mode == "id":
                    capture["site_result"]["transaction_id"] = "tx-000001"
                elif mode == "scope":
                    capture["site_result"]["scope_id"] = "run-another-page"
                else:
                    capture["site_result"]["response"]["score"] = 1
                result = diagnose(capture)
                self.assertEqual(result["server_finding_comparison"]["status"], "unknown")
                self.assertIn(result["status"], {"unknown", "incomplete"})

    def test_no_submission_gate_reasons_stay_unknown(self):
        for gate, reason in [("captcha", "submission_not_observed_captcha_gate"),
                             ("job_pending", "submission_not_observed_job_pending"),
                             ("unknown", "submission_not_observed_capture_unknown")]:
            with self.subTest(gate=gate):
                capture = without_submission(capture_stub())
                capture["observation"]["submission_gate"] = gate
                result = diagnose(capture)
                self.assertEqual(result["client_submission_comparison"]["status"], "unknown")
                self.assertEqual(result["client_submission_comparison"]["reason"], reason)
                self.assertEqual(result["status"], "incomplete")
                self.assertNotEqual(result["status"], "probe_error")

    def test_captcha_placeholder_is_not_http_or_dns_evidence(self):
        capture = without_submission(capture_stub())
        capture["facts"]["transactions"] = []
        capture["facts"]["client_submission"] = {"net": {"needCaptcha": True}}
        result = diagnose(capture)
        self.assertEqual(result["direct_backend_observation"]["status"], "unavailable")
        self.assertIn(result["status"], {"unknown", "incomplete"})
        self.assertNotEqual(result["status"], "probe_error")

    def test_initial_score_100_and_progress_done_is_not_pass(self):
        capture = without_submission(capture_stub())
        capture["facts"]["transactions"] = []
        capture["facts"]["page_snapshots"] = [{"score": 100, "progressDone": True}]
        result = diagnose(capture)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["direct_backend_observation"]["status"], "unavailable")
        self.assertFalse(result["complete"])
        self.assertNotIn("pass", result.values())

    def test_missing_ambiguous_or_invalid_finding_does_not_pass(self):
        for finding in [[], [{"id": "xc.dns_blackhole", "fail": "false"}],
                        [{"id": "xc.dns_blackhole", "fail": False}] * 2,
                        [{"id": "xc.dns_blackhole"}]]:
            with self.subTest(finding=finding):
                capture = capture_stub()
                capture["site_result"]["response"]["findings"] = copy.deepcopy(finding)
                capture["facts"]["transactions"][1]["response_fields"]["findings"] = copy.deepcopy(finding)
                result = diagnose(capture)
                self.assertEqual(result["status"], "incomplete")
                self.assertEqual(result["server_finding_comparison"]["status"], "unknown")

    def test_invalid_submission_count_cannot_support_server_divergence(self):
        for count in [None, False, True, "0", "1", -1]:
            with self.subTest(count=count):
                result = diagnose(capture_stub(1, submitted=count, finding_fail=True))
                self.assertEqual(result["status"], "incomplete")
                self.assertEqual(result["client_submission_comparison"]["status"], "unknown")
                self.assertNotEqual(result["server_finding_comparison"]["status"], "server_finding_divergence")

    def test_schema_and_subject_markers_fail_closed(self):
        for field, value in [("schema_version", True), ("schema_version", 2), ("synthetic", None),
                             ("contract_id", "unreviewed")]:
            with self.subTest(field=field):
                capture = capture_stub()
                capture[field] = value
                self.assertEqual(diagnose(capture)["status"], "unknown")
        capture = capture_stub()
        capture["subject"]["kind"] = "other"
        self.assertEqual(diagnose(capture)["status"], "unknown")

    def test_malformed_enums_are_unknown_not_exceptions(self):
        for field in ["kind", "body_state", "terminal", "schema_state", "error_kind"]:
            for value in [[], {}, False, 1]:
                with self.subTest(field=field, value=value):
                    capture = capture_stub()
                    capture["facts"]["transactions"][0][field] = value
                    result = diagnose(capture)
                    self.assertIn(result["status"], {"unknown", "incomplete"})
        capture = capture_stub()
        capture["subject"]["kind"] = []
        capture["site_result"]["state"] = {}
        self.assertEqual(diagnose(capture)["status"], "unknown")

    def test_nonfinite_capture_rejected_before_diagnosis(self):
        capture = capture_stub()
        capture["facts"]["transactions"][0]["response_fields"]["resolver_count"] = math.nan
        with self.assertRaises(records.ValidationError) as error:
            diagnose(capture)
        self.assertEqual(error.exception.code, "json_nonfinite_number")

    def test_diagnosis_is_pure_and_does_not_mutate_input(self):
        capture = capture_stub(2, submitted=0)
        contract = contract_stub()
        original_capture = copy.deepcopy(capture)
        original_contract = copy.deepcopy(contract)
        first = records.diagnose(capture, contract)
        second = records.diagnose(capture, contract)
        self.assertEqual(first, second)
        self.assertEqual(capture, original_capture)
        self.assertEqual(contract, original_contract)

    def test_report_drops_console_page_and_metadata_payloads(self):
        capture = capture_stub()
        capture["facts"]["console"] = [{"message": "COOKIE-SECRET"}]
        capture["facts"]["page_snapshots"] = [{"html": "<input value='TOKEN-SECRET'>"}]
        capture["subject"]["name"] = "PRIVATE-DEVICE-NAME"
        capture["observation"]["error"] = "PRIVATE-ERROR-DETAIL"
        capture["facts"]["transactions"][0]["error_text"] = "PRIVATE-NETWORK-ERROR"
        result = diagnose(capture)
        output = records.canonical(result).decode()
        for forbidden in ["COOKIE-SECRET", "TOKEN-SECRET", "PRIVATE-DEVICE-NAME", "PRIVATE-ERROR-DETAIL", "PRIVATE-NETWORK-ERROR"]:
            self.assertNotIn(forbidden, output)
        self.assertEqual(result["facts"]["console_event_count"], 1)
        self.assertEqual(result["facts"]["page_snapshot_count"], 1)

    def test_transaction_inventory_overflow_cannot_hide_last_failure(self):
        capture = capture_stub()
        capture["facts"]["transactions"].extend(dns_transaction(0, sequence=index)
                                               for index in range(3, records.MAX_TRANSACTIONS + 2))
        capture["facts"]["transactions"][-1]["terminal"] = "failed"
        result = diagnose(capture)
        self.assertEqual(result["status"], "incomplete")
        self.assertIn("transaction_inventory_truncated", result["reasons"])
        self.assertFalse(result["complete"])


class RenderingAndOfflineTests(unittest.TestCase):
    def test_markdown_keeps_raw_count_types_distinct(self):
        for value, expected in [(0, "0"), (None, "null"), (False, "false"), ("0", '"0"')]:
            with self.subTest(value=value):
                capture = capture_stub()
                capture["facts"]["transactions"][0]["response_fields"]["resolver_count"] = value
                markdown = records.render_markdown(diagnose(capture))
                self.assertIn("| " + expected + " |", markdown)
        capture = capture_stub()
        del capture["facts"]["transactions"][0]["response_fields"]["resolver_count"]
        self.assertIn("[missing]", records.render_markdown(diagnose(capture)))

    def test_markdown_ignores_untrusted_markup(self):
        report = diagnose(capture_stub())
        report["status"] = "<script>SECRET</script>"
        report["reasons"] = ["[private](https://secret.example)"]
        report["direct_backend_observation"]["transactions"][0]["transaction_id"] = "| SECRET |"
        report["direct_backend_observation"]["transactions"][0]["resolver_count"] = "<img src=SECRET>"
        output = records.render_markdown(report)
        self.assertNotIn("SECRET", output)
        self.assertNotIn("https://", output)
        self.assertIn("status: `unknown`", output)
        self.assertIn("backend_count_is_not_vpn_verdict", output)

    def test_markdown_malformed_types_are_bounded(self):
        output = records.render_markdown({"status": {}, "direct_backend_observation": {"transactions": [None, {"status": [], "resolver_count": {"_redacted": True, "_type": []}}]},
                                          "client_submission_comparison": {"status": []}})
        self.assertIn("unknown", output)
        self.assertIn("[redacted:unknown]", output)
        with self.assertRaises(records.ValidationError):
            records.render_markdown([])

    def test_only_stdlib_safe_imports_and_no_implicit_effects(self):
        source = Path(__file__).with_name("records.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        roots = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                roots.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                roots.add(node.module.split(".")[0])
        self.assertEqual(roots, {"__future__", "ipaddress", "json", "math", "re", "typing"})
        denied = {"socket", "subprocess", "websockets", "pmb3", "pymobiledevice3", "urllib", "http", "asyncio"}
        imported = []
        original_import = builtins.__import__

        def guarded_import(name, *args, **kwargs):
            imported.append(name)
            if name.split(".")[0] in denied:
                self.fail("forbidden import: " + name)
            return original_import(name, *args, **kwargs)

        guarded_builtins = dict(vars(builtins))
        guarded_builtins["__import__"] = guarded_import
        guarded_builtins["open"] = lambda *args, **kwargs: self.fail("unexpected file I/O")
        namespace = {"__builtins__": guarded_builtins, "__name__": "synthetic_records_import"}
        exec(compile(source, "records.py", "exec"), namespace)
        self.assertFalse(denied & {name.split(".")[0] for name in imported})
        self.assertEqual(namespace["decode"]('{"synthetic":true}'), {"synthetic": True})
        self.assertEqual(namespace["project_dns_response"](dns_response(0)), dns_response(0))

    def test_synthetic_helpers_never_load_external_contract(self):
        capture = capture_stub()
        self.assertIs(capture["synthetic"], True)
        self.assertEqual(contract_stub()["contract_id"], records.CONTRACT_ID)
        result = records.decode(records.canonical(capture))
        self.assertEqual(diagnose(result)["status"], "backend_zero")


if __name__ == "__main__":
    unittest.main()
