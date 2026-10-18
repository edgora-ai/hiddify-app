import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/proxy/node/data/node_config_service.dart';
import 'package:hiddify/features/proxy/node/notifier/node_providers.dart';
import 'package:hiddify/features/proxy/node/notifier/profile_nodes_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/node_actions_menu.dart';
import 'package:hiddify/singbox/model/singbox_proxy_type.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Node management page for one profile. Reads raw config nodes; works
/// offline and for non-active profiles. Remote profiles are read-only.
class ProfileNodesPage extends HookConsumerWidget {
  const ProfileNodesPage({super.key, required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return ref
        .watch(profileNodesNotifierProvider(profileId))
        .when(
          data: (data) {
            final editable = data.entries.where((e) => e.editable).toList();
            return Scaffold(
              appBar: AppBar(
                title: Text(t.pages.profileNodes.title),
                actions: [
                  if (data.isLocal)
                    IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: t.pages.nodeEditor.addTitle,
                      onPressed: () => context.goNamed(
                        'nodeEdit',
                        pathParameters: {'id': profileId},
                      ),
                    ),
                ],
              ),
              body: data.entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(t.pages.profileNodes.empty),
                          if (data.isLocal)
                            TextButton(
                              onPressed: () => context.goNamed(
                                'nodeEdit',
                                pathParameters: {'id': profileId},
                              ),
                              child: Text(t.pages.profileNodes.emptyAction),
                            ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () =>
                          ref.read(profileNodesNotifierProvider(profileId).notifier).refresh(),
                      child: ListView.builder(
                        itemCount: data.entries.length,
                        itemBuilder: (context, index) {
                          final entry = data.entries[index];
                          return NodeActionsMenu(
                            profileId: profileId,
                            entry: entry,
                            isLocal: data.isLocal,
                            expectedRawContentOf: () async {
                              final d = await ref.read(
                                profileNodesNotifierProvider(profileId).future,
                              );
                              return d.rawContent;
                            },
                            builder: (context, toggle, _) => ListTile(
                              leading: _protocolIcon(entry.type),
                              title: Text(
                                entry.displayName.isEmpty ? entry.rawTag : entry.displayName,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  ProxyType.fromJson(entry.type).label,
                                  if (entry.server != null && entry.server!.isNotEmpty)
                                    '${entry.server}:${entry.port ?? ''}',
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: entry.editable
                                  ? null
                                  : const Icon(Icons.lock_outline, size: 18),
                              onTap: data.isLocal && entry.editable
                                  ? () => context.goNamed(
                                      'nodeEdit',
                                      pathParameters: {'id': profileId},
                                      queryParameters: {'tag': entry.rawTag},
                                    )
                                  : null,
                              onLongPress: toggle,
                            ),
                          );
                        },
                      ),
                    ),
              floatingActionButton: data.isLocal && editable.isNotEmpty
                  ? null
                  : null,
            );
          },
          error: (error, _) => Scaffold(
            appBar: AppBar(title: Text(t.pages.profileNodes.title)),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t.presentShortError(error), textAlign: TextAlign.center),
              ),
            ),
          ),
          loading: () => Scaffold(
            appBar: AppBar(title: Text(t.pages.profileNodes.title)),
            body: const Center(child: CircularProgressIndicator()),
          ),
        );
  }

  Widget _protocolIcon(String type) {
    final label = ProxyType.fromJson(type).label;
    return CircleAvatar(
      radius: 18,
      child: Text(
        label.isEmpty ? '?' : label.characters.first,
        style: const TextStyle(fontSize: 16),
      ),
    );
  }
}

/// Deletes a node with confirmation; shared by menus.
Future<void> confirmAndDeleteNode(
  WidgetRef ref, {
  required String profileId,
  required NodeListEntry entry,
  required String expectedRawContent,
}) async {
  final t = ref.read(translationsProvider).requireValue;
  final confirmed = await ref
      .read(dialogNotifierProvider.notifier)
      .showConfirmation(
        title: t.dialogs.node.deleteTitle,
        message: t.dialogs.node.deleteMessage(name: entry.displayName),
      );
  if (!confirmed) return;
  final failure = await ref
      .read(profileNodesNotifierProvider(profileId).notifier)
      .deleteNode(entry.rawTag, expectedRawContent);
  if (failure == null) {
    ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.nodeEditor.messages.deleted);
  } else {
    await ref.read(dialogNotifierProvider.notifier).showCustomAlertFromErr(t.presentError(failure));
  }
}

/// Copies a share link for one node; shared by menus.
Future<void> copyNodeShareLink(
  WidgetRef ref, {
  required String profileId,
  required String rawTag,
}) async {
  final t = ref.read(translationsProvider).requireValue;
  final result = await ref.read(nodeConfigServiceProvider).shareLink(profileId, rawTag);
  await result.match(
    (failure) async {
      await ref.read(dialogNotifierProvider.notifier).showCustomAlertFromErr(t.presentError(failure));
    },
    (outcome) async {
      if (outcome.warnings.isNotEmpty) {
        final copy = await ref
            .read(dialogNotifierProvider.notifier)
            .showConfirmation(
              title: t.dialogs.node.shareWarningTitle,
              message: t.dialogs.node.shareWarningMessage(fields: outcome.droppedFields.join(', ')),
              positiveBtnTxt: t.pages.nodeEditor.actions.copyAnyway,
            );
        if (!copy) return;
      }
      await Clipboard.setData(ClipboardData(text: outcome.link!));
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.export.clipboard.success);
    },
  );
}
