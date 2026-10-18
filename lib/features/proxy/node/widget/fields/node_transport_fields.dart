import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Transport section for vmess/vless/trojan only.
class NodeTransportFields extends HookConsumerWidget {
  const NodeTransportFields({super.key, required this.profileId, required this.rawTag, required this.data});

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final current = NodeJson.transportTypeOf(draft);

    Future<void> switchTransport(String next) async {
      if (next == current) return;
      // Switching transports drops the old transport's settings; confirm
      // first whenever a configured non-tcp transport exists.
      if (current != 'tcp' && draft['transport'] is Map) {
        final ok = await ref
            .read(dialogNotifierProvider.notifier)
            .showConfirmation(
              title: t.dialogs.node.changeTransportTitle,
              message: t.dialogs.node.changeTransportMessage,
            );
        if (!ok) return;
      }
      // Drop everything, then lay down the new skeleton (or nothing for tcp).
      notifier.setPath(['transport'], null);
      if (next != 'tcp') notifier.setPath(['transport', 'type'], next);
    }

    String headerHost() {
      final headers = NodeJson.getPath(draft, ['transport', 'headers']);
      if (headers is Map<String, dynamic>) {
        for (final e in headers.entries) {
          if (e.key.toLowerCase() == 'host') return NodeJson.asString(e.value) ?? '';
        }
      }
      return '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodeSectionHeader(t.pages.nodeEditor.sections.transport),
        NodeFieldPadding(
          child: NodeDropdownField<String>(
            label: t.pages.nodeEditor.fields.transport,
            value: current,
            items: [
              for (final tr in nodeTransportTypes) DropdownMenuItem(value: tr, child: Text(tr)),
            ],
            onChanged: (v) {
              if (v != null) switchTransport(v);
            },
          ),
        ),
        if (current == 'ws') ...[
          NodeFieldPadding(
            child: CustomTextFormField(
              label: t.pages.nodeEditor.fields.path,
              hint: '/ws',
              initialValue: NodeJson.asString(NodeJson.getPath(draft, ['transport', 'path'])) ?? '',
              maxLines: 1,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              onChanged: (v) => notifier.setPath(['transport', 'path'], v.isEmpty ? null : v),
            ),
          ),
          NodeFieldPadding(
            child: CustomTextFormField(
              label: t.pages.nodeEditor.fields.hostHeader,
              initialValue: headerHost(),
              maxLines: 1,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              onChanged: (v) {
                final headers = Map<String, dynamic>.of(
                  NodeJson.getPath(draft, ['transport', 'headers']) as Map<String, dynamic>? ?? {},
                );
                NodeJson.putHeader(headers, 'Host', v.trim().isEmpty ? null : v.trim());
                notifier.setPath(['transport', 'headers'], headers.isEmpty ? null : headers);
              },
            ),
          ),
        ],
        if (current == 'grpc')
          NodeFieldPadding(
            child: CustomTextFormField(
              label: t.pages.nodeEditor.fields.serviceName,
              initialValue: NodeJson.asString(NodeJson.getPath(draft, ['transport', 'service_name'])) ?? '',
              maxLines: 1,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              onChanged: (v) => notifier.setPath(['transport', 'service_name'], v.isEmpty ? null : v),
            ),
          ),
        if (current == 'httpupgrade') ...[
          NodeFieldPadding(
            child: CustomTextFormField(
              label: t.pages.nodeEditor.fields.hostHeader,
              initialValue: NodeJson.asString(NodeJson.getPath(draft, ['transport', 'host'])) ?? '',
              maxLines: 1,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              onChanged: (v) => notifier.setPath(['transport', 'host'], v.isEmpty ? null : v),
            ),
          ),
          NodeFieldPadding(
            child: CustomTextFormField(
              label: t.pages.nodeEditor.fields.path,
              initialValue: NodeJson.asString(NodeJson.getPath(draft, ['transport', 'path'])) ?? '',
              maxLines: 1,
              textCapitalization: TextCapitalization.none,
              enableSuggestions: false,
              onChanged: (v) => notifier.setPath(['transport', 'path'], v.isEmpty ? null : v),
            ),
          ),
        ],
      ],
    );
  }
}
