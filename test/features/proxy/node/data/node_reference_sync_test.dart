import 'dart:convert';

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
      {
        'outbound': 'node-a',
        'domain': ['example.com'],
      },
      {'outbound': 'direct'},
    ],
  },
};

Map<String, dynamic> dependencyConfig() => {
  'outbounds': [
    {'type': 'trojan', 'tag': 'node-a', 'password': 'synthetic-a'},
    {'type': 'trojan', 'tag': 'node-b', 'password': 'synthetic-b'},
    {'type': 'trojan', 'tag': 'chained', 'detour': 'node-a'},
    {
      'type': 'selector',
      'tag': 'select',
      'outbounds': ['node-a', 'node-b'],
      'default': 'node-a',
    },
    {
      'type': 'balancer',
      'tag': 'balance',
      'outbounds': ['node-a', 'node-b'],
    },
  ],
  'endpoints': [
    {
      'type': 'wireguard',
      'tag': 'endpoint-a',
      'detour': 'node-a',
      'metadata': {'detour': 'node-a'},
    },
  ],
  'dns': {
    'servers': [
      {
        'type': 'https',
        'tag': 'node-a',
        'server': 'dns.example.test',
        'detour': 'node-a',
        'domain_resolver': {'server': 'node-a'},
        'tls': {'server_name': 'node-a'},
        'metadata': {'detour': 'node-a'},
      },
      {
        'type': 'group',
        'tag': 'dns-group',
        'servers': ['node-a'],
      },
    ],
    'final': 'node-a',
    'rules': [
      {
        'domain': ['node-a'],
        'server': 'node-a',
      },
    ],
  },
  'ntp': {'detour': 'node-a', 'server': 'node-a'},
  'http_clients': [
    {
      'tag': 'node-a',
      'detour': 'node-a',
      'headers': {'X-Label': 'node-a'},
    },
  ],
  'route': {
    'final': 'node-a',
    'default_domain_resolver': {'server': 'node-a'},
    'rule_set': [
      {
        'type': 'remote',
        'tag': 'node-a',
        'download_detour': 'node-a',
        'http_client': {'detour': 'node-a'},
      },
    ],
    'geoip': {'download_detour': 'node-a'},
    'geosite': {'download_detour': 'node-a'},
  },
  'experimental': {
    'clash_api': {'external_ui_download_detour': 'node-a', 'secret': 'synthetic-secret'},
  },
  'metadata': {
    'dns': {
      'servers': [
        {'detour': 'node-a'},
      ],
    },
    'detour': 'node-a',
  },
};

