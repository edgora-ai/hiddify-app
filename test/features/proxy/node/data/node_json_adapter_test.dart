import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';

void main() {
  group('getPath', () {
    test('reads nested values', () {
      final m = {
        'tls': {
          'reality': {'public_key': 'abc'},
        },
      };
      expect(NodeJson.getPath(m, ['tls', 'reality', 'public_key']), 'abc');
      expect(NodeJson.getPath(m, ['tls', 'missing']), isNull);
      expect(NodeJson.getPath(m, ['nope', 'x']), isNull);
      // non-Map hop returns null instead of throwing
      expect(NodeJson.getPath(m, ['tls', 'reality', 'public_key', 'deep']), isNull);
    });
  });

  group('putPath', () {
    test('creates intermediate maps', () {
      final m = <String, dynamic>{};
      NodeJson.putPath(m, ['transport', 'type'], 'ws');
      expect(m, {
        'transport': {'type': 'ws'},
      });
    });

    test('null deletes leaf and prunes empty parents', () {
      final m = <String, dynamic>{
        'server': 'x.com',
        'tls': {
          'enabled': true,
          'reality': {'enabled': true},
        },
      };
      NodeJson.putPath(m, ['tls', 'reality'], null);
      expect(m['tls'], {'enabled': true});

      NodeJson.putPath(m, ['tls'], null);
      expect(m.containsKey('tls'), isFalse);
      expect(m['server'], 'x.com');
    });

    test('prunes multi-level empty parents', () {
      final m = <String, dynamic>{
        'tls': {
          'utls': {'fingerprint': 'chrome'},
        },
      };
      NodeJson.putPath(m, ['tls', 'utls', 'fingerprint'], null);
      expect(m.containsKey('tls'), isFalse);
    });

    test('keeps non-empty siblings', () {
      final m = <String, dynamic>{
        'transport': {
          'type': 'ws',
          'path': '/x',
          'headers': {'Host': 'h.com'},
        },
      };
      NodeJson.putPath(m, ['transport', 'path'], null);
      expect(m['transport'], {
        'type': 'ws',
        'headers': {'Host': 'h.com'},
      });
    });

    test('overwrites non-map hop with a map', () {
      final m = <String, dynamic>{'tls': 'bogus'};
      NodeJson.putPath(m, ['tls', 'enabled'], true);
      expect(m['tls'], {'enabled': true});
    });
  });

  group('splitTagSuffix', () {
    test('splits core display suffix', () {
      expect(NodeJson.splitTagSuffix('Kr-xg § 0'), ('Kr-xg', ' § 0'));
      expect(NodeJson.splitTagSuffix('洛杉矶-2 § 33'), ('洛杉矶-2', ' § 33'));
    });

    test('leaves other tags whole', () {
      expect(NodeJson.splitTagSuffix('plain'), ('plain', ''));
      expect(NodeJson.splitTagSuffix('a § b'), ('a § b', ''));
      expect(NodeJson.splitTagSuffix('x§1'), ('x§1', ''));
    });
  });

  group('transport mapping', () {
    test('missing transport reads as tcp', () {
      expect(NodeJson.transportTypeOf({'type': 'vmess'}), 'tcp');
      expect(NodeJson.transportTypeOf({'transport': 'bogus'}), 'tcp');
      expect(NodeJson.transportTypeOf({'transport': {'type': 'ws'}}), 'ws');
    });

    test('tcp selection removes transport object', () {
      final m = <String, dynamic>{
        'transport': {'type': 'ws', 'path': '/x'},
      };
      NodeJson.applyTransportType(m, 'tcp');
      expect(m.containsKey('transport'), isFalse);
    });

    test('non-tcp selection sets type, keeps siblings', () {
      final m = <String, dynamic>{
        'transport': {'type': 'ws', 'path': '/x'},
      };
      NodeJson.applyTransportType(m, 'grpc');
      final transport = m['transport'] as Map<String, dynamic>;
      expect(transport['type'], 'grpc');
      expect(transport['path'], '/x');
    });
  });

  group('tls mode mapping', () {
    test('reads none/tls/reality', () {
      expect(NodeJson.tlsModeOf({}), 'none');
      expect(NodeJson.tlsModeOf({'tls': {'enabled': false}}), 'none');
      expect(NodeJson.tlsModeOf({'tls': {'enabled': true}}), 'tls');
      expect(NodeJson.tlsModeOf({'tls': {'enabled': true, 'reality': {'enabled': true}}}), 'reality');
      expect(NodeJson.tlsModeOf({'tls': {'enabled': true, 'reality': {'enabled': false}}}), 'tls');
    });

    test('applies modes, preserves unknown siblings', () {
      final m = <String, dynamic>{
        'tls': {'enabled': true, 'server_name': 's.com', 'custom_keep': 1},
      };
      NodeJson.applyTlsMode(m, 'reality');
      var tls = m['tls'] as Map<String, dynamic>;
      expect(tls['reality'], {'enabled': true});
      expect(tls['server_name'], 's.com');
      expect(tls['custom_keep'], 1);

      NodeJson.applyTlsMode(m, 'tls');
      tls = m['tls'] as Map<String, dynamic>;
      expect(tls.containsKey('reality'), isFalse);
      expect(tls['enabled'], isTrue);

      NodeJson.applyTlsMode(m, 'none');
      expect(m.containsKey('tls'), isFalse);
    });
  });

  group('putHeader', () {
    test('updates existing key preserving case', () {
      final h = <String, dynamic>{'Host': 'a.com', 'X': '1'};
      NodeJson.putHeader(h, 'host', 'b.com');
      expect(h, {'Host': 'b.com', 'X': '1'});
    });

    test('adds with preferred key, removes on empty', () {
      final h = <String, dynamic>{};
      NodeJson.putHeader(h, 'Host', 'a.com');
      expect(h, {'Host': 'a.com'});
      NodeJson.putHeader(h, 'host', '');
      expect(h, isEmpty);
    });
  });

  group('asInt/asStringList', () {
    test('asInt handles int and numeric strings', () {
      expect(NodeJson.asInt(443), 443);
      expect(NodeJson.asInt('8080'), 8080);
      expect(NodeJson.asInt('x'), isNull);
      expect(NodeJson.asInt(null), isNull);
    });

    test('asStringList handles string and list alpn', () {
      expect(NodeJson.asStringList('http/1.1'), ['http/1.1']);
      expect(NodeJson.asStringList(['h2', 'http/1.1']), ['h2', 'http/1.1']);
      expect(NodeJson.asStringList(null), isEmpty);
    });
  });

  group('deepCopyMap', () {
    test('edits on copy leave original untouched', () {
      final orig = {
        'tls': {'enabled': true},
      };
      final copy = NodeJson.deepCopyMap(orig);
      (copy['tls'] as Map)['enabled'] = false;
      expect(orig['tls'], {'enabled': true});
    });
  });
}
