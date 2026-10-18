import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/data/node_protocol_templates.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/validation/node_validators.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_common_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_multiplex_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_tls_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_transport_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/hysteria2_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/shadowsocks_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/trojan_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/tuic_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/vless_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/vmess_fields.dart';
import 'package:hiddify/singbox/model/singbox_proxy_type.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _profileId = 'node-fields-only';
const _rawTag = 'node';
const _uuid = '38470e24-987f-4854-8d58-40878a9991ae';

// Only loading is replaced: field edits and validation use the real notifier.
// No config service, filesystem, connection or device is involved.
class _DraftNotifier extends NodeEditorNotifier {
  _DraftNotifier(this.initial);

  final NodeEditorState initial;

  @override
  Future<NodeEditorState> build(String profileId, String? rawTag) async => initial;
}

class _Fields extends ConsumerWidget {
  const _Fields({required this.rawTag});

  final String? rawTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = nodeEditorNotifierProvider(_profileId, rawTag);
    final data = ref.watch(provider).requireValue;
    final protocol = data.draft['type'];
    final hasTransport = ['vmess', 'vless', 'trojan'].contains(protocol);
    return Column(
      children: [
        NodeCommonFields(
          profileId: _profileId,
          rawTag: rawTag,
          data: data,
          onProtocolSwitch: (next) =>
              ref.read(provider.notifier).switchProtocol(next, keepName: NodeJson.asString(data.draft['tag']) ?? ''),
        ),
        switch (protocol) {
          'vmess' => VmessFields(profileId: _profileId, rawTag: rawTag, data: data),
          'vless' => VlessFields(profileId: _profileId, rawTag: rawTag, data: data),
          'trojan' => TrojanFields(profileId: _profileId, rawTag: rawTag, data: data),
          'shadowsocks' => ShadowsocksFields(profileId: _profileId, rawTag: rawTag, data: data),
          'tuic' => TuicFields(profileId: _profileId, rawTag: rawTag, data: data),
          'hysteria2' => Hysteria2Fields(profileId: _profileId, rawTag: rawTag, data: data),
          _ => const SizedBox.shrink(),
        },
        if (hasTransport) NodeTransportFields(profileId: _profileId, rawTag: rawTag, data: data),
        if (hasTransport || protocol == 'tuic' || protocol == 'hysteria2')
          NodeTlsFields(
            profileId: _profileId,
            rawTag: rawTag,
            data: data,
            allowReality: protocol == 'vless',
            tlsRequired: protocol == 'tuic' || protocol == 'hysteria2',
          ),
        if (hasTransport) NodeMultiplexFields(profileId: _profileId, rawTag: rawTag, data: data),
      ],
    );
  }
}

Map<String, dynamic> _draft(String protocol) => NodeProtocolTemplates.create(protocol, _rawTag)
  ..addAll({
    'server': 'node.example.com',
    if (['vmess', 'vless', 'tuic'].contains(protocol)) 'uuid': _uuid,
    if (['trojan', 'shadowsocks', 'tuic', 'hysteria2'].contains(protocol)) 'password': 'password',
  });

