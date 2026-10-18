import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/node/data/node_share_link_encoder.dart';

Map<String, dynamic> tlsOutbound(String type, Map<String, dynamic> tls) => {
  'type': type,
  'tag': 'synthetic-node',
  'server': 'proxy.example.test',
  'server_port': 443,
  if (type == 'vmess' || type == 'vless' || type == 'tuic') 'uuid': '00000000-0000-4000-8000-000000000001',
  if (type == 'trojan' || type == 'tuic' || type == 'hysteria2') 'password': 'synthetic-password',
  'tls': tls,
};

void main() {
  group('TLS share safety', () {
    const constraints = <String, dynamic>{
      'certificate_public_key_sha256': ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='],
      'certificate_sha256': ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='],
      'certificate': ['synthetic trust certificate'],
      'certificate_path': 'synthetic-ca.pem',
      'client_certificate': ['synthetic client certificate'],
      'client_certificate_path': 'synthetic-client.pem',
      'client_key': ['synthetic client key'],
      'client_key_path': 'synthetic-client-key.pem',
      'min_version': '1.3',
      'max_version': '1.3',
      'cipher_suites': ['TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256'],
      'curve_preferences': ['X25519'],
    };
    for (final type in ['vmess', 'vless', 'trojan', 'tuic', 'hysteria2']) {
      for (final constraint in constraints.entries) {
        test('$type refuses unrepresentable TLS ${constraint.key}', () {
          final outbound = tlsOutbound(type, {'enabled': true, constraint.key: constraint.value});
          final before = jsonEncode(outbound);
          final outcome = NodeShareLinkEncoder.encode(outbound);
          expect(outcome.blockedReason, NodeShareLinkEncoder.blockedTlsNotShareable);
          expect(outcome.link, isNull);
          expect(outcome.warnings, contains('tls.${constraint.key}'));
          expect(outcome.droppedFields, contains('tls.${constraint.key}'));
          expect(jsonEncode(outbound), before);
        });
      }
      test('$type shares ordinary TLS without loss warnings', () {
        final outcome = NodeShareLinkEncoder.encode(
          tlsOutbound(type, {
            'enabled': true,
            'server_name': 'proxy.example.test',
            'insecure': false,
            'certificate': <String>[],
            'certificate_public_key_sha256': <String>[],
            'client_certificate': <String>[],
            'client_key_path': '',
            'disable_sni': false,
            'fragment': false,
          }),
        );
        expect(outcome.blocked, isFalse);
        expect(outcome.link, isNotNull);
        expect(outcome.warnings, isEmpty);
        expect(outcome.droppedFields, isEmpty);
      });
    }

    test('pins remain mandatory when insecure is true', () {
      final outcome = NodeShareLinkEncoder.encode(
        tlsOutbound('trojan', {
          'enabled': true,
          'insecure': true,
          'certificate_public_key_sha256': ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='],
        }),
      );
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedTlsNotShareable);
      expect(outcome.link, isNull);
      expect(outcome.droppedFields, contains('tls.certificate_public_key_sha256'));
    });

    test('client certificate chain and key losses are all reported', () {
      final outcome = NodeShareLinkEncoder.encode(
        tlsOutbound('vless', {
          'enabled': true,
          'client_certificate': ['synthetic leaf certificate', 'synthetic intermediate certificate'],
          'client_key': ['synthetic private key'],
        }),
      );
      expect(outcome.blocked, isTrue);
      expect(outcome.link, isNull);
      expect(outcome.droppedFields, containsAll(['tls.client_certificate', 'tls.client_key']));
      expect(outcome.warnings, outcome.droppedFields);
    });

    test('VMess insecure loss is explicit without inventing an import mapping', () {
      final outcome = NodeShareLinkEncoder.encode(tlsOutbound('vmess', {'enabled': true, 'insecure': true}));
      expect(outcome.blocked, isFalse);
      expect(outcome.warnings, contains('tls.insecure'));
      expect(outcome.droppedFields, contains('tls.insecure'));
      final json = jsonDecode(utf8.decode(base64.decode(outcome.link!.substring(8)))) as Map;
      expect(json.containsKey('insecure'), isFalse);
      expect(json.containsKey('allowInsecure'), isFalse);
    });

    for (final type in ['vless', 'trojan']) {
      test('$type keeps the supported insecure query', () {
        final outcome = NodeShareLinkEncoder.encode(tlsOutbound(type, {'enabled': true, 'insecure': true}));
        expect(outcome.blocked, isFalse);
        expect(Uri.parse(outcome.link!).queryParameters['allowInsecure'], '1');
        expect(outcome.droppedFields, isEmpty);
      });
    }

    test('active ECH cannot silently fall back to ordinary TLS', () {
      final outcome = NodeShareLinkEncoder.encode(
        tlsOutbound('vless', {
          'enabled': true,
          'ech': {'enabled': true, 'config_path': 'synthetic-ech.pem'},
        }),
      );
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedTlsNotShareable);
      expect(outcome.link, isNull);
      expect(outcome.droppedFields, containsAll(['tls.ech.enabled', 'tls.ech.config_path']));
    });

    test('unknown nested settings are reported without leaking values or mutating input', () {
      final outbound = tlsOutbound('vless', {
        'enabled': true,
        'utls': {
          'enabled': true,
          'fingerprint': 'chrome',
          'future': {'flag': false},
        },
        'tls_tricks': {'padding_mode': 'synthetic-mode'},
        'future': {
          'items': [
            {'setting': 'synthetic-value'},
          ],
        },
        'engine': 'apple',
        'handshake_timeout': '5s',
      });
      outbound['transport'] = {
        'type': 'ws',
        'path': '/synthetic',
        'max_early_data': 1024,
        'future': {'flag': true},
      };
      outbound['future'] = {'metadata': 'synthetic-metadata'};
      final before = jsonEncode(outbound);
      final outcome = NodeShareLinkEncoder.encode(outbound);
      expect(outcome.blocked, isFalse);
      expect(
        outcome.droppedFields,
        containsAll([
          'tls.utls.future.flag',
          'tls.tls_tricks.padding_mode',
          'tls.future.items[0].setting',
          'tls.engine',
          'tls.handshake_timeout',
          'transport.max_early_data',
          'transport.future.flag',
          'future.metadata',
        ]),
      );
      expect(outcome.warnings, outcome.droppedFields);
      expect(outcome.droppedFields.toSet().length, outcome.droppedFields.length);
      expect(outcome.warnings.join(','), isNot(contains('synthetic-value')));
      expect(jsonEncode(outbound), before);
    });

    test('other real outbound TLS settings all report losses', () {
      final settings = <String, dynamic>{
        'engine': 'apple',
        'disable_sni': true,
        'fragment': true,
        'fragment_fallback_delay': '50ms',
        'record_fragment': true,
        'spoof': 'cover.example.test',
        'spoof_method': 'wrong-sequence',
        'kernel_tx': true,
        'kernel_rx': true,
        'handshake_timeout': '5s',
      };
      final outcome = NodeShareLinkEncoder.encode(tlsOutbound('vless', {'enabled': true, ...settings}));
      expect(outcome.blocked, isFalse);
      expect(outcome.droppedFields, unorderedEquals(settings.keys.map((key) => 'tls.$key')));
      expect(outcome.warnings, outcome.droppedFields);
    });

    test('transport-specific importer ALPN overrides are reported', () {
      final outbound = tlsOutbound('vless', {
        'enabled': true,
        'alpn': ['h2'],
      });
      outbound['transport'] = {'type': 'ws', 'path': '/synthetic'};
      final outcome = NodeShareLinkEncoder.encode(outbound);
      expect(outcome.blocked, isFalse);
      expect(outcome.droppedFields, ['tls.alpn']);
      expect(outcome.warnings, ['tls.alpn']);
    });

    test('Trojan Reality auth is refused rather than reimported as ordinary TLS', () {
      final outcome = NodeShareLinkEncoder.encode(
        tlsOutbound('trojan', {
          'enabled': true,
          'reality': {'enabled': true, 'public_key': 'synthetic-public-key', 'short_id': 'a1'},
        }),
      );
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedRealityNotShareable);
      expect(outcome.link, isNull);
      expect(outcome.droppedFields, contains('tls.reality.public_key'));
    });
  });

  group('vmess', () {
    test('golden link round-trips key fields', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'vmess',
        'tag': 'synthetic-vmess § 0',
        'server': 'vmess.example.test',
        'server_port': 443,
        'uuid': '00000000-0000-4000-8000-000000000001',
        'security': 'auto',
        'tls': {'enabled': true, 'server_name': 'vmess.example.test', 'alpn': 'http/1.1'},
        'transport': {'type': 'ws', 'path': '/xray'},
      });
      expect(outcome.blocked, isFalse);
      final link = outcome.link!;
      expect(link.startsWith('vmess://'), isTrue);
      final decoded = jsonDecode(utf8.decode(base64.decode(link.substring(8)))) as Map<String, dynamic>;
      expect(decoded['ps'], 'synthetic-vmess');
      expect(decoded['add'], 'vmess.example.test');
      expect(decoded['port'], '443');
      expect(decoded['id'], '00000000-0000-4000-8000-000000000001');
      expect(decoded['net'], 'ws');
      expect(decoded['tls'], 'tls');
      expect(decoded['sni'], 'vmess.example.test');
      expect(decoded['path'], '/xray');
    });

    test('reality blocks sharing', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'vmess',
        'tag': 'x',
        'server': 'server.example.test',
        'server_port': 443,
        'uuid': '00000000-0000-4000-8000-000000000001',
        'tls': {
          'enabled': true,
          'reality': {'enabled': true},
        },
      });
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedRealityNotShareable);
    });
  });

  group('vless', () {
    test('golden link with reality', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'vless',
        'tag': 'test § 1',
        'server': 'example.com',
        'server_port': 443,
        'uuid': 'uuid-1',
        'flow': 'xtls-rprx-vision',
        'tls': {
          'enabled': true,
          'server_name': 'example.com',
          'utls': {'fingerprint': 'chrome'},
          'reality': {'enabled': true, 'public_key': 'PUB', 'short_id': 'abc123'},
        },
      });
      expect(outcome.blocked, isFalse);
      final uri = Uri.parse(outcome.link!);
      expect(uri.scheme, 'vless');
      expect(uri.queryParameters['security'], 'reality');
      expect(uri.queryParameters['flow'], 'xtls-rprx-vision');
      expect(uri.queryParameters['pbk'], 'PUB');
      expect(uri.queryParameters['sid'], 'abc123');
      expect(uri.queryParameters['fp'], 'chrome');
      // Display name strips the core ` § N` suffix.
      expect(uri.fragment, 'test');
    });

    test('ipv6 host gets brackets', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'vless',
        'tag': 'v6',
        'server': '2001:db8::1',
        'server_port': 443,
        'uuid': 'uuid-1',
      });
      expect(outcome.link, contains('[2001:db8::1]'));
    });
  });

  group('trojan', () {
    test('password is encoded once', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'trojan',
        'tag': 'tj 中文',
        'server': 'trojan.example.test',
        'server_port': 443,
        'password': 'p@ss:word?',
        'tls': {'enabled': true, 'server_name': 'trojan.example.test'},
      });
      expect(outcome.blocked, isFalse);
      final uri = Uri.parse(outcome.link!);
      // Dart keeps userInfo encoded; decode once to verify single encoding.
      expect(Uri.decodeComponent(uri.userInfo), 'p@ss:word?');
      expect(Uri.decodeComponent(uri.fragment), 'tj 中文');
    });
  });

  group('shadowsocks', () {
    test('classic method uses base64url userinfo', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'shadowsocks',
        'tag': 'ss1',
        'server': 'server.example.test',
        'server_port': 8388,
        'method': 'aes-256-gcm',
        'password': 'pwd',
      });
      expect(outcome.blocked, isFalse);
      expect(outcome.link, startsWith('ss://'));
      final userinfo = Uri.parse(outcome.link!).userInfo;
      final decoded = utf8.decode(base64Url.decode(userinfo.padRight((userinfo.length + 3) ~/ 4 * 4, '=')));
      expect(decoded, 'aes-256-gcm:pwd');
    });

    test('2022 method uses plain encoded userinfo', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'shadowsocks',
        'tag': 'ss2',
        'server': 'server.example.test',
        'server_port': 8388,
        'method': '2022-blake3-aes-128-gcm',
        'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
      });
      expect(outcome.blocked, isFalse);
      expect(outcome.link, contains('2022-blake3-aes-128-gcm:'));
      expect(outcome.link, isNot(contains('MjAyMi')));
    });

    test('plugin becomes query param', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'shadowsocks',
        'tag': 'ss3',
        'server': 'server.example.test',
        'server_port': 8388,
        'method': 'aes-256-gcm',
        'password': 'pwd',
        'plugin': 'obfs-local',
        'plugin_opts': 'obfs=http;obfs-host=cover.example.test',
      });
      final uri = Uri.parse(outcome.link!);
      expect(uri.queryParameters['plugin'], 'obfs-local;obfs=http;obfs-host=cover.example.test');
    });
  });

  group('tuic', () {
    test('golden link keeps uuid:password shape', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'tuic',
        'tag': 'tu § 2',
        'server': '192.0.2.1',
        'server_port': 46294,
        'uuid': 'uuid-9',
        'password': 'pass-9',
        'congestion_control': 'bbr',
        'udp_relay_mode': 'native',
        'tls': {
          'enabled': true,
          'server_name': 'cover.example.test',
          'insecure': true,
          'alpn': ['h3'],
        },
      });
      expect(outcome.blocked, isFalse);
      final uri = Uri.parse(outcome.link!);
      expect(uri.scheme, 'tuic');
      expect(uri.userInfo, 'uuid-9:pass-9');
      expect(uri.queryParameters['congestion_control'], 'bbr');
      expect(uri.queryParameters['allow_insecure'], '1');
      expect(uri.queryParameters['alpn'], 'h3');
    });
  });

  group('hysteria2', () {
    test('golden link with salamander obfs', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'hysteria2',
        'tag': 'hy2',
        'server': 'hysteria2.example.test',
        'server_port': 443,
        'password': 'auth:pw',
        'obfs': {'type': 'salamander', 'password': 'obfs-pw'},
        'tls': {'enabled': true, 'server_name': 'hysteria2.example.test'},
      });
      expect(outcome.blocked, isFalse);
      final uri = Uri.parse(outcome.link!);
      expect(uri.scheme, 'hysteria2');
      expect(Uri.decodeComponent(uri.userInfo), 'auth:pw');
      expect(uri.queryParameters['obfs'], 'salamander');
      expect(uri.queryParameters['obfs-password'], 'obfs-pw');
    });

    test('unknown obfs blocks', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'hysteria2',
        'tag': 'hy2x',
        'server': 'hysteria2.example.test',
        'server_port': 443,
        'password': 'p',
        'obfs': {'type': 'weird'},
        'tls': {'enabled': true},
      });
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedUnsupportedObfs);
    });
  });

  group('blocking and warnings', () {
    test('detour blocks, multiplex warns', () {
      final detour = NodeShareLinkEncoder.encode({
        'type': 'vmess',
        'tag': 'd',
        'server': 'server.example.test',
        'server_port': 443,
        'uuid': 'u',
        'detour': 'other',
      });
      expect(detour.blockedReason, NodeShareLinkEncoder.blockedDetour);

      final mux = NodeShareLinkEncoder.encode({
        'type': 'vmess',
        'tag': 'm',
        'server': 'server.example.test',
        'server_port': 443,
        'uuid': 'u',
        'multiplex': {'enabled': true},
      });
      expect(mux.blocked, isFalse);
      expect(mux.warnings, contains('multiplex'));
    });

    test('missing credentials block', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'trojan',
        'tag': 't',
        'server': 'server.example.test',
        'server_port': 443,
      });
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedMissingField);
    });

    test('unsupported protocol blocks', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'wireguard',
        'tag': 'w',
        'server': 'server.example.test',
        'server_port': 443,
      });
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedUnsupportedProtocol);
    });

    test('unsupported transport blocks', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'vless',
        'tag': 'v',
        'server': 'server.example.test',
        'server_port': 443,
        'uuid': 'u',
        'transport': {'type': 'quic'},
      });
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedUnsupportedTransport);
    });
  });
}
