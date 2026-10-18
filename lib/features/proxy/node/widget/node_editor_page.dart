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
    final formRevision = useState(0);
    final formKey = useMemoized(() => GlobalKey<FormState>(), [formRevision.value]);
    final provider = nodeEditorNotifierProvider(profileId, rawTag);
    ref.listen(provider, (previous, next) {
      if (next.asData?.value.isSaving ?? false) {
        // Close the existing text-input connection as well as blocking new taps.
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });

    return ref
        .watch(provider)
        .when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (data) {
            final protocol = data.draft['type'] as String? ?? '';
            return PopScope(
              canPop: !data.isSaving && !data.isDirty,
              onPopInvokedWithResult: (didPop, _) async {
                if (didPop || ref.read(provider).asData?.value.isSaving == true) return;
                final discard = await ref
                    .read(dialogNotifierProvider.notifier)
                    .showConfirmation(title: t.dialogs.node.discardTitle, message: t.dialogs.node.discardMessage);
                if (discard && context.mounted && ref.read(provider).asData?.value.isSaving == false) {
                  context.pop();
                }
              },
              child: Scaffold(
                appBar: AppBar(
                  title: Text(data.isNew ? t.pages.nodeEditor.addTitle : t.pages.nodeEditor.editTitle),
                  actions: [
                    if (data.needsReload)
                      TextButton(
                        onPressed: () => _reload(context, ref, t, () => formRevision.value++),
                        child: Text(t.pages.nodeEditor.actions.reload),
                      ),
                    TextButton.icon(
                      onPressed: !data.canEdit || data.needsReload || !data.isDirty
                          ? null
                          : () => _save(context, ref, formKey, t),
                      icon: data.isSaving
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.check),
                      label: Text(t.common.save),
                    ),
                    const Gap(8),
                  ],
                ),
                bottomNavigationBar: data.savePhase == NodeSavePhase.applyFailed
                    ? SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: FilledButton.tonal(
                            onPressed: () => _retryApply(context, ref, t),
                            child: Text(t.pages.nodeEditor.actions.tryAgain),
                          ),
                        ),
                      )
                    : null,
                body: ExcludeFocus(
                  excluding: !data.canEdit,
                  child: AbsorbPointer(
                    absorbing: !data.canEdit,
                    child: Form(
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
                            'shadowsocks' => ShadowsocksFields(profileId: profileId, rawTag: rawTag, data: data),
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
                            NodeTlsFields(profileId: profileId, rawTag: rawTag, data: data, tlsRequired: true),
                          if (protocol == 'vmess' || protocol == 'vless' || protocol == 'trojan')
                            NodeMultiplexFields(profileId: profileId, rawTag: rawTag, data: data),
                          const Gap(32),
                        ],
                      ),
                    ),
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

  Future<void> _reload(BuildContext context, WidgetRef ref, TranslationsEn t, VoidCallback resetForm) async {
    final provider = nodeEditorNotifierProvider(profileId, rawTag);
    final data = ref.read(provider).asData?.value;
    if (data == null || data.isSaving) return;
    if (data.isDirty) {
      final discard = await ref
          .read(dialogNotifierProvider.notifier)
          .showConfirmation(title: t.dialogs.node.discardTitle, message: t.dialogs.node.discardMessage);
      if (!discard || !context.mounted) return;
    }
    if (ref.read(provider).asData?.value.isSaving != false) return;
    resetForm();
    ref.read(provider.notifier).reload();
  }

  Future<void> _confirmProtocolSwitch(BuildContext context, WidgetRef ref, TranslationsEn t, String next) async {
    final ok = await ref
        .read(dialogNotifierProvider.notifier)
        .showConfirmation(title: t.dialogs.node.changeProtocolTitle, message: t.dialogs.node.changeProtocolMessage);
    if (!ok) return;
    final data = ref.read(nodeEditorNotifierProvider(profileId, rawTag)).asData?.value;
    final name = data?.draft['tag'] as String? ?? '';
    ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier).switchProtocol(next, keepName: name);
  }

  Future<void> _save(BuildContext context, WidgetRef ref, GlobalKey<FormState> formKey, TranslationsEn t) async {
    FocusManager.instance.primaryFocus?.unfocus();
    formKey.currentState?.validate();
    final result = await ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier).save(t);
    if (!context.mounted) return;
    switch (result.kind) {
      case NodeSaveKind.invalid:
        // Inline errors are already shown; keep the form open.
        break;
      case NodeSaveKind.saved:
        ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.saved);
        if (_canClose(ref)) context.pop();
      case NodeSaveKind.applied:
        ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.applied);
        if (_canClose(ref)) context.pop();
      case NodeSaveKind.applyFailed:
        // Stay on the page: the Try again button is visible.
        ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.saved);
      case NodeSaveKind.failed:
        if (result.failure != null) {
          await ref.read(dialogNotifierProvider.notifier).showCustomAlertFromErr(t.presentError(result.failure!));
        }
      case NodeSaveKind.aborted:
        break;
    }
  }

  bool _canClose(WidgetRef ref) {
    final data = ref.read(nodeEditorNotifierProvider(profileId, rawTag)).asData?.value;
    return data != null && !data.isSaving && !data.isDirty;
  }

  Future<void> _retryApply(BuildContext context, WidgetRef ref, TranslationsEn t) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await ref.read(nodeEditorNotifierProvider(profileId, rawTag).notifier).retryApply(t);
    if (!context.mounted) return;
    if (result.kind == NodeSaveKind.applied) {
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.applied);
      if (_canClose(ref)) context.pop();
    }
  }
}
