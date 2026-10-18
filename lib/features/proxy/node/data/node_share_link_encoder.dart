import 'dart:convert';

import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';

/// Result of encoding one outbound to a share link.
///
/// [link] is null when [blockedReason] is set: the outbound cannot be
/// faithfully represented (e.g. it depends on a detour). [warnings] lists
/// dropped settings the user should know about; [droppedFields] the raw keys.
class NodeShareOutcome {
  const NodeShareOutcome({this.link, this.blockedReason, this.warnings = const [], this.droppedFields = const []});

  final String? link;
  final String? blockedReason;
  final List<String> warnings;
  final List<String> droppedFields;

  bool get blocked => blockedReason != null;
}

/// Pure-Dart outbound JSON → share-link encoder for the six form protocols.
///
/// Input must be the complete outbound Map from the saved config — never the
/// runtime `OutboundInfo` summary, which carries no credentials.
abstract final class NodeShareLinkEncoder {
  /// Block reason codes (mapped to translations by the UI layer).
  static const blockedDetour = 'detour';
  static const blockedExtraHeaders = 'extraHeaders';
  static const blockedUnsupportedTransport = 'unsupportedTransport';
  static const blockedRealityNotShareable = 'realityNotShareable';
  static const blockedUnsupportedObfs = 'unsupportedObfs';
  static const blockedUnsupportedProtocol = 'unsupportedProtocol';
  static const blockedMissingField = 'missingField';

  static const _shareableTransports = {'tcp', 'ws', 'grpc', 'httpupgrade'};

  /// Fields that never survive a share link; reported as warnings.
  static const _droppedDialKeys = {'dial_timeout', 'tcp_fast_open', 'tcp_multi_path', 'udp_fragment'};

  static NodeShareOutcome encode(Map<String, dynamic> outbound) {
    final type = outbound['type'];
    if (type is! String) return const NodeShareOutcome(blockedReason: blockedUnsupportedProtocol);

    final server = NodeJson.asString(outbound['server']);
    final port = NodeJson.asInt(outbound['server_port']);
    if (server == null || server.isEmpty || port == null || port <= 0) {
      return const NodeShareOutcome(blockedReason: blockedMissingField);
    }
    // A detour-dependent outbound cannot be shared standalone.
    final detour = outbound['detour'];
    if (detour is String && detour.isNotEmpty) {
      return const NodeShareOutcome(blockedReason: blockedDetour);
    }

    final (name, _) = NodeJson.splitTagSuffix(NodeJson.asString(outbound['tag']) ?? '');

    final warnings = <String>[];
    final dropped = <String>[];
    _collectCommonDropped(outbound, warnings, dropped);

    switch (type) {
      case 'vmess':
        return _vmess(outbound, server, port, name, warnings, dropped);
      case 'vless':
        return _vless(outbound, server, port, name, warnings, dropped);
      case 'trojan':
        return _trojan(outbound, server, port, name, warnings, dropped);
      case 'shadowsocks':
        return _shadowsocks(outbound, server, port, name, warnings, dropped);
      case 'tuic':
        return _tuic(outbound, server, port, name, warnings, dropped);
      case 'hysteria2':
        return _hysteria2(outbound, server, port, name, warnings, dropped);
      default:
        return const NodeShareOutcome(blockedReason: blockedUnsupportedProtocol);
    }
  }

  // ------------------------------------------------------------------ common

  static void _collectCommonDropped(
    Map<String, dynamic> outbound,
    List<String> warnings,
    List<String> dropped,
  ) {
    if (outbound['multiplex'] is Map) {
      dropped.add('multiplex');
      warnings.add('multiplex');
    }
    if (outbound['packet_encoding'] != null) {
      dropped.add('packet_encoding');
      warnings.add('packet_encoding');
    }
    for (final k in _droppedDialKeys) {
      if (outbound[k] != null) {
        dropped.add(k);
        warnings.add(k);
      }
    }
  }

  /// Authority host with IPv6 brackets; userinfo-free.
  static String _authorityHost(String server) => server.contains(':') && !server.startsWith('[') ? '[$server]' : server;

