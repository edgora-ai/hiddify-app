import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// TLS section. [allowReality] gates the Reality option (v1: vless only);
/// [tlsRequired] hides the "none" option (tuic/hysteria2).
class NodeTlsFields extends HookConsumerWidget {
  const NodeTlsFields({
    super.key,
    required this.profileId,
    required this.rawTag,
    required this.data,
    this.allowReality = false,
    this.tlsRequired = false,
  });

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;
  final bool allowReality;
  final bool tlsRequired;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final errors = data.fieldErrors;
    var mode = NodeJson.tlsModeOf(draft);
    if (tlsRequired && mode == 'none') mode = 'tls';
    if (mode == 'reality' && !allowReality) mode = 'tls';

    final modes = [if (!tlsRequired) 'none', 'tls', if (allowReality) 'reality'];
    String modeLabel(String m) => switch (m) {
      'none' => t.pages.nodeEditor.options.noTls,
      'tls' => t.pages.nodeEditor.options.tls,
      'reality' => t.pages.nodeEditor.options.reality,
      _ => m,
    };

    final fp = NodeJson.asString(NodeJson.getPath(draft, ['tls', 'utls', 'fingerprint'])) ?? '';
    final alpn = NodeJson.asStringList(NodeJson.getPath(draft, ['tls', 'alpn'])).join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodeSectionHeader(t.pages.nodeEditor.sections.tls),
        if (tlsRequired)
          NodeFieldPadding(
            child: Text(t.pages.nodeEditor.help.tlsRequired, style: Theme.of(context).textTheme.bodySmall),
          ),
        NodeFieldPadding(
          child: NodeDropdownField<String>(
            label: t.pages.nodeEditor.fields.tlsMode,
            value: mode,
            items: [for (final m in modes) DropdownMenuItem(value: m, child: Text(modeLabel(m)))],
            onChanged: (v) {
              if (v == null) return;
              notifier.setTlsMode(v);
            },
          ),
        ),
        if (mode != 'none') ...[
          NodeFieldPadding(
            child: CustomTextFormField(
              label: t.pages.nodeEditor.fields.serverName,
              hint: 'SNI',
              initialValue: NodeJson.asString(NodeJson.getPath(draft, ['tls', 'server_name'])) ?? '',
              maxLines: 1,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              onChanged: (v) => notifier.setPath(['tls', 'server_name'], v.trim().isEmpty ? null : v.trim()),
            ),
          ),
          NodeFieldPadding(
            child: CustomTextFormField(
              label: t.pages.nodeEditor.fields.alpn,
              hint: 'h2, http/1.1',
              initialValue: alpn,
              maxLines: 1,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              onChanged: (v) {
                final parts = v.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
                notifier.setPath(['tls', 'alpn'], parts.isEmpty ? null : parts);
              },
            ),
          ),
          NodeFieldPadding(
            child: NodeDropdownField<String>(
              label: t.pages.nodeEditor.fields.fingerprint,
              value: nodeUtlsFingerprints.contains(fp) ? fp : '',
              items: [
                const DropdownMenuItem(value: '', child: Text('-')),
                for (final f in nodeUtlsFingerprints) DropdownMenuItem(value: f, child: Text(f)),
              ],
              onChanged: (v) {
                if (v == null || v.isEmpty) {
                  notifier.setPath(['tls', 'utls'], null);
                } else {
                  notifier.setPath(['tls', 'utls', 'enabled'], true);
                  notifier.setPath(['tls', 'utls', 'fingerprint'], v);
                }
              },
            ),
          ),
          NodeFieldPadding(
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(t.pages.nodeEditor.fields.skipCertificateVerification),
              subtitle: Text(t.pages.nodeEditor.help.skipCertificateVerification),
              value: NodeJson.getPath(draft, ['tls', 'insecure']) == true,
              onChanged: (v) => notifier.setPath(['tls', 'insecure'], v ? true : null),
            ),
          ),
        ],
        if (mode == 'reality') ...[
          NodeFieldPadding(
            child: NodePasswordField(
              label: t.pages.nodeEditor.fields.realityPublicKey,
              initialValue: NodeJson.asString(NodeJson.getPath(draft, ['tls', 'reality', 'public_key'])) ?? '',
              validator: (_) => errors['reality.public_key'],
              onChanged: (v) => notifier.setPath(['tls', 'reality', 'public_key'], v.trim()),
            ),
          ),
          NodeFieldPadding(
            child: CustomTextFormField(
              label: t.pages.nodeEditor.fields.realityShortId,
              initialValue: NodeJson.asString(NodeJson.getPath(draft, ['tls', 'reality', 'short_id'])) ?? '',
              maxLines: 1,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              validator: (_) => errors['reality.short_id'],
              onChanged: (v) => notifier.setPath(['tls', 'reality', 'short_id'], v.trim()),
            ),
          ),
        ],
      ],
    );
  }
}
