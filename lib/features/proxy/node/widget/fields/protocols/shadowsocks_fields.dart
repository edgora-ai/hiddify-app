import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ShadowsocksFields extends HookConsumerWidget {
  const ShadowsocksFields({super.key, required this.profileId, required this.rawTag, required this.data});

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final errors = data.fieldErrors;
    final method = NodeJson.asString(draft['method']) ?? '';
    final plugin = NodeJson.asString(draft['plugin']) ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodeSectionHeader(t.pages.nodeEditor.sections.credentials),
        NodeFieldPadding(
          child: NodeDropdownField<String>(
            label: t.pages.nodeEditor.fields.method,
            value: method,
            items: [for (final m in nodeShadowsocksMethods) DropdownMenuItem(value: m, child: Text(m))],
            onChanged: (v) {
              if (v != null) notifier.setPath(['method'], v);
            },
          ),
        ),
        NodeFieldPadding(
          child: NodePasswordField(
            label: t.pages.nodeEditor.fields.password,
            initialValue: NodeJson.asString(draft['password']) ?? '',
            validator: (_) => errors['password'],
            onChanged: (v) => notifier.setPath(['password'], v),
          ),
        ),
        NodeSectionHeader(t.pages.nodeEditor.sections.advanced),
        NodeFieldPadding(
          child: NodeDropdownField<String>(
            label: t.pages.nodeEditor.fields.plugin,
            value: plugin,
            items: [
              for (final p in nodeShadowsocksPlugins) DropdownMenuItem(value: p, child: Text(p.isEmpty ? '-' : p)),
            ],
            onChanged: (v) => notifier.setPath(['plugin'], (v == null || v.isEmpty) ? null : v),
          ),
        ),
        NodeFieldPadding(
          child: CustomTextFormField(
            label: t.pages.nodeEditor.fields.pluginOptions,
            initialValue: NodeJson.asString(draft['plugin_opts']) ?? '',
            initialValueRevision: plugin,
            enabled: nodeShadowsocksPlugins.contains(plugin),
            maxLines: 1,
            textCapitalization: TextCapitalization.none,
            enableSuggestions: false,
            onChanged: (v) => notifier.setPath(['plugin_opts'], v.isEmpty ? null : v),
          ),
        ),
        NodeFieldPadding(
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(t.pages.nodeEditor.fields.udpOverTcp),
            value: draft['udp_over_tcp'] == true,
            onChanged: (v) => notifier.setPath(['udp_over_tcp'], v ? true : null),
          ),
        ),
      ],
    );
  }
}