  static String _query(Map<String, String> params) {
    final parts = <String>[];
    params.forEach((k, v) {
      if (v.isNotEmpty) parts.add('$k=${Uri.encodeComponent(v)}');
    });
    return parts.join('&');
  }

  static String _alpnParam(Map<String, dynamic> outbound) => NodeJson.asStringList(NodeJson.getPath(outbound, [
    'tls',
    'alpn',
  ])).join(',');

  static String? _sniOf(Map<String, dynamic> outbound) => NodeJson.asString(NodeJson.getPath(outbound, ['tls', 'server_name']));

  static String? _fpOf(Map<String, dynamic> outbound) => NodeJson.asString(NodeJson.getPath(outbound, ['tls', 'utls', 'fingerprint']));

  static bool _insecureOf(Map<String, dynamic> outbound) => NodeJson.getPath(outbound, ['tls', 'insecure']) == true;

  /// Returns (host, path, serviceName) for ws/grpc/httpupgrade, or null +
  /// blocked reason when the transport can't be represented.
  static ({String host, String path, String serviceName})? _transportParams(
    Map<String, dynamic> outbound,
    void Function(String reason) onBlocked,
  ) {
    final t = NodeJson.transportTypeOf(outbound);
    if (!_shareableTransports.contains(t)) {
      onBlocked(blockedUnsupportedTransport);
      return null;
    }
    if (t == 'tcp') return (host: '', path: '', serviceName: '');
    final transport = outbound['transport'];
    if (transport is! Map<String, dynamic>) return (host: '', path: '', serviceName: '');
    switch (t) {
      case 'ws':
        final headers = transport['headers'];
        var host = '';
        if (headers is Map<String, dynamic>) {
          for (final e in headers.entries) {
            if (e.key.toLowerCase() == 'host') {
              host = NodeJson.asString(e.value) ?? '';
            } else {
              onBlocked(blockedExtraHeaders);
              return null;
            }
          }
        }
        return (host: host, path: NodeJson.asString(transport['path']) ?? '', serviceName: '');
      case 'grpc':
        return (host: '', path: '', serviceName: NodeJson.asString(transport['service_name']) ?? '');
      case 'httpupgrade':
        return (
          host: NodeJson.asString(transport['host']) ?? '',
          path: NodeJson.asString(transport['path']) ?? '',
          serviceName: '',
        );
      default:
        return (host: '', path: '', serviceName: '');
    }
  }

  // -------------------------------------------------------------------- vmess

  static NodeShareOutcome _vmess(
    Map<String, dynamic> outbound,
    String server,
    int port,
    String name,
    List<String> warnings,
    List<String> dropped,
  ) {
    final uuid = NodeJson.asString(outbound['uuid']);
    if (uuid == null || uuid.isEmpty) return const NodeShareOutcome(blockedReason: blockedMissingField);

    final tlsMode = NodeJson.tlsModeOf(outbound);
    if (tlsMode == 'reality') {
      return const NodeShareOutcome(blockedReason: blockedRealityNotShareable);
    }

    String? blocked;
    final tp = _transportParams(outbound, (r) => blocked = r);
    if (tp == null) return NodeShareOutcome(blockedReason: blocked);

    // grpc service name rides in `path` per common client convention.
    final net = NodeJson.transportTypeOf(outbound);
    final path = net == 'grpc' ? tp.serviceName : tp.path;

    final json = <String, dynamic>{
      'v': '2',
      'ps': name,
      'add': server,
      'port': port.toString(),
      'id': uuid,
      'aid': NodeJson.asString(outbound['alter_id']) ?? '0',
      'scy': NodeJson.asString(outbound['security']) ?? 'auto',
      'net': net,
      'type': 'none',
      'host': tp.host,
      'path': path,
      'tls': tlsMode == 'tls' ? 'tls' : '',
      'sni': _sniOf(outbound) ?? '',
      'alpn': _alpnParam(outbound),
      'fp': _fpOf(outbound) ?? '',
    };
    for (final k in ['global_padding', 'authenticated_length']) {
      if (outbound[k] != null) {
        dropped.add(k);
        warnings.add(k);
      }
    }
    final link = 'vmess://${base64.encode(utf8.encode(jsonEncode(json)))}';
    return NodeShareOutcome(link: link, warnings: warnings, droppedFields: dropped);
  }

