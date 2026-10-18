import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/node/validation/node_validators.dart';

void main() {
  group('isUuid', () {
    test('accepts standard uuid any case', () {
      expect(NodeValidators.isUuid('38470e24-987f-4854-8d58-40878a9991ae'), isTrue);
      expect(NodeValidators.isUuid('38470E24-987F-4854-8D58-40878A9991AE'), isTrue);
    });

    test('rejects malformed', () {
      expect(NodeValidators.isUuid(''), isFalse);
      expect(NodeValidators.isUuid('not-a-uuid'), isFalse);
      expect(NodeValidators.isUuid('38470e24-987f-4854-8d58-40878a9991a'), isFalse);
      expect(NodeValidators.isUuid(' 38470e24-987f-4854-8d58-40878a9991ae'), isFalse);
    });
  });

  group('isServerAddress', () {
    test('accepts domains and ips', () {
      expect(NodeValidators.isServerAddress('example.com'), isTrue);
      expect(NodeValidators.isServerAddress('a.b.example.co'), isTrue);
      expect(NodeValidators.isServerAddress('1.2.3.4'), isTrue);
      expect(NodeValidators.isServerAddress('2606:4700::1'), isTrue);
      expect(NodeValidators.isServerAddress('[2606:4700::1]'), isTrue);
    });

    test('rejects cidr/scheme/path/port/userinfo', () {
      expect(NodeValidators.isServerAddress(''), isFalse);
      expect(NodeValidators.isServerAddress('1.2.3.0/24'), isFalse);
      expect(NodeValidators.isServerAddress('https://example.com'), isFalse);
      expect(NodeValidators.isServerAddress('example.com/path'), isFalse);
      expect(NodeValidators.isServerAddress('example.com:443'), isFalse);
      expect(NodeValidators.isServerAddress('user@example.com'), isFalse);
      expect(NodeValidators.isServerAddress('999.999.999.999'), isFalse);
      expect(NodeValidators.isServerAddress('not a host'), isFalse);
    });
  });

  group('isRealityPublicKey', () {
    test('accepts 32-byte base64url key', () {
      // 43 chars base64url == 32 bytes.
      expect(NodeValidators.isRealityPublicKey('M'.padRight(43, 'A')), isTrue);
    });

    test('rejects wrong length and garbage', () {
      expect(NodeValidators.isRealityPublicKey(''), isFalse);
      expect(NodeValidators.isRealityPublicKey('short'), isFalse);
      expect(NodeValidators.isRealityPublicKey('!!!not-base64!!!'), isFalse);
    });
  });

  group('isRealityShortId', () {
    test('empty or even hex up to 16 chars', () {
      expect(NodeValidators.isRealityShortId(''), isTrue);
      expect(NodeValidators.isRealityShortId('ab12'), isTrue);
      expect(NodeValidators.isRealityShortId('ABCDEF0123456789'.substring(0, 16)), isTrue);
    });

    test('rejects odd length, non-hex, too long', () {
      expect(NodeValidators.isRealityShortId('abc'), isFalse);
      expect(NodeValidators.isRealityShortId('zz'), isFalse);
      expect(NodeValidators.isRealityShortId('ab' * 9), isFalse);
    });
  });

  group('isShadowsocksKey', () {
    test('non-2022 methods accept any non-empty password', () {
      expect(NodeValidators.isShadowsocksKey('aes-256-gcm', 'pwd'), isTrue);
      expect(NodeValidators.isShadowsocksKey('aes-256-gcm', ''), isFalse);
    });

    test('2022 methods check decoded key length', () {
      // 16 zero bytes -> base64.
      expect(NodeValidators.isShadowsocksKey('2022-blake3-aes-128-gcm', 'AAAAAAAAAAAAAAAAAAAAAA=='), isTrue);
      // 32 zero bytes -> base64.
      expect(
        NodeValidators.isShadowsocksKey('2022-blake3-aes-256-gcm', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='),
        isTrue,
      );
      expect(NodeValidators.isShadowsocksKey('2022-blake3-aes-128-gcm', 'short'), isFalse);
      expect(NodeValidators.isShadowsocksKey('2022-blake3-aes-128-gcm', ''), isFalse);
    });
  });

  group('isDuration/isNonNegativeInt/isPositiveNumber', () {
    test('durations', () {
      expect(NodeValidators.isDuration('10s'), isTrue);
      expect(NodeValidators.isDuration('500ms'), isTrue);
      expect(NodeValidators.isDuration('30'), isTrue);
      expect(NodeValidators.isDuration(''), isFalse);
      expect(NodeValidators.isDuration('abc'), isFalse);
    });

    test('ints and numbers', () {
      expect(NodeValidators.isNonNegativeInt('0'), isTrue);
      expect(NodeValidators.isNonNegativeInt('4'), isTrue);
      expect(NodeValidators.isNonNegativeInt('-1'), isFalse);
      expect(NodeValidators.isPositiveNumber('100'), isTrue);
      expect(NodeValidators.isPositiveNumber('0'), isFalse);
      expect(NodeValidators.isPositiveNumber('-5'), isFalse);
    });
  });

  group('Hysteria2 integer bandwidth', () {
    test('accepts positive decimal integers through the core-safe limit', () {
      for (final value in ['1', '100', ' 200 ', NodeValidators.maxBandwidthMbps.toString()]) {
        expect(NodeValidators.isPositiveNumber(value), isTrue, reason: value);
      }
    });

    test('rejects fractions, non-decimal input and non-finite values', () {
      for (final value in ['', ' ', '100.5', '100.0', '.5', '1e2', '0x64', 'NaN', 'Infinity', 'abc']) {
        expect(NodeValidators.isPositiveNumber(value), isFalse, reason: value);
      }
    });

    test('rejects zero, negatives, conversion overflow and integer overflow', () {
      for (final value in [
        '0',
        '-1',
        (NodeValidators.maxBandwidthMbps + 1).toString(),
        '9223372036854775807',
        '9223372036854775808',
      ]) {
        expect(NodeValidators.isPositiveNumber(value), isFalse, reason: value);
      }
    });
  });

  group('parseAlpn', () {
    test('parses tokens, empty gives empty list', () {
      expect(NodeValidators.parseAlpn(''), isEmpty);
      expect(NodeValidators.parseAlpn('h2, http/1.1'), ['h2', 'http/1.1']);
      expect(NodeValidators.parseAlpn('h2 http/1.1'), ['h2', 'http/1.1']);
    });
  });

  group('vlessCombinationError', () {
    test('empty flow always ok', () {
      expect(NodeValidators.vlessCombinationError(flow: '', transport: 'ws', multiplex: true), isNull);
    });

    test('vision requires tcp without multiplex', () {
      expect(
        NodeValidators.vlessCombinationError(flow: 'xtls-rprx-vision', transport: 'tcp', multiplex: false),
        isNull,
      );
      expect(
        NodeValidators.vlessCombinationError(flow: 'xtls-rprx-vision', transport: 'ws', multiplex: false),
        'visionRequiresTcp',
      );
      expect(
        NodeValidators.vlessCombinationError(flow: 'xtls-rprx-vision', transport: 'tcp', multiplex: true),
        'visionNoMultiplex',
      );
      expect(NodeValidators.vlessCombinationError(flow: 'bogus', transport: 'tcp', multiplex: false), 'unknownFlow');
    });
  });
}
