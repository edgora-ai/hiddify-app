import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/node/data/node_reference_sync.dart';

Map<String, dynamic> sampleConfig() => {
  'outbounds': [
    {'type': 'vmess', 'tag': 'node-a', 'server': 'a.com', 'server_port': 443},
    {'type': 'vmess', 'tag': 'node-b', 'server': 'b.com', 'server_port': 443},
    {
      'type': 'selector',
      'tag': 'select',
      'outbounds': ['node-a', 'node-b'],
      'default': 'node-a',
    },
    {'type': 'trojan', 'tag': 'node-c', 'server': 'c.com', 'server_port': 443, 'detour': 'node-a'},
  ],
  'route': {
    'final': 'select',
    'rules': [
      {'outbound': 'node-a', 'domain': ['example.com']},
      {'outbound': 'direct'},
    ],
  },
};

void main() {
  group('check', () {
    test('finds group, default, detour and rule refs', () {
      final check = NodeReferenceSync.check(config: sampleConfig(), tag: 'node-a');
      expect(check.groups, ['select']);
      expect(check.defaults, ['select']);
      expect(check.detours, ['node-c']);
      expect(check.ruleTargets, ['route.rules[0]']);
      expect(check.finalRoute, isFalse);
      expect(check.hasBlockingRefs, isTrue);
    });

    test('no refs for unreferenced tag', () {
      final check = NodeReferenceSync.check(config: sampleConfig(), tag: 'node-b');
      expect(check.groups, ['select']);
      expect(check.hasBlockingRefs, isFalse);
      expect(check.detours, isEmpty);
    });

    test('detects include patterns as blocking', () {
      final config = {
        'outbounds': [
          {'type': 'selector', 'tag': 'g', 'outbounds': [], 'include': 'node-.*'},
        ],
      };
      final check = NodeReferenceSync.check(config: config, tag: 'node-a');
      expect(check.patternRefs, ['g.include']);
      expect(check.hasBlockingRefs, isTrue);
    });

    test('match conditions are not treated as refs', () {
      final config = {
        'outbounds': [],
        'route': {
          'rules': [
            {'domain': ['node-a'], 'outbound': 'direct'},
          ],
        },
      };
      final check = NodeReferenceSync.check(config: config, tag: 'node-a');
      expect(check.hasAnyRef, isFalse);
    });

    test('nested rules are scanned', () {
      final config = {
        'outbounds': [],
        'route': {
          'rules': [
            {
              'rules': [
                {'outbound': 'node-a'},
              ],
            },
          ],
        },
      };
      final check = NodeReferenceSync.check(config: config, tag: 'node-a');
      expect(check.ruleTargets, ['route.rules[0].rules[0]']);
    });
  });

  group('applyRename', () {
    test('syncs known refs without touching passwords or sni', () {
      final config = <String, dynamic>{
        'outbounds': [
          {'type': 'trojan', 'tag': 'old', 'password': 'old', 'tls': {'server_name': 'old'}},
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['old'],
            'default': 'old',
          },
          {'type': 'vmess', 'tag': 'x', 'detour': 'old'},
        ],
        'route': {'final': 'old'},
      };
      NodeReferenceSync.applyRename(config: config, oldTag: 'old', newTag: 'new');
      final outbounds = config['outbounds'] as List;
      final selector = outbounds[1] as Map<String, dynamic>;
      expect(selector['outbounds'], ['new']);
      expect(selector['default'], 'new');
      expect((outbounds[2] as Map)['detour'], 'new');
      expect((config['route'] as Map)['final'], 'new');
      // Credentials and SNI untouched.
      final node = outbounds[0] as Map<String, dynamic>;
      expect(node['password'], 'old');
      expect((node['tls'] as Map)['server_name'], 'old');
    });
  });

  group('applyDeleteMemberRefs', () {
    test('removes members and reports groups', () {
      final config = sampleConfig();
      final touched = NodeReferenceSync.applyDeleteMemberRefs(config: config, tag: 'node-a');
      expect(touched, ['select']);
      final outbounds = config['outbounds'] as List;
      final selector = outbounds[2] as Map<String, dynamic>;
      expect(selector['outbounds'], ['node-b']);
    });
  });
}