  // -------------------------------------------------------------------- vless

  static NodeShareOutcome _vless(
    Map<String, dynamic> outbound,
    String server,
    int port,
    String name,
    List<String> warnings,
    List<String> dropped,
  ) {
    final uuid = NodeJson.asString(outbound['uuid']);
    if (uuid == null || uuid.isEmpty) return const NodeShareOutcome(blockedReason: blockedMissingField);

    String? blocked;
    final tp = _transportParams(outbound, (r) => blocked = r);
    if (tp == null) return NodeShareOutcome(blockedReason: blocked);

    final tlsMode = NodeJson.tlsModeOf(outbound);
    final params = <String, String>{
      'encryption': 'none',
      'security': tlsMode == 'none' ? 'none' : tlsMode,
      'type': NodeJson.transportTypeOf(outbound),
      'flow': NodeJson.asString(outbound['flow']) ?? '',
      'sni': _sniOf(outbound) ?? '',
      'alpn': _alpnParam(outbound),
      'fp': _fpOf(outbound) ?? '',
      'host': tp.host,
      'path': tp.path,
      'serviceName': tp.serviceName,
    };
    if (tlsMode == 'reality') {
      params['pbk'] = NodeJson.asString(NodeJson.getPath(outbound, ['tls', 'reality', 'public_key'])) ?? '';
      params['sid'] = NodeJson.asString(NodeJson.getPath(outbound, ['tls', 'reality', 'short_id'])) ?? '';
    }
    if (_insecureOf(outbound)) params['allowInsecure'] = '1';

    final link = 'vless://$uuid@${_authorityHost(server)}:$port?${_query(params)}#${Uri.encodeComponent(name)}';
    return NodeShareOutcome(link: link, warnings: warnings, droppedFields: dropped);
  }

  // ------------------------------------------------------------------- trojan

  static NodeShareOutcome _trojan(
    Map<String, dynamic> outbound,
    String server,
    int port,
    String name,
    List<String> warnings,
    List<String> dropped,
  ) {
    final password = NodeJson.asString(outbound['password']);
    if (password == null || password.isEmpty) return const NodeShareOutcome(blockedReason: blockedMissingField);

    String? blocked;
    final tp = _transportParams(outbound, (r) => blocked = r);
    if (tp == null) return NodeShareOutcome(blockedReason: blocked);

    final tlsMode = NodeJson.tlsModeOf(outbound);
    final params = <String, String>{
      'security': tlsMode == 'none' ? 'none' : tlsMode,
      'type': NodeJson.transportTypeOf(outbound),
      'sni': _sniOf(outbound) ?? '',
      'alpn': _alpnParam(outbound),
      'fp': _fpOf(outbound) ?? '',
      'host': tp.host,
      'path': tp.path,
      'serviceName': tp.serviceName,
    };
    if (tlsMode == 'reality') {
      params['pbk'] = NodeJson.asString(NodeJson.getPath(outbound, ['tls', 'reality', 'public_key'])) ?? '';
      params['sid'] = NodeJson.asString(NodeJson.getPath(outbound, ['tls', 'reality', 'short_id'])) ?? '';
    }
    if (_insecureOf(outbound)) params['allowInsecure'] = '1';

    final link =
        'trojan://${Uri.encodeComponent(password)}@${_authorityHost(server)}:$port?${_query(params)}#${Uri.encodeComponent(name)}';
    return NodeShareOutcome(link: link, warnings: warnings, droppedFields: dropped);
  }

  // ------------------------------------------------------------- shadowsocks

