import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_common_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_multiplex_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_tls_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_transport_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/hysteria2_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/shadowsocks_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/trojan_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/tuic_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/vless_fields.dart';
import 'package:hiddify/features/proxy/node/widget/fields/protocols/vmess_fields.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Add/edit form for a single node. [rawTag] null means add-mode.
class NodeEditorPage extends HookConsumerWidget with PresLogger {
  const NodeEditorPage({super.key, required this.profileId, this.rawTag});

  final String profileId;
  final String? rawTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final formKey = useMemoized(() => GlobalKey<FormState>());
    final provider = nodeEditorNotifierProvider(profileId, rawTag);

    return ref
        .watch(provider)
        .when(
          data: (data) {
            final protocol = data.draft['type'] as String? ?? '';
            return PopScope(
              canPop: !data.isDirty,
              onPopInvokedWithResult: (didPop, _) async {
                if (didPop) return;
                final discard = await ref
                    .read(dialogNotifierProvider.notifier)
                    .showConfirmation(
                      title: t.dialogs.node.discardTitle,
                      message: t.dialogs.node.discardMessage,
                    );
                if (discard && context.mounted) context.pop();
              },
              child: Scaffold(
                appBar: AppBar(
                  title: Text(data.isNew ? t.pages.nodeEditor.addTitle : t.pages.nodeEditor.editTitle),
                  actions: [
                    TextButton.icon(
                      onPressed: data.isSaving || !data.isDirty
                          ? null
                          : () => _save(context, ref, formKey, t),
                      icon: data.isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: Text(t.common.save),
                    ),
                    const Gap(8),
                  ],
                ),
                body: Form(
                  key: formKey,
                  child: ListView(
                    children: [
                      NodeCommonFields(
                        profileId: profileId,
                        rawTag: rawTag,
                        data: data,
                        onProtocolSwitch: (next) => _confirmProtocolSwitch(context, ref, t, next),
                      ),
                      switch (protocol) {
                        'vmess' => VmessFields(profileId: profileId, rawTag: rawTag, data: data),
                        'vless' => VlessFields(profileId: profileId, rawTag: rawTag, data: data),
                        'trojan' => TrojanFields(profileId: profileId, rawTag: rawTag, data: data),
                        'shadowsocks' => ShadowsocksFields(
                          profileId: profileId,
                          rawTag: rawTag,
                          data: data,
                        ),
                        'tuic' => TuicFields(profileId: profileId, rawTag: rawTag, data: data),
                        'hysteria2' => Hysteria2Fields(profileId: profileId, rawTag: rawTag, data: data),
                        _ => const SizedBox.shrink(),
                      },
                      if (protocol == 'vmess' || protocol == 'vless' || protocol == 'trojan')
                        NodeTransportFields(profileId: profileId, rawTag: rawTag, data: data),
                      if (protocol == 'vmess' || protocol == 'vless' || protocol == 'trojan')
                        NodeTlsFields(
                          profileId: profileId,
                          rawTag: rawTag,
                          data: data,
                          allowReality: protocol == 'vless',
                        ),
                      if (protocol == 'tuic' || protocol == 'hysteria2')
                        NodeTlsFields(
                          profileId: profileId,
                          rawTag: rawTag,
                          data: data,
                          tlsRequired: true,
                        ),
                      if (protocol == 'vmess' || protocol == 'vless' || protocol == 'trojan')
                        NodeMultiplexFields(profileId: profileId, rawTag: rawTag, data: data),
                      if (data.savePhase == NodeSavePhase.applyFailed)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: FilledButton.tonal(
                            onPressed: () => _retryApply(context, ref, t),
                            child: Text(t.pages.nodeEditor.actions.tryAgain),
                          ),
                        ),
                      const Gap(32),
                    ],
                  ),
                ),
              ),
            );
          },
          error: (error, _) => Scaffold(
            appBar: AppBar(title: Text(t.pages.nodeEditor.editTitle)),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t.presentShortError(error), textAlign: TextAlign.center),
              ),
            ),
          ),
          loading: () => Scaffold(
            appBar: AppBar(title: Text(t.pages.nodeEditor.editTitle)),
            body: const Center(child: CircularProgressIndicator()),
          ),
        );
  }

  Future<void> _confirmProtocolSwitch(
    BuildContext context,
    WidgetRef ref,
    TranslationsEn t,
    String next,
  ) async {
    final ok = await ref
        .read(dialogNotifierProvider.notifier)
        .showConfirmation(
          title: t.dialogs.node.changeProtocolTitle,
          message: t.dialogs.node.changeProtocolMessage,
        );
    if (!ok) return;
    final data = ref.read(nodeEditorNotifierProvider(profileId, rawTag)).asData?.value;
    final name = data?.draft['tag'] as String? ?? '';
    ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier).switchProtocol(next, keepName: name);
  }

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    GlobalKey<FormState> formKey,
    TranslationsEn t,
  ) async {
    formKey.currentState?.validate();
    final result = await ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier).save(t);
    if (!context.mounted) return;
    switch (result.kind) {
      case NodeSaveKind.invalid:
        // Inline errors are already shown; keep the form open.
        break;
      case NodeSaveKind.saved:
        ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.saved);
        context.pop();
      case NodeSaveKind.applied:
        ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.applied);
        context.pop();
      case NodeSaveKind.applyFailed:
        // Stay on the page: the Try again button is visible.
        ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.saved);
      case NodeSaveKind.failed:
        if (result.failure != null) {
          await ref
              .read(dialogNotifierProvider.notifier)
              .showCustomAlertFromErr(t.presentError(result.failure!));
        }
      case NodeSaveKind.aborted:
        break;
    }
  }

  Future<void> _retryApply(BuildContext context, WidgetRef ref, TranslationsEn t) async {
    final result = await ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier).retryApply(t);
    if (!context.mounted) return;
    if (result.kind == NodeSaveKind.applied) {
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.applied);
      context.pop();
    }
  }
}
