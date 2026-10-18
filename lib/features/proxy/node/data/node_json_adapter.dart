import 'dart:convert';

/// Small pure-Dart helpers for reading and patching a single outbound Map.
///
/// The node form edits a deep copy of the original outbound; unknown fields
/// stay untouched because we only write back the keys the form owns.
abstract final class NodeJson {
  /// Deep-copies a JSON-compatible value via encode/decode round-trip.
  static Map<String, dynamic> deepCopyMap(Map<String, dynamic> src) =>
      jsonDecode(jsonEncode(src)) as Map<String, dynamic>;

  /// Reads a nested value by path segments, returns null when any hop is
  /// missing or not a Map. Never throws on malformed input.
  static dynamic getPath(Map<String, dynamic> map, List<String> path) {
    dynamic cur = map;
    for (final seg in path) {
      if (cur is! Map<String, dynamic>) return null;
      cur = cur[seg];
    }
    return cur;
  }

  /// Writes [value] at [path], creating intermediate Maps as needed.
  /// A null [value] deletes the leaf key instead of writing null.
  /// Empty parent Maps left behind by deletion are pruned so we don't emit
  /// e.g. `"tls": {}` when the user turns TLS off.
  static void putPath(Map<String, dynamic> map, List<String> path, dynamic value) {
    assert(path.isNotEmpty);
    Map<String, dynamic> cur = map;
    for (var i = 0; i < path.length - 1; i++) {
      final seg = path[i];
      var next = cur[seg];
      if (next is! Map<String, dynamic>) {
        next = <String, dynamic>{};
        cur[seg] = next;
      }
      cur = next;
    }
    final leaf = path.last;
    if (value == null) {
      cur.remove(leaf);
      _pruneEmptyParents(map, path);
    } else {
      cur[leaf] = value;
    }
  }

  static void _pruneEmptyParents(Map<String, dynamic> root, List<String> path) {
    // Walk from the deepest parent upward; remove Maps that became empty.
    for (var depth = path.length - 1; depth >= 1; depth--) {
      final parentPath = path.sublist(0, depth);
      final parent = getPath(root, parentPath);
      if (parent is Map<String, dynamic> && parent.isEmpty) {
        final grandParent = depth == 1 ? root : getPath(root, parentPath.sublist(0, depth - 1));
        if (grandParent is Map<String, dynamic>) {
          grandParent.remove(parentPath.last);
        }
      } else {
        break;
      }
    }
  }

  /// Reads an int that may be stored as int or numeric String.
  static int? asInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// Optional integer form input. Only blank input removes the setting;
  /// malformed non-empty text stays in the draft so validation can reject it.
  /// Explicit radix 10 prevents hexadecimal input from becoming an integer.
  static Object? optionalIntInput(String input) {
    final value = input.trim();
    if (value.isEmpty) return null;
    return int.tryParse(value, radix: 10) ?? value;
  }

  /// Reads a String, converting numbers/bools; null stays null.
  static String? asString(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return null;
  }

  /// Reads ALPN which core may store as `String` or `List<String>`.
  static List<String> asStringList(dynamic v) {
    if (v is List) return v.whereType<String>().toList();
    if (v is String && v.isNotEmpty) return [v];
    return [];
  }

  /// Splits a core tag like `Kr-xg § 0` into (displayName, suffix).
  /// Only the exact ` § <digits>` tail is treated as a suffix; anything
  /// else is returned whole as the display name with an empty suffix.
  /// The suffix must be preserved on save when the user didn't rename.
  static (String displayName, String suffix) splitTagSuffix(String tag) {
    // Non-greedy name + exact ' § <digits>' tail, e.g. 'Kr-xg § 0'.
    final m = RegExp(r'^(.*?) (?:§ (\d+))$').firstMatch(tag);
    if (m == null) return (tag, '');
    return (m.group(1)!, ' § ${m.group(2)!}');
  }

  /// Effective transport type for the form: `tcp` when the outbound has no
  /// `transport` object, otherwise `transport.type`.
  static String transportTypeOf(Map<String, dynamic> outbound) {
    final t = outbound['transport'];
    if (t is Map<String, dynamic>) {
      final type = t['type'];
      if (type is String && type.isNotEmpty) return type;
    }
    return 'tcp';
  }

  /// Applies a form transport selection. `tcp` removes the whole `transport`
  /// object (sing-box has no `transport.type = tcp`).
  static void applyTransportType(Map<String, dynamic> outbound, String selection) {
    if (selection == 'tcp') {
      outbound.remove('transport');
    } else {
      putPath(outbound, ['transport', 'type'], selection);
    }
  }

  /// TLS mode for the form: `none` (no tls object or enabled != true),
  /// `reality` (tls.reality.enabled == true), else `tls`.
  static String tlsModeOf(Map<String, dynamic> outbound) {
    final tls = outbound['tls'];
    if (tls is! Map<String, dynamic> || tls['enabled'] != true) return 'none';
    final reality = tls['reality'];
    if (reality is Map<String, dynamic> && reality['enabled'] == true) return 'reality';
    return 'tls';
  }

  /// Applies a form TLS mode selection, creating/removing nested objects.
  /// Unknown sibling keys inside `tls` are preserved.
  static void applyTlsMode(Map<String, dynamic> outbound, String mode) {
    switch (mode) {
      case 'none':
        outbound.remove('tls');
      case 'tls':
        putPath(outbound, ['tls', 'enabled'], true);
        putPath(outbound, ['tls', 'reality'], null);
      case 'reality':
        putPath(outbound, ['tls', 'enabled'], true);
        putPath(outbound, ['tls', 'reality', 'enabled'], true);
    }
  }

  /// Case-insensitive update of a headers map (e.g. WS Host). Preserves the
  /// existing key casing when present; otherwise uses [preferredKey].
  /// A null/empty [value] removes the header.
  static void putHeader(Map<String, dynamic> headers, String preferredKey, String? value) {
    String? existing;
    for (final k in headers.keys) {
      if (k.toLowerCase() == preferredKey.toLowerCase()) {
        existing = k;
        break;
      }
    }
    if (value == null || value.isEmpty) {
      if (existing != null) headers.remove(existing);
      return;
    }
    headers[existing ?? preferredKey] = value;
  }
}
