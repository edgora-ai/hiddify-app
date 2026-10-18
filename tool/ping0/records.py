"""Bounded JSON, privacy projections, and evidence-only Ping0 diagnostics.

This module performs no I/O. Missing fields stay missing; redaction markers are
never numbers. Capture producers own event timing, scope assignment, and cleanup.
"""

from __future__ import annotations

import ipaddress
import json
import math
import re
from typing import Any

CONTRACT_ID = "ping0-env-2026-10-18-cb9bbcc5"
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_JSON_DEPTH = 32
MAX_JSON_NODES = 50_000
MAX_STRING_LENGTH = 65_536
MAX_DNS_ITEMS = 128
MAX_DOMAINS = 50
MAX_TRANSACTIONS = 256
MAX_FINDINGS = 64
MAX_FINDING_SCAN = 512
MAX_SAFE_COUNT = (1 << 53) - 1

EXPECTED_SOURCE_PINS = {
    "https://cdn.ping0.cc/js/envdetect/main.js":
        "ae98c00553ef102d723da27811c78e7290f241f9ffcaba1d96f2f85e2ace7665",
    "https://cdn.ping0.cc/js/envdetect/probes/index.js":
        "cb9bbcc5030921ac1092f513e8760cc7dd92fdb56a6ff93ee150a470b7e313c4",
    "https://cdn.ping0.cc/js/envdetect/browser-detect.client.js":
        "ba81e5199246133c1789a5e20f81b033e3932575e9b3185caaed43f84e9508e6",
}
FINDING_IDS = frozenset({
    "xc.ip_tz", "xc.ip_lang", "xc.ip_fonts_cn", "xc.ua_webgl",
    "xc.ua_engine_browser", "xc.ua_engine_version", "xc.ipv4_ipv6_country",
    "xc.rtc_http_ip", "xc.tz_intl_tz", "xc.dns_ip_country", "xc.dns_blackhole",
    "xc.voices_country", "xc.proxy_headers", "xc.multi_geo_ip",
    "xc.gpu_cpu_mismatch", "xc.webgl_driver_leak", "xc.ua_header_match",
    "xc.sec_ch_ua_match",
})
_DOMAIN = re.compile(r"r-[0-9]{13}-[0-9]{1,16}\.d\.ping0\.cc\Z")
_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,95}\Z")
_TX_ID = re.compile(r"tx-[0-9]{6,12}\Z")
_NUMBER_TEXT = re.compile(r"[+-]?(?:[0-9]{1,24})(?:\.[0-9]{1,12})?\Z")
_SECRET_TEXT = re.compile(r"cookie|authorization|bearer|token|secret|password|credential|session[_-]?id", re.IGNORECASE)
_LANGUAGE = re.compile(r"[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}\Z")
_TIMEZONE = re.compile(r"[A-Za-z_+-]{1,24}(?:/[A-Za-z0-9_+-]{1,32}){1,2}\Z")
_COUNTRY_CODES = re.compile(r"[A-Za-z]{2}\Z")
_COUNTRY_NAMES = frozenset({
    "United States", "United States of America", "United Kingdom", "China",
    "Hong Kong", "Taiwan", "Macao", "Macau", "Japan", "South Korea", "Korea",
    "Singapore", "Australia", "New Zealand", "Canada", "Germany", "France",
    "Netherlands", "Belgium", "Switzerland", "Austria", "Ireland", "Italy",
    "Spain", "Portugal", "Sweden", "Norway", "Denmark", "Finland", "Iceland",
    "Poland", "Czechia", "Romania", "Ukraine", "Russia", "Turkey", "Türkiye",
    "India", "Indonesia", "Malaysia", "Thailand", "Vietnam", "Philippines",
    "Brazil", "Mexico", "Argentina", "Chile", "Colombia", "South Africa",
    "Israel", "United Arab Emirates", "Saudi Arabia", "Iran", "Egypt",
    "中国", "美国", "英国", "香港", "台湾", "澳门", "日本", "韩国", "新加坡",
    "加拿大", "澳大利亚", "德国", "法国", "荷兰", "俄罗斯", "印度",
})
_FONTS = frozenset({
    "PingFang SC", "PingFang TC", "PingFang HK", "Heiti SC", "Heiti TC",
    "Songti SC", "Songti TC", "STHeiti", "STSong", "STKaiti", "STFangsong",
    "Microsoft YaHei", "Microsoft JhengHei", "SimSun", "SimHei", "KaiTi",
    "FangSong", "NSimSun", "Noto Sans CJK SC", "Noto Sans CJK TC",
    "Noto Serif CJK SC", "Noto Serif CJK TC", "WenQuanYi Micro Hei",
    "Arial Unicode MS", "苹方", "宋体", "黑体", "楷体", "仿宋", "微软雅黑",
})
_ENUMS = frozenset({
    "unknown", "unavailable", "pending", "captured", "finished", "failed",
    "disabled", "enabled", "present", "absent", "matched", "mismatch",
    "low", "medium", "high", "critical", "info", "warning", "error",
    "pass", "warn", "fail", "good", "poor", "excellent", "safe", "risk",
    "danger", "none", "public", "private", "dns_blackhole", "A", "B", "C",
    "D", "F", "ipv4", "ipv6", "mdns",
})
_ERROR_KINDS = frozenset({
    "request_failed", "http_error", "invalid_json", "body_unavailable",
    "body_too_large", "protocol_error", "network_error", "cancelled",
    "blocked", "timeout", "capture_error", "decode_error",
})
_KINDS = frozenset({"dnsleak", "submit", "ipinfo", "engine", "multigeo", "dns_trigger", "script"})
_OPTIONAL_KINDS = frozenset({"ipinfo", "engine", "multigeo", "dns_trigger"})
_STATUSES = frozenset({
    "backend_zero", "backend_positive", "probe_error", "mixed", "unknown",
    "incomplete", "unavailable", "client_submission_divergence",
    "server_finding_divergence", "consistent", "not_observed", "captured",
})
_REASON_CODES = frozenset({
    "contract_unreviewed", "contract_source_pins_missing", "source_digest_evidence_missing",
    "source_digest_evidence_truncated", "source_digest_mismatch", "capture_schema_unreviewed",
    "synthetic_marker_missing", "subject_kind_unknown", "subject_target_binding_missing",
    "capture_scope_missing_or_mismatched", "observation_not_armed", "source_not_matched",
    "capture_end_incomplete_or_unknown", "deadline_reached_or_unknown", "capture_truncated_or_unknown",
    "late_events_or_unknown", "cleanup_incomplete", "transaction_inventory_missing",
    "transaction_inventory_truncated", "invalid_transaction", "transaction_kind_unknown",
    "transaction_route_mismatch", "transaction_identity_missing", "transaction_scope_mismatch",
    "transaction_target_mismatch", "late_transaction_or_unknown", "dns_request_evidence_incomplete",
    "projection_truncated", "submit_history_incomplete_or_error", "submit_body_evidence_missing",
    "transaction_identity_collision", "dns_transaction_not_observed", "dns_polling_counts_disagree",
    "dns_response_evidence_incomplete", "dns_error_evidence_retained", "submission_history_count_missing_or_invalid",
    "submission_not_observed_captcha_gate", "submission_not_observed_job_pending",
    "submission_not_observed_capture_unknown", "submission_association_missing_or_mismatched",
    "submission_evidence_conflict", "submission_transaction_incomplete", "round_evidence_incomplete",
    "submission_count_missing_or_invalid", "conversion_fallback_or_assembly_possible_cause_unknown",
    "count_differs_assembly_mapping_unknown", "site_result_not_observed",
    "site_result_association_missing_or_mismatched", "site_result_evidence_conflict",
    "dns_finding_missing_or_ambiguous", "server_rules_unknown", "request_failed", "http_error",
    "invalid_json", "dns_route_unreviewed", "dns_scope_or_identity_unbound",
    "transaction_error_metadata_unreviewed_or_conflicting", "dns_polling_request_identity_mismatch",
    "dns_poll_after_selected_submission",
})
_LOCALE_FIELDS = frozenset({
    "language", "languages", "locale", "intl_locale", "intl_timezone",
    "timezone", "time_zone", "tz", "tz_offset", "timezone_offset", "region",
    "fonts_cn", "chinese_fonts", "chinese_font_count", "zh_font_count",
    "cjk_font_count", "chinese_font", "cjk",
})
_NET_IP_FIELDS = frozenset({"ip", "ip_v6", "public_ip", "public_ip_v6"})
_NET_FLAGS = frozenset({
    "needCaptcha", "need_captcha", "captcha_required", "has_ipv4", "has_ipv6",
    "ipv4_supported", "ipv6_supported", "ipv4_ok", "ipv6_ok", "tcp", "udp",
    "http", "https", "http3", "quic", "available", "supported", "enabled",
})
_EVIDENCE_KEYS = frozenset({
    "actual", "expected", "observed", "submitted", "backend", "value",
    "evidence", "count", "resolver_count", "foreign_count", "items", "ip",
    "cc", "country_code", "country", "foreign", "public_ip", "public_ip_v6",
    "disabled", "mdns", "mdns_present", "dns", "net", "rtc", "locale",
    "ipv4", "ipv6", "asn", "ASN", "risk", "needCaptcha", "reason", "state",
    "status", "mismatch", "present",
}) | _LOCALE_FIELDS


