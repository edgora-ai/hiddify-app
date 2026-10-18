import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Multiplex section for vmess/vless/trojan.
class NodeMultiplexFields extends HookConsumerWidget {
  const NodeMultiplexFields({super.key, required this.profileId, required this.rawTag, required this.data});

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final enabled = NodeJson.getPath(draft, ['multiplex', 'enabled']) == true;
    final protocol = NodeJson.asString(NodeJson.getPath(draft, ['multiplex', 'protocol'])) ?? 'smux';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodeSectionHeader(t.pages.nodeEditor.sections.multiplexing),
        NodeFieldPadding(
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(t.pages.nodeEditor.fields.multiplexEnabled),
            value: enabled,
            onChanged: (v) {
              if (v) {
                notifier.setPath(['multiplex', 'enabled'], true);
                notifier.setPath(['multiplex', 'protocol'], 'smux');
              } else {
                notifier.setPath(['multiplex'], null);
              }
            },
          ),
        ),
        if (enabled) ...[
          NodeFieldPadding(
            child: NodeDropdownField<String>(
              label: t.pages.nodeEditor.fields.multiplexProtocol,
              value: nodeMultiplexProtocols.contains(protocol) ? protocol : 'smux',
              items: [
                for (final p in nodeMultiplexProtocols) DropdownMenuItem(value: p, child: Text(p)),
              ],
              onChanged: (v) {
                if (v != null) notifier.setPath(['multiplex', 'protocol'], v);
              },
            ),
          ),
          NodeFieldRow(
            children: [
              CustomTextFormField(
                label: t.pages.nodeEditor.fields.maxConnections,
                initialValue: (NodeJson.asInt(NodeJson.getPath(draft, ['multiplex', 'max_connections'])) ?? 4)
                    .toString(),
                maxLines: 1,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (v) {
                  final n = int.tryParse(v.trim());
                  notifier.setPath(['multiplex', 'max_connections'], n);
                },
              ),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: NodeJson.getPath(draft, ['multiplex', 'padding']) == true,
                      onChanged: (v) => notifier.setPath(['multiplex', 'padding'], v == true ? true : null),
                    ),
                    Text(t.pages.nodeEditor.fields.padding),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
