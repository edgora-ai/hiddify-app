import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hiddify/singbox/model/singbox_proxy_type.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Name, protocol, server, port and (for new nodes) target groups.
class NodeCommonFields extends HookConsumerWidget {
  const NodeCommonFields({
    super.key,
    required this.profileId,
    required this.rawTag,
    required this.data,
    required this.onProtocolSwitch,
  });

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;
  final void Function(String protocol) onProtocolSwitch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final errors = data.fieldErrors;
    final protocol = draft['type'] as String? ?? '';

    String? errorFor(String key) => errors[key];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodeSectionHeader(t.pages.nodeEditor.sections.basics),
        NodeFieldPadding(
          child: Builder(
            builder: (context) {
              final (displayName, _) = NodeJson.splitTagSuffix(NodeJson.asString(draft['tag']) ?? '');
              return CustomTextFormField(
                key: ValueKey('tag-$rawTag'),
                label: t.common.name,
                initialValue: displayName,
                initialValueRevision: protocol,
                maxLines: 1,
                textCapitalization: TextCapitalization.none,
                validator: (_) => errorFor('tag'),
                onChanged: (v) => notifier.setPath(['tag'], v.trim()),
              );
            },
          ),
        ),
        NodeFieldPadding(
          child: NodeDropdownField<String>(
            label: t.pages.nodeEditor.fields.protocol,
            value: protocol,
            enabled: data.isNew,
            items: [
              for (final p in nodeFormProtocols) DropdownMenuItem(value: p, child: Text(ProxyType.fromJson(p).label)),
            ],
            onChanged: (v) {
              if (v == null || v == protocol) return;
              onProtocolSwitch(v);
            },
          ),
        ),
        NodeFieldRow(
          children: [
            CustomTextFormField(
              key: ValueKey('server-$rawTag'),
              label: t.pages.nodeEditor.fields.server,
              initialValue: NodeJson.asString(draft['server']) ?? '',
              initialValueRevision: protocol,
              maxLines: 1,
              keyboardType: TextInputType.url,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              validator: (_) => errorFor('server'),
              onChanged: (v) => notifier.setPath(['server'], v.trim()),
            ),
            CustomTextFormField(
              key: ValueKey('port-$rawTag'),
              label: t.pages.nodeEditor.fields.port,
              initialValue: (NodeJson.asInt(draft['server_port']) ?? 443).toString(),
              initialValueRevision: protocol,
              maxLines: 1,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (_) => errorFor('server_port'),
              onChanged: (v) {
                final port = int.tryParse(v.trim());
                notifier.setPath(['server_port'], port ?? v.trim());
              },
            ),
          ],
        ),
        if (data.isNew && data.groupTags.isNotEmpty) ...[
          NodeFieldPadding(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.pages.nodeEditor.fields.groups, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final g in data.groupTags)
                      FilterChip(
                        label: Text(g),
                        selected: data.selectedGroups.contains(g),
                        onSelected: (v) => notifier.toggleGroup(g, v),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