  static NodeShareOutcome _shadowsocks(
    Map<String, dynamic> outbound,
    String server,
    int port,
    String name,
    List<String> warnings,
    List<String> dropped,
  ) {
    final method = NodeJson.asString(outbound['method']);
    final password = NodeJson.asString(outbound['password']);
    if (method == null || method.isEmpty || password == null || password.isEmpty) {
      return const NodeShareOutcome(blockedReason: blockedMissingField);
    }
    if (outbound['udp_over_tcp'] == true) {
      dropped.add('udp_over_tcp');
      warnings.add('udp_over_tcp');
    }

    String userinfo;
    if (method.startsWith('2022-blake3-')) {
      userinfo = '${Uri.encodeComponent(method)}:${Uri.encodeComponent(password)}';
    } else {
      userinfo = base64Url.encode(utf8.encode('$method:$password')).replaceAll('=', '');
    }

    var link = 'ss://$userinfo@${_authorityHost(server)}:$port#${Uri.encodeComponent(name)}';
    final plugin = NodeJson.asString(outbound['plugin']);
    if (plugin != null && plugin.isNotEmpty) {
      final opts = NodeJson.asString(outbound['plugin_opts']) ?? '';
      final pluginValue = opts.isEmpty ? plugin : '$plugin;$opts';
      // Insert query before fragment.
      link =
          'ss://$userinfo@${_authorityHost(server)}:$port?plugin=${Uri.encodeComponent(pluginValue)}#${Uri.encodeComponent(name)}';
    }
    return NodeShareOutcome(link: link, warnings: warnings, droppedFields: dropped);
  }

  // ---------------------------------------------------------------------- tuic

  static NodeShareOutcome _tuic(
    Map<String, dynamic> outbound,
    String server,
    int port,
    String name,
    List<String> warnings,
    List<String> dropped,
  ) {
    final uuid = NodeJson.asString(outbound['uuid']);
    final password = NodeJson.asString(outbound['password']);
    if (uuid == null || uuid.isEmpty || password == null || password.isEmpty) {
      return const NodeShareOutcome(blockedReason: blockedMissingField);
    }
    for (final k in ['udp_over_stream', 'zero_rtt_handshake', 'heartbeat']) {
      if (outbound[k] != null) {
        dropped.add(k);
        warnings.add(k);
      }
    }
    final params = <String, String>{
      'congestion_control': NodeJson.asString(outbound['congestion_control']) ?? '',
      'udp_relay_mode': NodeJson.asString(outbound['udp_relay_mode']) ?? '',
      'sni': _sniOf(outbound) ?? '',
      'alpn': _alpnParam(outbound),
    };
    if (_insecureOf(outbound)) params['allow_insecure'] = '1';

    final link =
        'tuic://$uuid:${Uri.encodeComponent(password)}@${_authorityHost(server)}:$port?${_query(params)}#${Uri.encodeComponent(name)}';
    return NodeShareOutcome(link: link, warnings: warnings, droppedFields: dropped);
  }

  // ----------------------------------------------------------------- hysteria2

  static NodeShareOutcome _hysteria2(
    Map<String, dynamic> outbound,
    String server,
    int port,
    String name,
    List<String> warnings,
    List<String> dropped,
  ) {
    final password = NodeJson.asString(outbound['password']);
    if (password == null || password.isEmpty) return const NodeShareOutcome(blockedReason: blockedMissingField);

    final params = <String, String>{'sni': _sniOf(outbound) ?? ''};
    if (_insecureOf(outbound)) params['insecure'] = '1';

    final obfs = outbound['obfs'];
    if (obfs is Map<String, dynamic>) {
      final obfsType = NodeJson.asString(obfs['type']) ?? '';
      if (obfsType.isNotEmpty && obfsType != 'salamander') {
        return const NodeShareOutcome(blockedReason: blockedUnsupportedObfs);
      }
      if (obfsType == 'salamander') {
        params['obfs'] = 'salamander';
        params['obfs-password'] = NodeJson.asString(obfs['password']) ?? '';
      }
    }
    for (final k in ['up_mbps', 'down_mbps']) {
      if (outbound[k] != null) {
        dropped.add(k);
        warnings.add(k);
      }
    }

    final link =
        'hysteria2://${Uri.encodeComponent(password)}@${_authorityHost(server)}:$port/?${_query(params)}#${Uri.encodeComponent(name)}';
    return NodeShareOutcome(link: link, warnings: warnings, droppedFields: dropped);
  }
}