Future<ProviderContainer> _mount(
  WidgetTester tester,
  Map<String, dynamic> draft, {
  bool isNew = false,
  GlobalKey<FormState>? formKey,
  AutovalidateMode autovalidateMode = AutovalidateMode.disabled,
}) async {
  final rawTag = isNew ? null : _rawTag;
  final initial = NodeEditorState(
    profile: ProfileEntity.local(id: _profileId, active: false, name: 'Fields test', lastUpdate: DateTime.utc(2026)),
    rawContentSnapshot: '',
    draft: NodeJson.deepCopyMap(draft),
    originalDraft: NodeJson.deepCopyMap(draft),
    rawTag: rawTag,
    isNew: isNew,
  );
  final container = ProviderContainer(
    overrides: [
      translationsProvider.overrideWith((ref) => TranslationsEn()),
      nodeEditorNotifierProvider(_profileId, rawTag).overrideWith(() => _DraftNotifier(initial)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(translationsProvider.future);
  await container.read(nodeEditorNotifierProvider(_profileId, rawTag).future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Form(
              key: formKey,
              autovalidateMode: autovalidateMode,
              child: _Fields(rawTag: rawTag),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _textField(String label) => find.descendant(
  of: find.byWidgetPredicate((widget) => widget is CustomTextFormField && widget.label == label),
  matching: find.byType(TextFormField),
);

TextEditingController _controller(WidgetTester tester, String label) =>
    tester.widget<TextFormField>(_textField(label)).controller!;

String? _formValue(WidgetTester tester, String label) => tester.state<FormFieldState<String>>(_textField(label)).value;

Finder _dropdown(String label) => find.descendant(
  of: find.byWidgetPredicate((widget) => widget is NodeDropdownField<String> && widget.label == label),
  matching: find.byType(DropdownButton<String>),
);

NodeEditorState _data(ProviderContainer container, {bool isNew = false}) =>
    container.read(nodeEditorNotifierProvider(_profileId, isNew ? null : _rawTag)).requireValue;

void main() {
  final t = TranslationsEn();
  final fields = t.pages.nodeEditor.fields;

  for (final protocol in ['vmess', 'vless', 'trojan']) {
    for (final transport in ['http', 'quic']) {
      testWidgets('$protocol with $transport opens read-only transport without changing original JSON', (tester) async {
        final original = _draft(protocol)
          ..['transport'] = <String, dynamic>{
            'type': transport,
            if (transport == 'http') ...{
              'host': ['transport.example.com'],
              'path': '/tunnel',
              'method': 'POST',
              'headers': {
                'X-Keep': ['original'],
              },
              'idle_timeout': '15s',
            },
          }
          ..['tls'] = {
            'enabled': true,
            'server_name': 'tls.example.com',
            'alpn': ['h2'],
          }
          ..['tcp_fast_open'] = true;
        final before = NodeJson.deepCopyMap(original);
        final container = await _mount(tester, original);
        expect(tester.takeException(), isNull);
        final dropdown = tester.widget<DropdownButton<String>>(_dropdown(fields.transport));
        expect(dropdown.value, transport);
        expect(dropdown.onChanged, isNull);
        expect(dropdown.items!.singleWhere((item) => item.value == transport).enabled, isFalse);
        expect(find.text(t.pages.nodeEditor.help.unsupportedFieldsPreserved), findsOneWidget);
        expect(_data(container).draft, before);
        expect(_data(container).isDirty, isFalse);

        await tester.ensureVisible(_dropdown(fields.transport));
        await tester.tap(_dropdown(fields.transport));
        await tester.pumpAndSettle();
        expect(_data(container).draft, before);
        await tester.ensureVisible(_textField(fields.port));
        await tester.enterText(_textField(fields.port), '8443');
        await tester.pump();
        final decoded = NodeJson.deepCopyMap(_data(container).draft);
        expect(decoded, {...before, 'server_port': 8443});
        expect(_data(container).originalDraft, before);
        expect(original, before);
        expect(tester.takeException(), isNull);
      });
    }
  }

  final unknownDropdowns = <(String, String, String, Map<String, dynamic>)>[
    ('vmess', fields.encryption, 'aes-128-cfb', {'security': 'aes-128-cfb'}),
    ('vless', fields.flow, 'future-flow', {'flow': 'future-flow'}),
    ('vless', fields.packetEncoding, 'future-packet', {'packet_encoding': 'future-packet'}),
    ('shadowsocks', fields.method, 'aes-128-ctr', {'method': 'aes-128-ctr'}),
    ('shadowsocks', fields.plugin, 'future-plugin', {'plugin': 'future-plugin', 'plugin_opts': 'keep=original'}),
    ('tuic', fields.congestionControl, 'future-cc', {'congestion_control': 'future-cc'}),
    ('tuic', fields.udpRelayMode, 'future-relay', {'udp_relay_mode': 'future-relay'}),
    (
      'hysteria2',
      fields.obfs,
      'gecko',
      {
        'obfs': {'type': 'gecko', 'password': 'keep-password', 'min_packet_size': 100},
      },
    ),
    (
      'vmess',
      fields.multiplexProtocol,
      'future-mux',
      {
        'multiplex': {'enabled': true, 'protocol': 'future-mux', 'padding': true},
      },
    ),
    (
      'vmess',
      fields.fingerprint,
      'chrome_psk',
      {
        'tls': {
          'enabled': true,
          'utls': {'enabled': true, 'fingerprint': 'chrome_psk'},
        },
      },
    ),
    (
      'trojan',
      fields.tlsMode,
      'reality',
      {
        'tls': {
          'enabled': true,
          'reality': {'enabled': true, 'public_key': 'keep', 'short_id': 'abcd'},
        },
      },
    ),
    ('hysteria2', fields.tlsMode, 'none', {'tls': null}),
  ];
  for (final (protocol, label, value, patch) in unknownDropdowns) {
    testWidgets('$protocol $label preserves the unsupported initial value instead of a default', (tester) async {
      final original = _draft(protocol)..addAll(patch);
      final before = NodeJson.deepCopyMap(original);
      final container = await _mount(tester, original);
      expect(tester.takeException(), isNull);
      final dropdown = tester.widget<DropdownButton<String>>(_dropdown(label));
      expect(dropdown.value, value);
      expect(dropdown.onChanged, isNull);
      expect(dropdown.items!.singleWhere((item) => item.value == value).enabled, isFalse);
      expect(_data(container).isDirty, isFalse);
      await tester.enterText(_textField(fields.server), 'changed.example.com');
      await tester.pump();
      expect(NodeJson.deepCopyMap(_data(container).draft), {...before, 'server': 'changed.example.com'});
      expect(_data(container).originalDraft, before);
      expect(original, before);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unknown protocol dropdown preserves its raw value without asserting', (tester) async {
    final original = _draft('vmess')..['type'] = 'future-protocol';
    final before = NodeJson.deepCopyMap(original);
    final container = await _mount(tester, original);
    final dropdown = tester.widget<DropdownButton<String>>(_dropdown(fields.protocol));
    expect(dropdown.value, 'future-protocol');
    expect(dropdown.onChanged, isNull);
    expect(_data(container).draft, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('programmatic transport replacement updates selection and reused text fields', (tester) async {
    final original = _draft('vmess')
      ..['transport'] = {
        'type': 'ws',
        'path': '/old',
        'headers': {'Host': 'old.example.com'},
      };
    final container = await _mount(tester, original, autovalidateMode: AutovalidateMode.always);
    final notifier = container.read(nodeEditorNotifierProvider(_profileId, _rawTag).notifier);
    notifier.setPath(['transport'], {'type': 'httpupgrade', 'host': 'new.example.com', 'path': '/new'});
    await tester.pumpAndSettle();
    final draft = _data(container).draft;
    expect(tester.widget<DropdownButton<String>>(_dropdown(fields.transport)).value, 'httpupgrade');
    expect(_controller(tester, fields.hostHeader).text, 'new.example.com');
    expect(_controller(tester, fields.path).text, '/new');
    expect(_formValue(tester, fields.hostHeader), NodeJson.getPath(draft, ['transport', 'host']));
    expect(_formValue(tester, fields.path), NodeJson.getPath(draft, ['transport', 'path']));
    expect(original['transport'], {
      'type': 'ws',
      'path': '/old',
      'headers': {'Host': 'old.example.com'},
    });
    expect(tester.takeException(), isNull);
  });

  for (final protocol in ['vmess', 'vless']) {
    testWidgets('$protocol Generate UUID updates the existing controller and the draft', (tester) async {
      final container = await _mount(tester, _draft(protocol), autovalidateMode: AutovalidateMode.always);
      final controller = _controller(tester, fields.uuid);
      expect(controller.text, _uuid);
      final button = find.text(t.pages.nodeEditor.actions.generateUuid);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final first = _data(container).draft['uuid'] as String;
      expect(NodeValidators.isUuid(first), isTrue);
      expect(first, isNot(_uuid));
      expect(_controller(tester, fields.uuid), same(controller));
      expect(controller.text, first);
      expect(_formValue(tester, fields.uuid), first);
      expect(tester.takeException(), isNull);

      await tester.tap(button);
      await tester.pumpAndSettle();
      final second = _data(container).draft['uuid'] as String;
      expect(NodeValidators.isUuid(second), isTrue);
      expect(second, isNot(first));
      expect(controller.text, second);
      expect(_controller(tester, fields.uuid), same(controller));
      expect(_formValue(tester, fields.uuid), second);
      expect(_data(container).originalDraft['uuid'], _uuid);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new-node protocol switch resets visible server and port without replacing their controllers', (
    tester,
  ) async {
    final container = await _mount(tester, _draft('vmess'), isNew: true, autovalidateMode: AutovalidateMode.always);
    final serverController = _controller(tester, fields.server);
    final portController = _controller(tester, fields.port);
    await tester.enterText(_textField(fields.server), 'edited.example.com');
    await tester.enterText(_textField(fields.port), '8443');
    await tester.pump();
    expect(_data(container, isNew: true).draft['server'], 'edited.example.com');
    expect(_data(container, isNew: true).draft['server_port'], 8443);

    await tester.tap(_dropdown(fields.protocol));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ProxyType.fromJson('vless').label).last);
    await tester.pumpAndSettle();
    final data = _data(container, isNew: true);
    expect(data.draft['type'], 'vless');
    expect(serverController.text, data.draft['server']);
    expect(serverController.text, isEmpty);
    expect(portController.text, data.draft['server_port'].toString());
    expect(portController.text, '443');
    expect(_formValue(tester, fields.server), data.draft['server']);
    expect(_formValue(tester, fields.port), data.draft['server_port'].toString());
    expect(_controller(tester, fields.server), same(serverController));
    expect(_controller(tester, fields.port), same(portController));
    expect(tester.widget<DropdownButton<String>>(_dropdown(fields.protocol)).value, 'vless');
    expect(tester.takeException(), isNull);
  });

  testWidgets('node typing preserves raw input, focus, selection and IME through trimmed draft rebuilds', (
    tester,
  ) async {
    final container = await _mount(tester, _draft('vmess'), isNew: true);
    await tester.showKeyboard(_textField(fields.server));
    final controller = _controller(tester, fields.server);
    final editableFinder = find.descendant(of: _textField(fields.server), matching: find.byType(EditableText));
    final editable = tester.widget<EditableText>(editableFinder);
    final state = tester.state<EditableTextState>(editableFinder);
    for (final text in ['a ', 'ab ', 'abc ']) {
      final value = TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: 0, extentOffset: text.length - 1),
        composing: TextRange(start: 0, end: text.length - 1),
      );
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
      expect(_data(container, isNew: true).draft['server'], text.trim());
      expect(controller.value, value);
      expect(_controller(tester, fields.server), same(controller));
      expect(tester.state<EditableTextState>(editableFinder), same(state));
      expect(tester.widget<EditableText>(editableFinder).focusNode, same(editable.focusNode));
      expect(editable.focusNode.hasFocus, isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  for (final (key, label) in [('up_mbps', fields.uploadMbps), ('down_mbps', fields.downloadMbps)]) {
    testWidgets('Hysteria2 $key rejects malformed bandwidth without dropping the input', (tester) async {
      final formKey = GlobalKey<FormState>();
      final container = await _mount(tester, _draft('hysteria2'), formKey: formKey);
      final notifier = container.read(nodeEditorNotifierProvider(_profileId, _rawTag).notifier);
      await tester.ensureVisible(_textField(label));
      for (final input in [
        '100.5',
        '100.0',
        '1e2',
        '0x64',
        'abc',
        'NaN',
        'Infinity',
        '0',
        '-1',
        (NodeValidators.maxBandwidthMbps + 1).toString(),
        '9223372036854775808',
      ]) {
        await tester.enterText(_textField(label), input);
        await tester.pump();
        expect(_data(container).draft.containsKey(key), isTrue, reason: input);
        expect(_data(container).draft[key].toString(), input);
        expect(_controller(tester, label).text, input);
        expect(formKey.currentState!.validate(), isFalse, reason: input);
        expect(notifier.validate(t), isFalse, reason: input);
        await tester.pump();
        expect(_data(container).fieldErrors[key], t.errors.nodes.invalidNumber);
      }
      await tester.enterText(_textField(label), '');
      await tester.pump();
      expect(_data(container).draft.containsKey(key), isFalse);
      expect(notifier.validate(t), isTrue);
      await tester.pump();
      expect(formKey.currentState!.validate(), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Hysteria2 integer and unset bandwidths round-trip without doubles or null settings', (tester) async {
    final original = _draft('hysteria2')..addAll({'up_mbps': 100, 'down_mbps': 200});
    final container = await _mount(tester, original);
    expect(_controller(tester, fields.uploadMbps).text, '100');
    expect(_controller(tester, fields.downloadMbps).text, '200');
    expect(_data(container).draft, original);
    await tester.ensureVisible(_textField(fields.uploadMbps));
    await tester.enterText(_textField(fields.uploadMbps), '300');
    await tester.enterText(_textField(fields.downloadMbps), '');
    await tester.pump();
    final notifier = container.read(nodeEditorNotifierProvider(_profileId, _rawTag).notifier);
    expect(notifier.validate(t), isTrue);
    final decoded = NodeJson.deepCopyMap(_data(container).draft);
    expect(decoded['up_mbps'], isA<int>());
    expect(decoded['up_mbps'], 300);
    expect(decoded.containsKey('down_mbps'), isFalse);
    expect(original['up_mbps'], 100);
    expect(original['down_mbps'], 200);
    expect(tester.takeException(), isNull);
  });
}
