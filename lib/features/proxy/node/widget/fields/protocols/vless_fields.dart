import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:uuid/uuid.dart';

class VlessFields extends HookConsumerWidget {
  const VlessFields({super.key, required this.profileId, required this.rawTag, required this.data});

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final errors = data.fieldErrors;
    final flow = NodeJson.asString(draft['flow']) ?? '';
    final packetEncoding = NodeJson.asString(draft['packet_encoding']) ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodeSectionHeader(t.pages.nodeEditor.sections.credentials),
        NodeFieldPadding(
          child: NodePasswordField(
            label: t.pages.nodeEditor.fields.uuid,
            initialValue: NodeJson.asString(draft['uuid']) ?? '',
            validator: (_) => errors['uuid'],
            onChanged: (v) => notifier.setPath(['uuid'], v.trim()),
          ),
        ),
        NodeFieldRow(
          children: [
            NodeDropdownField<String>(
              label: t.pages.nodeEditor.fields.flow,
              value: nodeVlessFlows.contains(flow) ? flow : '',
              items: [
                for (final f in nodeVlessFlows) DropdownMenuItem(value: f, child: Text(f.isEmpty ? '-' : f)),
              ],
              onChanged: (v) => notifier.setPath(['flow'], (v == null || v.isEmpty) ? null : v),
            ),
            NodeDropdownField<String>(
              label: t.pages.nodeEditor.fields.packetEncoding,
              value: nodePacketEncodings.contains(packetEncoding) ? packetEncoding : '',
              items: [
                for (final p in nodePacketEncodings) DropdownMenuItem(value: p, child: Text(p.isEmpty ? '-' : p)),
              ],
              onChanged: (v) => notifier.setPath(['packet_encoding'], (v == null || v.isEmpty) ? null : v),
            ),
          ],
        ),
        if (errors['flow'] != null)
          NodeFieldPadding(
            child: Text(errors['flow']!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        NodeFieldPadding(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.pages.nodeEditor.actions.generateUuid),
            onPressed: () => notifier.setPath(['uuid'], const Uuid().v4()),
          ),
        ),
      ],
    );
  }
}
