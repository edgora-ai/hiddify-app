/// Minimal, credential-free skeletons for newly added nodes.
///
/// Unlike the JSON editor's demo templates, these carry no example UUIDs,
/// passwords or keys: required credentials stay empty so the form forces
/// the user to fill in real values. Optional sections (transport, tls for
/// TUIC/Hysteria2 aside) are omitted entirely.
abstract final class NodeProtocolTemplates {
  static const supported = <String>['vmess', 'vless', 'trojan', 'shadowsocks', 'tuic', 'hysteria2'];

  static bool isSupported(String? type) => type != null && supported.contains(type);

  /// Returns a fresh skeleton Map for [protocol], with [tag] prefilled.
  /// Throws [ArgumentError] for unsupported protocols.
  static Map<String, dynamic> create(String protocol, String tag) {
    final base = <String, dynamic>{'type': protocol, 'tag': tag, 'server': '', 'server_port': 443};
    switch (protocol) {
      case 'vmess':
        return base
          ..addAll({
            'uuid': '',
            'security': 'auto',
          });
      case 'vless':
        return base
          ..addAll({
            'uuid': '',
            // flow intentionally omitted: no vision by default.
          });
      case 'trojan':
        return base
          ..addAll({
            'password': '',
            'tls': {'enabled': true},
          });
      case 'shadowsocks':
        return base
          ..addAll({
            'method': 'aes-256-gcm',
            'password': '',
          });
      case 'tuic':
        return base
          ..addAll({
            'uuid': '',
            'password': '',
            'congestion_control': 'cubic',
            'udp_relay_mode': 'native',
            'tls': {'enabled': true},
          });
      case 'hysteria2':
        return base
          ..addAll({
            'password': '',
            'tls': {'enabled': true},
          });
      default:
        throw ArgumentError.value(protocol, 'protocol', 'unsupported node protocol');
    }
  }
}
