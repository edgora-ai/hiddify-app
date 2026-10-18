import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/validation/node_validators.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class Hysteria2Fields extends HookConsumerWidget {
  const Hysteria2Fields({super.key, required this.profileId, required this.rawTag, required this.data});

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final errors = data.fieldErrors;
    final obfsType = NodeJson.asString(NodeJson.getPath(draft, ['obfs', 'type'])) ?? '';

    String? bandwidthError(String? input, String key) {
      if (input != null && input.trim().isNotEmpty && !NodeValidators.isPositiveNumber(input)) {
        return t.errors.nodes.invalidNumber;
      }
      return errors[key];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodeSectionHeader(t.pages.nodeEditor.sections.credentials),
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
              label: t.pages.nodeEditor.fields.obfs,
              value: obfsType,
              items: [
                for (final o in nodeHysteria2ObfsTypes) DropdownMenuItem(value: o, child: Text(o.isEmpty ? '-' : o)),
              ],
              onChanged: (v) {
                if (v == null || v.isEmpty) {
                  notifier.setPath(['obfs'], null);
                } else {
                  notifier.setPath(['obfs', 'type'], v);
                }
              },
            ),
            NodePasswordField(
              label: t.pages.nodeEditor.fields.obfsPassword,
              initialValue: NodeJson.asString(NodeJson.getPath(draft, ['obfs', 'password'])) ?? '',
              initialValueRevision: obfsType,
              enabled: nodeHysteria2ObfsTypes.contains(obfsType),
              onChanged: (v) => notifier.setPath(['obfs', 'password'], v.isEmpty ? null : v),
            ),
          ],
        ),
        NodeFieldRow(
          children: [
            CustomTextFormField(
              label: t.pages.nodeEditor.fields.uploadMbps,
              initialValue: NodeJson.asString(draft['up_mbps']) ?? '',
              maxLines: 1,
              keyboardType: TextInputType.number,
              validator: (v) => bandwidthError(v, 'up_mbps'),
              onChanged: (v) => notifier.setPath(['up_mbps'], NodeJson.optionalIntInput(v)),
            ),
            CustomTextFormField(
              label: t.pages.nodeEditor.fields.downloadMbps,
              initialValue: NodeJson.asString(draft['down_mbps']) ?? '',
              maxLines: 1,
              keyboardType: TextInputType.number,
              validator: (v) => bandwidthError(v, 'down_mbps'),
              onChanged: (v) => notifier.setPath(['down_mbps'], NodeJson.optionalIntInput(v)),
            ),
          ],
        ),
      ],
    );
  }
}
