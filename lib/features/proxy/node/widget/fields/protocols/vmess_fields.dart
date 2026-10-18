import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/singbox/model/singbox_outbound_schema_values.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:uuid/uuid.dart';

class VmessFields extends HookConsumerWidget {
  const VmessFields({super.key, required this.profileId, required this.rawTag, required this.data});

  final String profileId;
  final String? rawTag;
  final NodeEditorState data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final notifier = ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier);
    final draft = data.draft;
    final errors = data.fieldErrors;
    final security = NodeJson.asString(draft['security']) ?? 'auto';
    final uuidRevision = useState(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodeSectionHeader(t.pages.nodeEditor.sections.credentials),
        NodeFieldPadding(
          child: NodePasswordField(
            label: t.pages.nodeEditor.fields.uuid,
            initialValue: NodeJson.asString(draft['uuid']) ?? '',
            initialValueRevision: uuidRevision.value,
            validator: (_) => errors['uuid'],
            onChanged: (v) => notifier.setPath(['uuid'], v.trim()),
          ),
        ),
        NodeFieldPadding(
          child: Row(
            children: [
              Expanded(
                child: NodeDropdownField<String>(
                  label: t.pages.nodeEditor.fields.encryption,
                  value: security,
                  items: [for (final s in nodeVmessSecurities) DropdownMenuItem(value: s, child: Text(s))],
                  onChanged: (v) {
                    if (v != null) notifier.setPath(['security'], v);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CustomTextFormField(
                  label: t.pages.nodeEditor.fields.alterId,
                  initialValue: (NodeJson.asInt(draft['alter_id']) ?? 0).toString(),
                  maxLines: 1,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (v) {
                    final n = int.tryParse(v.trim());
                    notifier.setPath(['alter_id'], n ?? 0);
                  },
                ),
              ),
            ],
          ),
        ),
        NodeFieldPadding(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.pages.nodeEditor.actions.generateUuid),
            onPressed: () {
              notifier.setPath(['uuid'], const Uuid().v4());
              uuidRevision.value++;
            },
          ),
        ),
      ],
    );
  }
}
