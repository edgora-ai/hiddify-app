import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class TuicFields extends HookConsumerWidget {
  const TuicFields({super.key, required this.profileId, required this.rawTag, required this.data});

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final errors = data.fieldErrors;
    final cc = NodeJson.asString(draft['congestion_control']) ?? 'cubic';
    final relay = NodeJson.asString(draft['udp_relay_mode']) ?? 'native';

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
        NodeFieldPadding(
          child: NodePasswordField(
            label: t.pages.nodeEditor.fields.password,
            initialValue: NodeJson.asString(draft['password']) ?? '',
            validator: (_) => errors['password'],
            onChanged: (v) => notifier.setPath(['password'], v),
          ),
        ),
        NodeFieldRow(
          children: [
            NodeDropdownField<String>(
              label: t.pages.nodeEditor.fields.congestionControl,
              value: cc,
              items: [for (final c in nodeTuicCongestionControls) DropdownMenuItem(value: c, child: Text(c))],
              onChanged: (v) {
                if (v != null) notifier.setPath(['congestion_control'], v);
              },
            ),
            NodeDropdownField<String>(
              label: t.pages.nodeEditor.fields.udpRelayMode,
              value: relay,
              items: [for (final r in nodeTuicUdpRelayModes) DropdownMenuItem(value: r, child: Text(r))],
              onChanged: (v) {
                if (v != null) notifier.setPath(['udp_relay_mode'], v);
              },
            ),
          ],
        ),
        NodeSectionHeader(t.pages.nodeEditor.sections.advanced),
        NodeFieldPadding(
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(t.pages.nodeEditor.fields.zeroRttHandshake),
            subtitle: Text(t.pages.nodeEditor.help.zeroRttHandshake),
            value: draft['zero_rtt_handshake'] == true,
            onChanged: (v) => notifier.setPath(['zero_rtt_handshake'], v ? true : null),
          ),
        ),
        NodeFieldPadding(
          child: CustomTextFormField(
            label: t.pages.nodeEditor.fields.heartbeat,
            hint: '10s',
            initialValue: NodeJson.asString(draft['heartbeat']) ?? '',
            maxLines: 1,
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.none,
            validator: (_) => errors['heartbeat'],
            onChanged: (v) => notifier.setPath(['heartbeat'], v.trim().isEmpty ? null : v.trim()),
          ),
        ),
      ],
    );
  }
}
