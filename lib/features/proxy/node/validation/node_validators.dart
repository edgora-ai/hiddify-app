import 'dart:convert';

import 'package:hiddify/utils/validators.dart';

/// Pure-Dart validators for node form fields.
///
/// Each function returns `true` when valid. UI layers map failures to
/// translated messages; see `errors.nodes.*` keys.
abstract final class NodeValidators {
  static final _uuidRegex = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  static final _hexEvenRegex = RegExp(r'^([0-9a-fA-F]{2})*$');

  /// Standard UUID in any version, case-insensitive. No trim: callers pass
  /// the raw input so surrounding whitespace fails loudly.
  static bool isUuid(String input) => _uuidRegex.hasMatch(input);

  /// Server address: domain, IPv4 or IPv6. Rejects CIDR, scheme, path,
  /// userinfo and embedded ports.
  static bool isServerAddress(String input) {
    final v = input.trim();
    if (v.isEmpty) return false;
    if (v.contains('/') || v.contains('@') || v.contains(' ')) return false;
    if (v.contains('://')) return false;
    // Bare IPv6 without brackets, or bracketed.
    final unbracketed = (v.startsWith('[') && v.endsWith(']')) ? v.substring(1, v.length - 1) : v;
    if (unbracketed.contains(':')) {
      try {
        Uri.parseIPv6Address(unbracketed);
        return true;
      } on FormatException {
        return false;
      }
    }
    // IPv4 (no prefix allowed) or domain.
    if (RegExp(r'^[0-9.]+$').hasMatch(v)) {
      try {
        Uri.parseIPv4Address(v);
        return true;
      } on FormatException {
        return false;
      }
    }
    // Reject host:port leftovers.
    if (v.contains(':')) return false;
    return isDomain(v);
  }

  /// Reality public key: base64url-decoded to exactly 32 bytes.
  static bool isRealityPublicKey(String input) {
    final v = input.trim();
    if (v.isEmpty) return false;
    try {
      final normalized = v.replaceAll('-', '+').replaceAll('_', '/');
      final decoded = base64.decode(normalized.padRight((normalized.length + 3) ~/ 4 * 4, '='));
      return decoded.length == 32;
    } catch (_) {
      return false;
    }
  }

  /// Reality short ID: empty or even-length hex, max 16 chars.
  static bool isRealityShortId(String input) {
    final v = input.trim();
    if (v.isEmpty) return true;
    if (v.length > 16) return false;
    return _hexEvenRegex.hasMatch(v);
  }

  /// Shadowsocks key check. For 2022-* methods the password must base64-decode
  /// to the method's key length (16/32 bytes). Other methods accept any
  /// non-empty password.
  static bool isShadowsocksKey(String method, String password) {
    const keyed = {'2022-blake3-aes-128-gcm': 16, '2022-blake3-aes-256-gcm': 32, '2022-blake3-chacha20-poly1305': 32};
    final want = keyed[method];
    if (want == null) return password.isNotEmpty;
    if (password.isEmpty) return false;
    try {
      // 2022 keys may be `base64:key` segments; validate the last one.
      final seg = password.split(':').last;
      final normalized = seg.replaceAll('-', '+').replaceAll('_', '/');
      final decoded = base64.decode(normalized.padRight((normalized.length + 3) ~/ 4 * 4, '='));
      return decoded.length == want;
    } catch (_) {
      return false;
    }
  }

  /// Duration like `10s`, `1m`, `500ms`. Accepts plain seconds too.
  static bool isDuration(String input) {
    final v = input.trim();
    if (v.isEmpty) return false;
    return RegExp(r'^\d+(\.\d+)?(ns|us|µs|ms|s|m|h)?$').hasMatch(v);
  }

  /// Non-negative integer for counts/sizes.
  static bool isNonNegativeInt(String input) {
    final v = input.trim();
    if (v.isEmpty) return false;
    final n = int.tryParse(v);
    return n != null && n >= 0;
  }

  /// The 64-bit core multiplies integer Mbps by 125000 before converting to
  /// uint64. Bound the input so that signed Go int multiplication cannot wrap.
  static const maxBandwidthMbps = 0x7fffffffffffffff ~/ 125000;

  /// Positive decimal integer for Hysteria2 bandwidths. Keep the existing
  /// entry point for the editor's validation call; fractions must not reach
  /// Go's integer up_mbps/down_mbps options, even as integral doubles.
  static bool isPositiveNumber(String input) {
    final n = int.tryParse(input.trim(), radix: 10);
    return n != null && n > 0 && n <= maxBandwidthMbps;
  }

  /// ALPN list: comma or space separated tokens, each non-empty.
  static List<String>? parseAlpn(String input) {
    final v = input.trim();
    if (v.isEmpty) return [];
    final parts = v.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return [];
    if (parts.any((e) => e.length > 255)) return null;
    return parts;
  }

  /// VLESS flow/xTLS-vision combination check against transport + multiplex.
  /// Returns an error code, or null when the combination is acceptable.
  static String? vlessCombinationError({required String flow, required String transport, required bool multiplex}) {
    if (flow.isEmpty) return null;
    if (flow != 'xtls-rprx-vision') return 'unknownFlow';
    if (transport != 'tcp') return 'visionRequiresTcp';
    if (multiplex) return 'visionNoMultiplex';
    return null;
  }
}