void main() {
  group('scoped outbound dependencies', () {
    test('DNS detour reaches the service delete guard without a group reference', () {
      final config = <String, dynamic>{
        'dns': {
          'servers': [
            {'type': 'https', 'tag': 'dns', 'detour': 'node-a'},
          ],
        },
      };
      final before = jsonEncode(config);
      final check = NodeReferenceSync.check(config: config, tag: 'node-a');
      expect(check.detours, ['dns.servers[0].detour']);
      expect(check.hasAnyRef, isTrue);
      expect(check.groups, isEmpty);
      expect(check.hasBlockingRefs, isFalse); // Rename is safe; delete checks detours.
      expect(jsonEncode(config), before);
    });

    test('endpoint detour reaches the service delete guard without a group reference', () {
      final config = <String, dynamic>{
        'endpoints': [
          {'type': 'wireguard', 'tag': 'endpoint', 'detour': 'node-a'},
        ],
      };
      final check = NodeReferenceSync.check(config: config, tag: 'node-a');
      expect(check.detours, ['endpoints[0].detour']);
      expect(check.hasAnyRef, isTrue);
      expect(check.groups, isEmpty);
      expect(check.hasBlockingRefs, isFalse);
    });

    test('rename syncs each enumerated dependency and preserves other namespaces', () {
      final config = dependencyConfig();
      final expected = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
      final oldCheck = NodeReferenceSync.check(config: config, tag: 'node-a');
      expect(oldCheck.detours, [
        'chained',
        'endpoints[0].detour',
        'dns.servers[0].detour',
        'ntp.detour',
        'http_clients[0].detour',
        'route.rule_set[0].download_detour',
        'route.rule_set[0].http_client.detour',
        'route.geoip.download_detour',
        'route.geosite.download_detour',
        'experimental.clash_api.external_ui_download_detour',
      ]);
      expect(oldCheck.hasBlockingRefs, isFalse);
      expected['outbounds'][2]['detour'] = 'node-c';
      expected['outbounds'][3]['outbounds'][0] = 'node-c';
      expected['outbounds'][3]['default'] = 'node-c';
      expected['outbounds'][4]['outbounds'][0] = 'node-c';
      expected['endpoints'][0]['detour'] = 'node-c';
      expected['dns']['servers'][0]['detour'] = 'node-c';
      expected['ntp']['detour'] = 'node-c';
      expected['http_clients'][0]['detour'] = 'node-c';
      expected['route']['final'] = 'node-c';
      expected['route']['rule_set'][0]['download_detour'] = 'node-c';
      expected['route']['rule_set'][0]['http_client']['detour'] = 'node-c';
      expected['route']['geoip']['download_detour'] = 'node-c';
      expected['route']['geosite']['download_detour'] = 'node-c';
      expected['experimental']['clash_api']['external_ui_download_detour'] = 'node-c';
      NodeReferenceSync.applyRename(config: config, oldTag: 'node-a', newTag: 'node-c');
      expect(config, expected); // Full comparison also checks metadata and DNS-server tags.
      expect(NodeReferenceSync.check(config: config, tag: 'node-a').hasAnyRef, isFalse);
      final newCheck = NodeReferenceSync.check(config: config, tag: 'node-c');
      expect(newCheck.detours, oldCheck.detours);
      expect(newCheck.groups, ['select', 'balance']);
      expect(newCheck.defaults, ['select']);
    });

    test('replacement retargets DNS and endpoint dependencies before deleting a node', () {
      final config = dependencyConfig();
      // A replacement caller can reuse the rename synchronization for an existing tag.
      NodeReferenceSync.applyRename(config: config, oldTag: 'node-a', newTag: 'node-b');
      final check = NodeReferenceSync.check(config: config, tag: 'node-a');
      expect(check.detours, isEmpty);
      expect(check.hasAnyRef, isFalse);
      expect(NodeReferenceSync.applyDeleteMemberRefs(config: config, tag: 'node-a'), isEmpty);
      (config['outbounds'] as List).removeWhere((o) => (o as Map)['tag'] == 'node-a');
      expect(config['dns']['servers'][0]['detour'], 'node-b');
      expect(config['endpoints'][0]['detour'], 'node-b');
      expect(config['dns']['servers'][0]['tag'], 'node-a');
      expect(config['dns']['final'], 'node-a');
      expect(config['metadata']['detour'], 'node-a');
    });

    test('same strings outside known outbound-reference paths are not scanned or changed', () {
      final config = <String, dynamic>{
        'outbounds': [
          {
            'type': 'trojan',
            'tag': 'node-a',
            'password': 'node-a',
            'outbounds': ['node-a'],
            'default': 'node-a',
            'tls': {'server_name': 'node-a'},
            'domain_resolver': {'server': 'node-a'},
            'metadata': {'detour': 'node-a'},
          },
        ],
        'inbounds': [
          {'tag': 'inbound', 'detour': 'node-a'},
        ],
        'endpoints': [
          {
            'tag': 'node-a',
            'metadata': {'detour': 'node-a'},
          },
        ],
        'dns': {
          'final': 'node-a',
          'servers': [
            {
              'tag': 'node-a',
              'address_resolver': 'node-a',
              'metadata': {'detour': 'node-a'},
            },
            {
              'type': 'group',
              'servers': ['node-a'],
            },
          ],
          'rules': [
            {
              'domain': ['node-a'],
              'server': 'node-a',
            },
          ],
        },
        'route': {
          'rules': [
            {
              'domain': ['node-a'],
              'outbound': 'direct',
            },
          ],
        },
        'metadata': {
          'outbounds': [
            {'detour': 'node-a'},
          ],
        },
      };
      final before = jsonEncode(config);
      expect(NodeReferenceSync.check(config: config, tag: 'node-a').hasAnyRef, isFalse);
      NodeReferenceSync.applyRename(config: config, oldTag: 'node-a', newTag: 'node-c');
      expect(NodeReferenceSync.applyDeleteMemberRefs(config: config, tag: 'node-a'), isEmpty);
      expect(jsonEncode(config), before);
    });

    test('malformed dependency containers are left untouched', () {
      final config = <String, dynamic>{
        'dns': {
          'servers': [
            null,
            7,
            {
              'metadata': {'detour': 'node-a'},
            },
          ],
        },
        'endpoints': 'node-a',
        'route': {
          'rule_set': {'download_detour': 'node-a'},
        },
      };
      final before = jsonEncode(config);
      expect(NodeReferenceSync.check(config: config, tag: 'node-a').hasAnyRef, isFalse);
      NodeReferenceSync.applyRename(config: config, oldTag: 'node-a', newTag: 'node-c');
      expect(jsonEncode(config), before);
    });
  });

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
            {
              'domain': ['node-a'],
              'outbound': 'direct',
            },
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
          {
            'type': 'trojan',
            'tag': 'old',
            'password': 'old',
            'tls': {'server_name': 'old'},
          },
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
