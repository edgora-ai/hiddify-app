import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/node/data/node_share_link_encoder.dart';

void main() {
  group('vmess', () {
    test('golden link round-trips key fields', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'vmess',
        'tag': 'Kr-xg § 0',
        'server': 'Kr-xray.hroze.org',
        'server_port': 443,
        'uuid': '38470e24-987f-4854-8d58-40878a9991ae',
        'security': 'auto',
        'tls': {'enabled': true, 'server_name': 'Kr-xray.hroze.org', 'alpn': 'http/1.1'},
        'transport': {'type': 'ws', 'path': '/xray'},
      });
      expect(outcome.blocked, isFalse);
      final link = outcome.link!;
      expect(link.startsWith('vmess://'), isTrue);
      final decoded = jsonDecode(utf8.decode(base64.decode(link.substring(8)))) as Map<String, dynamic>;
      expect(decoded['ps'], 'Kr-xg');
      expect(decoded['add'], 'Kr-xray.hroze.org');
      expect(decoded['port'], '443');
      expect(decoded['id'], '38470e24-987f-4854-8d58-40878a9991ae');
      expect(decoded['net'], 'ws');
      expect(decoded['tls'], 'tls');
      expect(decoded['sni'], 'Kr-xray.hroze.org');
      expect(decoded['path'], '/xray');
    });

    test('reality blocks sharing', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'vmess',
        'tag': 'x',
        'server': 's.com',
        'server_port': 443,
        'uuid': '38470e24-987f-4854-8d58-40878a9991ae',
        'tls': {'enabled': true, 'reality': {'enabled': true}},
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
        'server': '2606:4700::1',
        'server_port': 443,
        'uuid': 'uuid-1',
      });
      expect(outcome.link, contains('[2606:4700::1]'));
    });
  });

  group('trojan', () {
    test('password is encoded once', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'trojan',
        'tag': 'tj 中文',
        'server': 't.com',
        'server_port': 443,
        'password': 'p@ss:word?',
        'tls': {'enabled': true, 'server_name': 't.com'},
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
        'server': 's.com',
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
        'server': 's.com',
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
        'server': 's.com',
        'server_port': 8388,
        'method': 'aes-256-gcm',
        'password': 'pwd',
        'plugin': 'obfs-local',
        'plugin_opts': 'obfs=http;obfs-host=www.bing.com',
      });
      final uri = Uri.parse(outcome.link!);
      expect(uri.queryParameters['plugin'], 'obfs-local;obfs=http;obfs-host=www.bing.com');
    });
  });

  group('tuic', () {
    test('golden link keeps uuid:password shape', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'tuic',
        'tag': 'tu § 2',
        'server': '152.70.241.120',
        'server_port': 46294,
        'uuid': 'uuid-9',
        'password': 'pass-9',
        'congestion_control': 'bbr',
        'udp_relay_mode': 'native',
        'tls': {'enabled': true, 'server_name': 'www.bing.com', 'insecure': true, 'alpn': ['h3']},
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
        'server': 'h.com',
        'server_port': 443,
        'password': 'auth:pw',
        'obfs': {'type': 'salamander', 'password': 'obfs-pw'},
        'tls': {'enabled': true, 'server_name': 'h.com'},
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
        'server': 'h.com',
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
        'server': 's.com',
        'server_port': 443,
        'uuid': 'u',
        'detour': 'other',
      });
      expect(detour.blockedReason, NodeShareLinkEncoder.blockedDetour);

      final mux = NodeShareLinkEncoder.encode({
        'type': 'vmess',
        'tag': 'm',
        'server': 's.com',
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
        'server': 's.com',
        'server_port': 443,
      });
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedMissingField);
    });

    test('unsupported protocol blocks', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'wireguard',
        'tag': 'w',
        'server': 's.com',
        'server_port': 443,
      });
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedUnsupportedProtocol);
    });

    test('unsupported transport blocks', () {
      final outcome = NodeShareLinkEncoder.encode({
        'type': 'vless',
        'tag': 'v',
        'server': 's.com',
        'server_port': 443,
        'uuid': 'u',
        'transport': {'type': 'quic'},
      });
      expect(outcome.blockedReason, NodeShareLinkEncoder.blockedUnsupportedTransport);
    });
  });
}