class ValidationError(ValueError):
    """A fixed error code, never an excerpt of an input or exception message."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


def _validate_json(value: Any) -> None:
    stack = [(value, 0)]
    nodes = 0
    while stack:
        item, depth = stack.pop()
        nodes += 1
        if nodes > MAX_JSON_NODES or depth > MAX_JSON_DEPTH:
            raise ValidationError("json_structure_limit")
        if item is None or type(item) is bool:
            continue
        if type(item) is int:
            if item.bit_length() > 256:
                raise ValidationError("json_number_limit")
        elif type(item) is float:
            if not math.isfinite(item):
                raise ValidationError("json_nonfinite_number")
        elif type(item) is str:
            if len(item) > MAX_STRING_LENGTH:
                raise ValidationError("json_string_limit")
            try:
                item.encode("utf-8", "strict")
            except UnicodeError:
                raise ValidationError("json_invalid_unicode") from None
        elif type(item) is list:
            if len(item) > MAX_JSON_NODES:
                raise ValidationError("json_structure_limit")
            stack.extend((child, depth + 1) for child in item)
        elif type(item) is dict:
            if len(item) > MAX_JSON_NODES:
                raise ValidationError("json_structure_limit")
            for key, child in item.items():
                if type(key) is not str:
                    raise ValidationError("json_key_type")
                stack.append((key, depth + 1))
                stack.append((child, depth + 1))
        else:
            raise ValidationError("json_value_type")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError("json_duplicate_key")
        result[key] = value
    return result


def _reject_constant(_value: str) -> Any:
    raise ValidationError("json_nonfinite_number")


def _parse_integer(value: str) -> int:
    if len(value.lstrip("-")) > 77:
        raise ValidationError("json_number_limit")
    return int(value)


def decode(data: bytes | str) -> Any:
    """Decode strict UTF-8 JSON within explicit byte, structure, and scalar limits."""
    if type(data) is bytes:
        if len(data) > MAX_JSON_BYTES:
            raise ValidationError("json_byte_limit")
        try:
            text = data.decode("utf-8", "strict")
        except UnicodeError:
            raise ValidationError("json_invalid_unicode") from None
    elif type(data) is str:
        if len(data) > MAX_JSON_BYTES:
            raise ValidationError("json_byte_limit")
        try:
            size = len(data.encode("utf-8", "strict"))
        except UnicodeError:
            raise ValidationError("json_invalid_unicode") from None
        if size > MAX_JSON_BYTES:
            raise ValidationError("json_byte_limit")
        text = data
    else:
        raise ValidationError("json_input_type")
    try:
        value = json.loads(text, object_pairs_hook=_unique_object,
                           parse_constant=_reject_constant, parse_int=_parse_integer)
    except ValidationError:
        raise
    except (ValueError, RecursionError, OverflowError):
        raise ValidationError("json_syntax") from None
    _validate_json(value)
    return value


def canonical(value: Any) -> bytes:
    """Stable UTF-8 JSON plus one newline; this is serialization, not redaction."""
    _validate_json(value)
    try:
        result = (json.dumps(value, ensure_ascii=False, sort_keys=True,
                             separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    except (ValueError, RecursionError, OverflowError):
        raise ValidationError("json_encoding") from None
    if len(result) > MAX_JSON_BYTES:
        raise ValidationError("json_byte_limit")
    return result


def _type(value: Any) -> str:
    return {type(None): "null", bool: "boolean", int: "number", float: "number",
            str: "string", list: "array", dict: "object"}.get(type(value), "unsupported")


def _marker(value: Any, reason: str = "unretained_value") -> dict:
    if (type(value) is dict and value.get("_redacted") is True
            and _enum(value.get("_type"), {"null", "boolean", "number", "string", "array", "object", "unsupported"}) is not None):
        return {"_redacted": True, "_type": value["_type"],
                "_reason": _enum(value.get("_reason"), {"unretained_value", "invalid_ip", "non_public_ip"}, "unretained_value")}
    return {"_redacted": True, "_type": _type(value), "_reason": reason}


def _presence(value: Any) -> dict:
    if (type(value) is dict and value.get("present") is True
            and _enum(value.get("_type"), {"null", "boolean", "number", "string", "array", "object", "unsupported"}) is not None):
        return {"present": True, "_type": value["_type"]}
    return {"present": True, "_type": _type(value)}


def _projection_truncated(value: Any) -> bool:
    stack = [value]
    remaining = MAX_JSON_NODES
    while stack and remaining:
        item = stack.pop()
        remaining -= 1
        if type(item) is dict:
            if item.get("_projection_truncated") is True:
                return True
            stack.extend(item.values())
        elif type(item) is list:
            stack.extend(item)
    return bool(stack)


def _sensitive_key(key: Any) -> bool:
    if type(key) is not str:
        return True
    name = re.sub(r"[^a-z0-9]", "", key.lower())
    if name in {"sid", "sessionid", "k", "n", "p", "b", "apikey", "xapikey", "privatekey",
                "accesskey", "key", "jwt", "auth", "authentication"}:
        return True
    return (any(term in name for term in ("cookie", "authorization", "token", "secret", "credential", "password", "passwd"))
            or ("captcha" in name and name not in {"needcaptcha", "captcharequired"}))


def _secret_values(value: Any) -> set[Any]:
    strings: set[Any] = set()
    stack = [(value, False, 0)]
    remaining = MAX_JSON_NODES
    while stack and remaining:
        item, sensitive, depth = stack.pop()
        remaining -= 1
        if depth > MAX_JSON_DEPTH:
            continue
        if type(item) is str and sensitive and item:
            strings.add(item)
        elif sensitive and (type(item) is int or type(item) is float and math.isfinite(item)):
            strings.add(item)
        elif type(item) is dict:
            for index, (key, child) in enumerate(item.items()):
                if index >= MAX_JSON_NODES:
                    break
                stack.append((child, sensitive or _sensitive_key(key), depth + 1))
        elif type(item) is list:
            stack.extend((child, sensitive, depth + 1) for child in item[:MAX_JSON_NODES])
    return strings


def _sensitive_text(value: str, secrets: set[Any]) -> bool:
    return value in secrets or _SECRET_TEXT.search(value) is not None


def _numeric(value: Any) -> bool:
    return (type(value) in (int, float) and 0 <= value <= MAX_SAFE_COUNT
            and math.isfinite(value) and int(value) == value)


def _enum(value: Any, allowed: frozenset | set, default: Any = None) -> Any:
    return value if type(value) is str and value in allowed else default


def _scalar(value: Any, secrets: set[Any]) -> Any:
    if value is None or type(value) is bool:
        return value
    if type(value) in (int, float) and value in secrets:
        return _marker(value)
    if type(value) is int and value.bit_length() <= 256:
        return value
    if type(value) is float and math.isfinite(value):
        return value
    if (type(value) is str and len(value) <= 32 and not _sensitive_text(value, secrets)
            and (value == "" or _NUMBER_TEXT.fullmatch(value))):
        return value
    return _marker(value)


def _public_ip(value: Any, secrets: set[Any]) -> Any:
    if value is None or type(value) is bool:
        return value
    if type(value) is not str or len(value) > 64 or _sensitive_text(value, secrets) or "%" in value:
        return _marker(value)
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return _marker(value, "invalid_ip")
    if not address.is_global or any((address.is_private, address.is_reserved,
                                    address.is_multicast, address.is_loopback,
                                    address.is_link_local, address.is_unspecified)):
        return _marker(value, "non_public_ip")
    return str(address)


def _country(value: Any, secrets: set[Any], code_only: bool = False) -> Any:
    if value is None or type(value) is bool:
        return value
    if (type(value) is str and not _sensitive_text(value, secrets) and len(value) <= 64
            and (_COUNTRY_CODES.fullmatch(value) or (not code_only and value in _COUNTRY_NAMES))):
        return value
    return _marker(value)


def _boolean(value: Any) -> Any:
    return value if value is None or type(value) is bool else _marker(value)


def _dns_response(value: Any, secrets: set[Any]) -> dict:
    if type(value) is not dict or value.get("_redacted") is True:
        return _marker(value)
    result = {}
    if "resolver_count" in value:
        result["resolver_count"] = _scalar(value["resolver_count"], secrets)
    if "items" in value:
        items = value["items"]
        if type(items) is not list:
            result["items"] = _scalar(items, secrets)
        else:
            projected = []
            for item in items[:MAX_DNS_ITEMS]:
                if type(item) is not dict:
                    projected.append(_marker(item))
                    continue
                row = {}
                for key in ("ip", "cc", "country_code", "country", "foreign"):
                    if key not in item:
                        continue
                    raw = item[key]
                    row[key] = (_public_ip(raw, secrets) if key == "ip" else
                                _boolean(raw) if key == "foreign" else
                                _country(raw, secrets, key != "country"))
                projected.append(row)
            result["items"] = projected
            if len(items) > MAX_DNS_ITEMS:
                result["_projection_truncated"] = True
    if value.get("_projection_truncated") is True:
        result["_projection_truncated"] = True
    return result


def project_dns_response(value: Any) -> dict:
    return _dns_response(value, _secret_values(value))


def project_dns_request(value: Any) -> dict:
    if type(value) is not dict or value.get("_redacted") is True:
        return _marker(value)
    secrets = _secret_values(value)
    result = {}
    if "domains" in value:
        domains = value["domains"]
        if type(domains) is list:
            result["domains"] = [domain if (type(domain) is str and domain not in secrets
                                            and _DOMAIN.fullmatch(domain)) else _marker(domain)
                                 for domain in domains[:MAX_DOMAINS]]
            if len(domains) > MAX_DOMAINS:
                result["_projection_truncated"] = True
        else:
            result["domains"] = _marker(domains)
    if "stamp" in value:
        stamp = value["stamp"]
        if (type(stamp) is str and stamp not in secrets and re.fullmatch(r"[0-9]{1,24}", stamp)):
            result["stamp"] = stamp
        else:
            result["stamp"] = _scalar(stamp, secrets) if type(stamp) is not str else _marker(stamp)
    if value.get("_projection_truncated") is True:
        result["_projection_truncated"] = True
    return result


def dns_schema_state(raw_or_projected: Any) -> str:
    """Validate the observed numeric count and items shape, not count/length equality."""
    value = raw_or_projected
    if (type(value) is not dict or not _numeric(value.get("resolver_count"))
            or type(value.get("items")) is not list or value.get("_projection_truncated") is True
            or len(value["items"]) > MAX_DNS_ITEMS):
        return "invalid"
    for item in value["items"]:
        if type(item) is not dict or type(item.get("ip")) is not str:
            return "invalid"
        if type(_public_ip(item["ip"], set())) is not str:
            return "invalid"
        for field in ("cc", "country_code", "country"):
            if field not in item or item[field] is None or type(item[field]) is str:
                continue
            if not (type(item[field]) is dict and item[field].get("_redacted") is True
                    and item[field].get("_type") == "string"):
                return "invalid"
        if "foreign" in item and type(item["foreign"]) is not bool:
            return "invalid"
    return "valid"


def _locale_field(key: str, value: Any, secrets: set[Any], depth: int = 0) -> Any:
    if depth > 6:
        return _marker(value)
    if type(value) is dict and value.get("_projection_truncated") is True:
        retained = _locale_field(key, value.get("items"), secrets, depth + 1)
        return {"_projection_truncated": True, "items": retained}
    if type(value) is dict and value.get("_redacted") is True:
        return _marker(value)
    if key in {"tz_offset", "timezone_offset", "chinese_font_count", "zh_font_count", "cjk_font_count"}:
        return _scalar(value, secrets)
    if key in {"chinese_font", "cjk"}:
        return _boolean(value)
    if value is None or type(value) is bool:
        return value
    if key in {"fonts_cn", "chinese_fonts"}:
        if type(value) in (int, float):
            return _scalar(value, secrets)
        if type(value) is list:
            result = [font if type(font) is str and font in _FONTS and font not in secrets
                      else _marker(font) for font in value[:32]]
            return result if len(value) <= 32 else {"_projection_truncated": True, "items": result}
        if type(value) is dict:
            return {font: _boolean(value[font]) for font in sorted(_FONTS & value.keys())}
        return value if type(value) is str and value in _FONTS and not _sensitive_text(value, secrets) else _marker(value)
    if key == "languages":
        if type(value) is not list:
            return _marker(value)
        result = [_locale_field("language", item, secrets) for item in value[:16]]
        return result if len(value) <= 16 else {"_projection_truncated": True, "items": result}
    if type(value) is not str or _sensitive_text(value, secrets) or len(value) > 80:
        return _marker(value)
    if key in {"intl_timezone", "timezone", "time_zone", "tz"}:
        return value if value in {"UTC", "GMT", "Etc/UTC", "Etc/GMT"} or _TIMEZONE.fullmatch(value) else _marker(value)
    if key == "region":
        return _country(value, secrets)
    return value if _LANGUAGE.fullmatch(value) else _marker(value)


def _net(value: Any, secrets: set[Any], depth: int = 0) -> dict:
    if type(value) is not dict or value.get("_redacted") is True or depth > 2:
        return _marker(value)
    result = {}
    for key, raw in value.items():
        if key in _NET_IP_FIELDS:
            result[key] = _public_ip(raw, secrets)
        elif key in {"country", "国家", "cc", "country_code"}:
            result[key] = _country(raw, secrets, key in {"cc", "country_code"})
        elif key in _NET_FLAGS:
            result[key] = _boolean(raw)
        elif key in {"ipv4", "ipv6", "capabilities"}:
            result[key] = _net(raw, secrets, depth + 1) if type(raw) is dict else _boolean(raw)
        elif key in {"ASN", "asn"}:
            result[key] = (raw if type(raw) is str and raw not in secrets
                           and re.fullmatch(r"AS[0-9]{1,10}", raw) else _scalar(raw, secrets))
        elif key == "risk":
            result[key] = (raw if type(raw) is str and raw not in secrets
                           and raw.lower() in _ENUMS else _scalar(raw, secrets))
        elif key in {"asnname", "org"}:
            result[key] = _presence(raw)
    return result


def _rtc(value: Any, secrets: set[Any]) -> dict:
    if type(value) is not dict or value.get("_redacted") is True:
        return _marker(value)
    result = {}
    for key in ("public_ip", "public_ip_v6"):
        if key in value:
            raw = value[key]
            already_truncated = type(raw) is dict and raw.get("_projection_truncated") is True
            if already_truncated:
                raw = raw.get("items")
            if type(raw) is list:
                items = [_public_ip(item, secrets) for item in raw[:16]]
                result[key] = (items if len(raw) <= 16 and not already_truncated
                               else {"_projection_truncated": True, "items": items})
            else:
                projected = _public_ip(raw, secrets)
                result[key] = ({"_projection_truncated": True, "items": projected}
                               if already_truncated else projected)
    if "disabled" in value:
        result["disabled"] = _boolean(value["disabled"])
    if "mdns" in value:
        result["mdns"] = (_boolean(value["mdns"]) if value["mdns"] is None or type(value["mdns"]) is bool
                          else _presence(value["mdns"]))
    if "mdns_present" in value:
        result["mdns_present"] = _boolean(value["mdns_present"])
    return result


def project_submission(value: Any) -> dict:
    return _submission(value, _secret_values(value))


def _submission(value: Any, secrets: set[Any]) -> dict:
    if type(value) is not dict or value.get("_redacted") is True:
        return _marker(value)
    result = {}
    for key, raw in value.items():
        if key == "dns":
            result[key] = _dns_response(raw, secrets)
            if type(raw) is dict:
                for count in ("count", "foreign_count"):
                    if count in raw:
                        result[key][count] = _scalar(raw[count], secrets)
        elif key == "net":
            result[key] = _net(raw, secrets)
        elif key == "rtc":
            result[key] = _rtc(raw, secrets)
        elif key in {"locale", "i18n"} and type(raw) is dict:
            result[key] = {field: _locale_field(field, item, secrets) for field, item in raw.items()
                           if field in _LOCALE_FIELDS}
        elif key in _LOCALE_FIELDS:
            result[key] = _locale_field(key, raw, secrets)
    return result


def _diagnostic_value(value: Any, secrets: set[Any], depth: int = 0) -> Any:
    if depth > 6:
        return _marker(value)
    if type(value) is dict:
        if value.get("_redacted") is True:
            return _marker(value)
        result = {key: _diagnostic_value(raw, secrets, depth + 1)
                  for key, raw in value.items() if key in _EVIDENCE_KEYS and not _sensitive_key(key)}
        if value.get("_projection_truncated") is True:
            result["_projection_truncated"] = True
        return result
    if type(value) is list:
        result = [_diagnostic_value(item, secrets, depth + 1) for item in value[:32]]
        return result if len(value) <= 32 else {"_projection_truncated": True, "items": result}
    if type(value) is not str:
        return _scalar(value, secrets)
    if _sensitive_text(value, secrets) or len(value) > 80:
        return _marker(value)
    if (value.lower() in _ENUMS or value in _COUNTRY_NAMES or value in _FONTS
            or _COUNTRY_CODES.fullmatch(value) or _LANGUAGE.fullmatch(value)
            or _TIMEZONE.fullmatch(value)):
        return value
    public = _public_ip(value, secrets)
    return public if type(public) is str else _scalar(value, secrets)


def project_site_result(value: Any) -> dict:
    if type(value) is not dict or value.get("_redacted") is True:
        return _marker(value)
    secrets = _secret_values(value)
    result = {}
    if "score" in value:
        result["score"] = _scalar(value["score"], secrets)
    if "level" in value:
        level = value["level"]
        result["level"] = (level if type(level) is str and level not in secrets
                           and len(level) <= 16 and level.lower() in _ENUMS else _marker(level))
    if "id" in value:
        identifier = value["id"]
        result["id"] = (identifier if type(identifier) is str and not _sensitive_text(identifier, secrets)
                        and _ID.fullmatch(identifier) else _scalar(identifier, secrets))
    if "findings" in value:
        findings = value["findings"]
        if type(findings) is not list:
            result["findings"] = _marker(findings)
        else:
            retained = []
            omitted = max(0, len(findings) - MAX_FINDING_SCAN)
            truncated = len(findings) > MAX_FINDING_SCAN
            # The site returns ordinary rows before the reviewed crosschecks.
            # Bound scanning separately; do not cut off those trailing findings.
            for finding in findings[:MAX_FINDING_SCAN]:
                if type(finding) is not dict or _enum(finding.get("id"), FINDING_IDS) is None:
                    omitted += 1
                    continue
                if len(retained) >= MAX_FINDINGS:
                    omitted += 1
                    truncated = True
                    continue
                row = {"id": finding["id"]}
                if "fail" in finding:
                    row["fail"] = _boolean(finding["fail"])
                if "severity" in finding:
                    severity = finding["severity"]
                    row["severity"] = (severity if type(severity) is str and severity not in secrets
                                       and severity.lower() in _ENUMS else _scalar(severity, secrets))
                for key in ("value", "evidence"):
                    if key in finding:
                        row[key] = _diagnostic_value(finding[key], secrets)
                retained.append(row)
            result["findings"] = retained
            if omitted:
                result["_omitted_findings"] = omitted
            if truncated:
                result["_projection_truncated"] = True
    if "evidence" in value:
        result["evidence"] = _submission(value["evidence"], secrets)
    if value.get("_projection_truncated") is True:
        result["_projection_truncated"] = True
    if type(value.get("_omitted_findings")) is int and value["_omitted_findings"] > 0:
        result["_omitted_findings"] = value["_omitted_findings"]
    return result


def _safe_id(value: Any, transaction: bool = False) -> str | None:
    pattern = _TX_ID if transaction else _ID
    return value if type(value) is str and pattern.fullmatch(value) and not _sensitive_text(value, set()) else None


def _source_reasons(capture: dict, contract: dict) -> list[str]:
    reasons = []
    if (contract.get("contract_id") != CONTRACT_ID or capture.get("contract_id") != CONTRACT_ID
            or contract.get("schema_version") != 1 or type(contract.get("schema_version")) is not int):
        reasons.append("contract_unreviewed")
    pins = contract.get("source_pins")
    if type(pins) is not dict or any(
        type(pins.get(url)) is not dict or pins[url].get("sha256") != digest
        or pins[url].get("required") is not True for url, digest in EXPECTED_SOURCE_PINS.items()
    ):
        reasons.append("contract_source_pins_missing")
    observed = capture.get("facts", {}).get("script_digests")
    if type(observed) is not list:
        return reasons + ["source_digest_evidence_missing"]
    seen: dict[str, set[Any]] = {}
    if len(observed) > MAX_TRANSACTIONS:
        reasons.append("source_digest_evidence_truncated")
    for item in observed[:MAX_TRANSACTIONS]:
        if (type(item) is not dict or type(item.get("url")) is not str
                or item["url"] not in EXPECTED_SOURCE_PINS):
            continue
        digest = item.get("sha256")
        if (type(digest) is str and re.fullmatch(r"[a-f0-9]{64}", digest)
                and type(item.get("bytes")) is int and item["bytes"] > 0):
            seen.setdefault(item["url"], set()).add(digest)
    for url, digest in EXPECTED_SOURCE_PINS.items():
        if url not in seen:
            reasons.append("source_digest_evidence_missing")
        elif seen[url] != {digest}:
            reasons.append("source_digest_mismatch")
    return sorted(set(reasons))


def _route_matches(raw: dict, kind: str) -> bool:
    expected = {"dnsleak": "/envdetect/probe/dnsleak", "submit": "/envdetect/submit"}
    url = raw.get("url")
    return (kind in expected and type(url) is dict and url.get("origin") == "https://ping0.cc"
            and url.get("path") == expected[kind] and url.get("query_names") == []
            and raw.get("method") == "POST")


def _transaction_fact(raw: dict) -> dict:
    kind = _enum(raw.get("kind"), _KINDS, "unknown")
    result = {
        "transaction_id": _safe_id(raw.get("transaction_id"), True),
        "request_id": _safe_id(raw.get("request_id")),
        "scope_id": _safe_id(raw.get("scope_id")),
        "sequence": raw.get("sequence") if type(raw.get("sequence")) is int and raw["sequence"] > 0 else None,
        "kind": kind,
        "route_match": _route_matches(raw, kind) if kind in {"dnsleak", "submit"} else None,
        "response_status": raw.get("response_status") if type(raw.get("response_status")) is int
                           and 100 <= raw["response_status"] <= 599 else None,
        "body_state": _enum(raw.get("body_state"), {
            "pending", "captured", "invalid_json", "unavailable", "too_large", "not_requested"}, "unavailable"),
        "terminal": _enum(raw.get("terminal"), {"pending", "finished", "failed"}, "pending"),
        "schema_state": _enum(raw.get("schema_state"), {"valid", "invalid", "unknown"}, "unknown"),
        "error_kind": _enum(raw.get("error_kind"), _ERROR_KINDS),
        "error_kind_state": ("absent" if raw.get("error_kind") is None else
                             "recorded" if _enum(raw.get("error_kind"), _ERROR_KINDS) is not None else "unreviewed"),
        "late": raw.get("late") if type(raw.get("late")) is bool else None,
    }
    if result["route_match"] is True:
        result["url"] = {"origin": "https://ping0.cc", "path": raw["url"]["path"], "query_names": []}
        result["method"] = "POST"
    if kind == "dnsleak":
        result["request_fields"] = project_dns_request(raw["request_fields"]) if raw.get("request_fields") is not None else None
        result["response_fields"] = project_dns_response(raw["response_fields"]) if raw.get("response_fields") is not None else None
    elif kind == "submit":
        result["request_fields"] = project_submission(raw["request_fields"]) if raw.get("request_fields") is not None else None
        result["response_fields"] = project_site_result(raw["response_fields"]) if raw.get("response_fields") is not None else None
    return result


def _dns_request_valid(value: Any) -> bool:
    if (type(value) is not dict or value.get("_projection_truncated") is True
            or type(value.get("domains")) is not list or not 1 <= len(value["domains"]) <= MAX_DOMAINS
            or "stamp" not in value):
        return False
    if any(type(domain) is not str or not _DOMAIN.fullmatch(domain) for domain in value["domains"]):
        return False
    stamp = value["stamp"]
    return (_numeric(stamp) or type(stamp) is str and re.fullmatch(r"[0-9]{1,24}", stamp) is not None)


def _has_probe_error(transaction: dict) -> bool:
    return (transaction["terminal"] == "failed"
            or transaction["response_status"] is not None and not 200 <= transaction["response_status"] < 300
            or transaction["body_state"] == "invalid_json")


def _direct_dns(transaction: dict) -> dict:
    row = {key: transaction[key] for key in ("transaction_id", "sequence", "scope_id", "response_status",
                                            "body_state", "terminal", "schema_state", "late", "route_match",
                                            "scope_match", "identity_unique")}
    response = transaction.get("response_fields")
    if type(response) is dict:
        if "resolver_count" in response:
            row["resolver_count"] = response["resolver_count"]
        if type(response.get("items")) is list:
            row["retained_items_length"] = len(response["items"])
            row["items_length_used_as_count"] = False
    if transaction["route_match"] is not True:
        row["status"] = "incomplete"
        row["reason"] = "dns_route_unreviewed"
    elif transaction["scope_match"] is not True or transaction["identity_unique"] is not True:
        row["status"] = "incomplete"
        row["reason"] = "dns_scope_or_identity_unbound"
    elif _has_probe_error(transaction):
        row["status"] = "probe_error"
        row["reason"] = ("request_failed" if transaction["terminal"] == "failed" else
                         "invalid_json" if transaction["body_state"] == "invalid_json" else "http_error")
    elif (transaction["terminal"] != "finished" or transaction["response_status"] is None
          or transaction["body_state"] != "captured" or transaction["schema_state"] != "valid"
          or dns_schema_state(response) != "valid"):
        row["status"] = "incomplete"
        row["reason"] = "dns_response_evidence_incomplete"
    else:
        row["status"] = "backend_zero" if response["resolver_count"] == 0 else "backend_positive"
    return row


def _submission_count(submission: Any) -> Any:
    if type(submission) is not dict or type(submission.get("dns")) is not dict:
        return None
    dns = submission["dns"]
    if "resolver_count" in dns and "count" in dns and (
        not _numeric(dns["resolver_count"]) or not _numeric(dns["count"])
        or dns["resolver_count"] != dns["count"]
    ):
        return None
    return dns.get("resolver_count", dns.get("count"))


def _finished_response(transaction: dict) -> bool:
    return (transaction["terminal"] == "finished" and transaction["body_state"] == "captured"
            and transaction["response_status"] is not None and 200 <= transaction["response_status"] < 300)


def diagnose(capture: dict, contract: dict) -> dict:
    """Separate direct observations, capture completeness, and cross-layer comparisons."""
    if type(capture) is not dict or type(contract) is not dict:
        raise ValidationError("capture_or_contract_type")
    _validate_json(capture)
    _validate_json(contract)
    facts = capture.get("facts") if type(capture.get("facts")) is dict else {}
    observation = capture.get("observation") if type(capture.get("observation")) is dict else {}
    subject = capture.get("subject") if type(capture.get("subject")) is dict else {}
    authority = []
    incomplete = []
    if type(capture.get("schema_version")) is not int or capture["schema_version"] != 1:
        authority.append("capture_schema_unreviewed")
    if type(capture.get("synthetic")) is not bool:
        authority.append("synthetic_marker_missing")
    subject_kind = _enum(subject.get("kind"), {"desktop-cdp", "ipad-inspector"}, "unknown")
    if subject_kind == "unknown":
        authority.append("subject_kind_unknown")
    if any(_safe_id(subject.get(key)) is None for key in ("target_id", "session_id")):
        authority.append("subject_target_binding_missing")
    scope = _safe_id(subject.get("scope_id"))
    if (scope is None or observation.get("scope_id") != scope
            or "scope_id" in capture and capture["scope_id"] != scope):
        authority.append("capture_scope_missing_or_mismatched")
    if observation.get("armed_before_navigation") is not True:
        authority.append("observation_not_armed")
    if observation.get("source_match") != "matched":
        authority.append("source_not_matched")
    authority.extend(_source_reasons({**capture, "facts": facts}, contract))
    if observation.get("end_reason") not in ("site_result_captured", "completed"):
        incomplete.append("capture_end_incomplete_or_unknown")
    if observation.get("deadline_reached") is not False:
        incomplete.append("deadline_reached_or_unknown")
    if observation.get("truncated") is not False:
        incomplete.append("capture_truncated_or_unknown")
    if type(observation.get("late_event_count")) is not int or observation["late_event_count"] != 0:
        incomplete.append("late_events_or_unknown")
    cleanup = observation.get("cleanup")
    if type(cleanup) is not dict or any(cleanup.get(key) is not True for key in (
        "session_detached", "target_closed", "context_disposed", "transport_closed"
    )):
        incomplete.append("cleanup_incomplete")
    raw_transactions = facts.get("transactions")
    if type(raw_transactions) is not list:
        raw_transactions = []
        incomplete.append("transaction_inventory_missing")
    if len(raw_transactions) > MAX_TRANSACTIONS:
        incomplete.append("transaction_inventory_truncated")
    transactions = []
    for raw in raw_transactions[:MAX_TRANSACTIONS]:
        if type(raw) is not dict:
            incomplete.append("invalid_transaction")
            continue
        transaction = _transaction_fact(raw)
        transaction["identity_unique"] = all(transaction[key] is not None for key in ("transaction_id", "request_id", "sequence"))
        transaction["scope_match"] = (
            scope is not None and transaction["scope_id"] == scope and observation.get("scope_id") == scope
            and capture.get("scope_id", scope) == scope and subject_kind != "unknown"
            and all(_safe_id(subject.get(key)) is not None for key in ("target_id", "session_id"))
            and all(key not in raw or raw[key] == scope for key in ("request_scope_id", "response_scope_id"))
            and all(key not in raw or raw[key] == subject.get(key) for key in ("target_id", "session_id"))
        )
        transactions.append(transaction)
        if transaction["kind"] == "unknown":
            incomplete.append("transaction_kind_unknown")
        if transaction["kind"] in {"dnsleak", "submit"} and transaction["route_match"] is not True:
            authority.append("transaction_route_mismatch")
        if any(transaction[key] is None for key in ("transaction_id", "request_id", "sequence")):
            authority.append("transaction_identity_missing")
        if transaction["scope_id"] != scope or scope is None:
            authority.append("transaction_scope_mismatch")
        if any(key in raw and raw[key] != scope for key in ("request_scope_id", "response_scope_id")):
            authority.append("transaction_scope_mismatch")
        if any(key in raw and raw[key] != subject.get(key) for key in ("target_id", "session_id")):
            authority.append("transaction_target_mismatch")
        if transaction["late"] is not False:
            incomplete.append("late_transaction_or_unknown")
        if transaction["kind"] == "dnsleak" and not _dns_request_valid(transaction.get("request_fields")):
            incomplete.append("dns_request_evidence_incomplete")
        if _projection_truncated(transaction):
            incomplete.append("projection_truncated")
        if transaction["kind"] in {"dnsleak", "submit"} and transaction["error_kind_state"] != "absent" and not _has_probe_error(transaction):
            incomplete.append("transaction_error_metadata_unreviewed_or_conflicting")
        if transaction["kind"] == "submit":
            if not _finished_response(transaction):
                incomplete.append("submit_history_incomplete_or_error")
            if transaction.get("request_fields") is None or transaction.get("response_fields") is None:
                incomplete.append("submit_body_evidence_missing")
    for field in ("transaction_id", "request_id", "sequence"):
        identities = [transaction[field] for transaction in transactions if transaction[field] is not None]
        counts = {}
        for identity in identities:
            counts[identity] = counts.get(identity, 0) + 1
        duplicates = {identity for identity, count in counts.items() if count > 1}
        if duplicates:
            authority.append("transaction_identity_collision")
            for transaction in transactions:
                if transaction[field] in duplicates:
                    transaction["identity_unique"] = False
    transactions.sort(key=lambda transaction: transaction["sequence"] if transaction["sequence"] is not None else MAX_SAFE_COUNT)
    dns_transactions = [transaction for transaction in transactions if transaction["kind"] == "dnsleak"]
    request_identities = {canonical(transaction["request_fields"]) for transaction in dns_transactions
                          if _dns_request_valid(transaction.get("request_fields"))}
    if len(request_identities) > 1:
        authority.append("dns_polling_request_identity_mismatch")
    direct = [_direct_dns(transaction) for transaction in dns_transactions]
    direct_states = {row["status"] for row in direct}
    if not direct:
        history_backend = "unavailable"
        incomplete.append("dns_transaction_not_observed")
    elif "probe_error" in direct_states:
        history_backend = "probe_error"
    elif "incomplete" in direct_states:
        history_backend = "incomplete"
    elif len(direct_states) > 1:
        history_backend = "mixed"
    else:
        history_backend = direct[0]["status"]
    if "incomplete" in direct_states:
        incomplete.append("dns_response_evidence_incomplete")
    if "probe_error" in direct_states:
        incomplete.append("dns_error_evidence_retained")
    final_observed = dict(direct[-1]) if direct else None
    # The pinned client awaits same-nonce polls serially. Valid mixed counts are
    # history, not failures; selecting the last response is a source-bound derivation.
    all_polls_valid = bool(direct) and direct_states <= {"backend_positive", "backend_zero"}
    backend = (final_observed["status"] if all_polls_valid and len(request_identities) == 1
               else history_backend)

    submission = project_submission(facts["client_submission"]) if facts.get("client_submission") is not None else None
    if _projection_truncated(submission):
        incomplete.append("projection_truncated")
    submit_id = _safe_id(facts.get("client_submission_transaction_id"), True)
    submits = [transaction for transaction in transactions if transaction["kind"] == "submit"]
    associated = [transaction for transaction in submits if transaction["transaction_id"] == submit_id
                  and transaction["scope_id"] == scope]
    submission_history = []
    for transaction in submits:
        entry = {key: transaction[key] for key in ("transaction_id", "sequence", "terminal", "body_state", "response_status")}
        payload = transaction.get("request_fields")
        if type(payload) is dict and type(payload.get("dns")) is dict:
            for key in ("resolver_count", "count"):
                if key in payload["dns"]:
                    entry[key] = payload["dns"][key]
        submission_history.append(entry)
        if not _numeric(_submission_count(payload)):
            incomplete.append("submission_history_count_missing_or_invalid")
    client = {"status": "unknown", "transaction_id": submit_id}
    submit = associated[0] if len(associated) == 1 else None
    if (submit is not None and final_observed is not None
            and type(submit["sequence"]) is int and type(final_observed["sequence"]) is int
            and final_observed["sequence"] >= submit["sequence"]):
        incomplete.append("dns_poll_after_selected_submission")
    if submission is None:
        gate = _enum(observation.get("submission_gate"), {"captcha", "job_pending"}, "unknown")
        client["reason"] = {"captcha": "submission_not_observed_captcha_gate",
                            "job_pending": "submission_not_observed_job_pending",
                            "unknown": "submission_not_observed_capture_unknown"}[gate]
    elif submit is None or facts.get("client_submission_scope_id") != scope or scope is None:
        client["reason"] = "submission_association_missing_or_mismatched"
        authority.append("submission_association_missing_or_mismatched")
    elif submission != submit.get("request_fields"):
        client["reason"] = "submission_evidence_conflict"
        incomplete.append("submission_evidence_conflict")
    elif not _finished_response(submit):
        client["reason"] = "submission_transaction_incomplete"
    else:
        count = _submission_count(submission)
        if count is not None:
            client["resolver_count"] = count
        # Failed, pending, unbound, or cross-nonce histories cannot be selected.
        if authority or incomplete or backend not in {"backend_positive", "backend_zero"}:
            client["reason"] = "round_evidence_incomplete"
        elif not _numeric(count):
            client["reason"] = "submission_count_missing_or_invalid"
        elif backend == "backend_positive" and count == 0:
            client["status"] = "client_submission_divergence"
            client["divergence_transaction_ids"] = [submit["transaction_id"]]
            client["reason"] = "conversion_fallback_or_assembly_possible_cause_unknown"
        elif final_observed["resolver_count"] == count:
            client["status"] = "consistent"
        else:
            client["status"] = "captured"
            client["reason"] = "count_differs_assembly_mapping_unknown"
    if client["status"] == "unknown":
        incomplete.append(client["reason"])

    site_raw = capture.get("site_result") if type(capture.get("site_result")) is dict else {}
    site = {
        "state": _enum(site_raw.get("state"), {"captured", "pending", "error", "unavailable"}, "unavailable"),
        "scope_id": _safe_id(site_raw.get("scope_id")),
        "transaction_id": _safe_id(site_raw.get("transaction_id"), True),
        "response": project_site_result(site_raw["response"]) if site_raw.get("response") is not None else None,
    }
    if _projection_truncated(site):
        incomplete.append("projection_truncated")
    server = {"status": "unknown", "reason": "site_result_not_observed"}
    site_associated = (site["state"] == "captured" and submit is not None and scope is not None
                       and site["scope_id"] == scope and site["transaction_id"] == submit["transaction_id"])
    if site["state"] == "captured" and not site_associated:
        server["reason"] = "site_result_association_missing_or_mismatched"
        authority.append(server["reason"])
    elif site_associated:
        if site["response"] != submit.get("response_fields") or not _finished_response(submit):
            server["reason"] = "site_result_evidence_conflict"
        elif authority or incomplete or client["status"] == "unknown":
            server["reason"] = "round_evidence_incomplete"
        else:
            findings = site["response"].get("findings") if type(site["response"]) is dict else None
            blackholes = [finding for finding in findings if type(finding) is dict
                          and finding.get("id") == "xc.dns_blackhole"] if type(findings) is list else []
            if len(blackholes) != 1 or type(blackholes[0].get("fail")) is not bool:
                server["reason"] = "dns_finding_missing_or_ambiguous"
            elif _numeric(_submission_count(submission)) and _submission_count(submission) > 0 and blackholes[0]["fail"] is True:
                server = {"status": "server_finding_divergence", "finding_id": "xc.dns_blackhole",
                          "reason": "server_rules_unknown"}
            else:
                server = {"status": "captured", "finding_id": "xc.dns_blackhole",
                          "fail": blackholes[0]["fail"], "reason": "server_rules_unknown"}
    if server["status"] == "unknown":
        incomplete.append(server["reason"])

    # Actual errors remain separately visible even when capture completeness is poor.
    error_only = {"dns_error_evidence_retained"}
    if authority:
        status = "unknown"
    elif backend == "probe_error" and set(incomplete) <= error_only | {
        "round_evidence_incomplete", "submission_not_observed_captcha_gate",
        "submission_not_observed_job_pending", "submission_not_observed_capture_unknown",
        "site_result_not_observed", "submission_transaction_incomplete"
    }:
        status = "probe_error"
    elif incomplete:
        status = "incomplete"
    elif client["status"] == "client_submission_divergence":
        status = client["status"]
    elif server["status"] == "server_finding_divergence":
        status = server["status"]
    else:
        status = backend if backend in {"backend_zero", "backend_positive"} else "unknown"
    optional_issues = []
    for transaction in transactions:
        if transaction["kind"] not in _OPTIONAL_KINDS:
            continue
        issue = None
        if transaction["terminal"] == "failed":
            issue = "request_failed"
        elif transaction["response_status"] is not None and not 200 <= transaction["response_status"] < 300:
            issue = "http_error"
        elif transaction["body_state"] == "invalid_json":
            issue = "invalid_json"
        elif transaction["terminal"] == "pending":
            issue = "pending"
        elif transaction["kind"] not in {"multigeo", "dns_trigger"} and transaction["body_state"] != "captured":
            issue = "body_not_captured"
        elif transaction["error_kind_state"] != "absent":
            issue = "error_metadata_recorded_or_unreviewed"
        if issue:
            optional_issues.append({"transaction_id": transaction["transaction_id"],
                                    "sequence": transaction["sequence"], "kind": transaction["kind"],
                                    "response_status": transaction["response_status"], "issue": issue})
    selected = (dict(final_observed) if all_polls_valid and len(request_identities) == 1
                and not authority and not incomplete else None)
    return {
        "schema_version": 1, "contract_id": CONTRACT_ID,
        "synthetic": capture.get("synthetic") if type(capture.get("synthetic")) is bool else None,
        "subject": {"kind": subject_kind, "scope_id": scope},
        "status": status,
        "complete": not authority and not incomplete,
        "direct_backend_observation": {
            "status": history_backend, "transactions": direct,
            "final_observed": final_observed, "selected": selected,
            "selection_basis": "source_bound_last_completed_valid_dns_response" if selected is not None else None,
        },
        "client_submission_comparison": client,
        "client_submission_history": submission_history,
        "server_finding_comparison": server,
        "reasons": sorted(set(authority + incomplete)),
        "optional_probe_issues": optional_issues,
        "facts": {"transactions": transactions, "client_submission": submission,
                  "client_submission_transaction_id": submit_id, "site_result": site,
                  "console_event_count": len(facts["console"]) if type(facts.get("console")) is list else None,
                  "page_snapshot_count": len(facts["page_snapshots"]) if type(facts.get("page_snapshots")) is list else None},
        "limits": ["scope_dns_submit_required_sources_only", "not_full_network_acceptance",
                   "backend_count_is_not_vpn_verdict", "no_system_dns_causality_claim", "server_rules_unknown",
                   "items_deduplication_unknown", "site_score_not_recomputed"],
    }


def _display_scalar(container: Any, key: str) -> str:
    if type(container) is not dict or key not in container:
        return "[missing]"
    value = container[key]
    if type(value) is dict and value.get("_redacted") is True:
        kind = value.get("_type")
        return "[redacted:" + _enum(kind, {"null", "boolean", "number", "string", "array", "object", "unsupported"}, "unknown") + "]"
    if value is None or type(value) in (bool, int, float):
        if type(value) is int and value.bit_length() > 256 or type(value) is float and not math.isfinite(value):
            return "[invalid]"
        return json.dumps(value, allow_nan=False)
    if type(value) is str and len(value) <= 32 and (value == "" or _NUMBER_TEXT.fullmatch(value)):
        return json.dumps(value)
    return "[redacted]"


def render_markdown(report: dict) -> str:
    """Render fixed technical fields without embedding untrusted prose or markup."""
    if type(report) is not dict:
        raise ValidationError("report_type")
    status = _enum(report.get("status"), _STATUSES, "unknown")
    direct = report.get("direct_backend_observation")
    rows = direct.get("transactions") if type(direct) is dict else None
    lines = ["# Ping0 evidence", "", "- status: `" + status + "`",
             "- synthetic: `" + (str(report["synthetic"]).lower() if type(report.get("synthetic")) is bool else "unknown") + "`",
             "- complete: `" + str(report.get("complete") is True).lower() + "`", "",
             "## DNS observations", "", "| Sequence | Transaction | Status | HTTP | resolver_count |",
             "| --- | --- | --- | --- | --- |"]
    if type(rows) is list:
        for row in rows[:MAX_TRANSACTIONS]:
            if type(row) is not dict:
                continue
            sequence = str(row["sequence"]) if type(row.get("sequence")) is int and 0 < row["sequence"] <= MAX_SAFE_COUNT else "unknown"
            identifier = _safe_id(row.get("transaction_id"), True) or "unknown"
            row_status = _enum(row.get("status"), _STATUSES, "unknown")
            http = str(row["response_status"]) if type(row.get("response_status")) is int and 100 <= row["response_status"] <= 599 else "unknown"
            lines.append(f"| {sequence} | {identifier} | {row_status} | {http} | {_display_scalar(row, 'resolver_count')} |")
    if type(direct) is dict:
        final = direct.get("final_observed")
        selected = direct.get("selected")
        final_status = _enum(final.get("status"), _STATUSES, "unknown") if type(final) is dict else "unknown"
        selected_status = _enum(selected.get("status"), _STATUSES, "unknown") if type(selected) is dict else "unknown"
        basis = ("source_bound_last_completed_valid_dns_response" if type(selected) is dict
                 and direct.get("selection_basis") == "source_bound_last_completed_valid_dns_response" else "unavailable")
        lines.extend(["", "- history_status: `" + _enum(direct.get("status"), _STATUSES, "unknown") + "`",
                      "- final_observed_status: `" + final_status + "`",
                      "- selected_status: `" + selected_status + "`",
                      "- selection_basis: `" + basis + "`"])
    for key, title in (("client_submission_comparison", "Client submission"),
                       ("server_finding_comparison", "Server finding")):
        comparison = report.get(key)
        state = _enum(comparison.get("status"), _STATUSES, "unknown") if type(comparison) is dict else "unknown"
        lines.extend(["", "## " + title, "", "- status: `" + state + "`"])
        if type(comparison) is dict:
            reason = _enum(comparison.get("reason"), _REASON_CODES)
            if reason:
                lines.append("- reason: `" + reason + "`")
        if key == "client_submission_comparison":
            lines.append("- resolver_count: `" + _display_scalar(comparison, "resolver_count") + "`")
        elif type(comparison) is dict and type(comparison.get("fail")) is bool:
            lines.append("- fail: `" + str(comparison["fail"]).lower() + "`")
    reasons = report.get("reasons")
    if type(reasons) is list:
        safe_reasons = sorted({_enum(reason, _REASON_CODES) for reason in reasons[:64]} - {None})
        if safe_reasons:
            lines.extend(["", "## Observation notes", ""])
            lines.extend("- `" + reason + "`" for reason in safe_reasons)
    optional = report.get("optional_probe_issues")
    if type(optional) is list:
        lines.extend(["", "- optional_probe_issues: `" + str(len(optional)) + "`"])
    lines.extend(["", "## Scope", "", "- scope_dns_submit_required_sources_only",
                  "- not_full_network_acceptance", "- backend_count_is_not_vpn_verdict",
                  "- no_system_dns_causality_claim", "- server_rules_unknown", "- items_deduplication_unknown",
                  "- site_score_not_recomputed", ""])
    return "\n".join(lines)
