import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/widget/adaptive_menu.dart';
import 'package:hiddify/features/proxy/node/data/node_config_service.dart';
import 'package:hiddify/features/proxy/node/widget/profile_nodes_page.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Node actions menu built on [AdaptiveMenu].
///
/// [isLocal] gates write actions; copy-link stays available for remote
/// profiles because it is a pure read. [expectedRawContentOf] supplies the
/// conflict-detection snapshot for delete.
class NodeActionsMenu extends HookConsumerWidget {
  const NodeActionsMenu({
    super.key,
    required this.profileId,
    required this.entry,
    required this.isLocal,
    required this.expectedRawContentOf,
    required this.builder,
    this.child,
  });

  final String profileId;
  final NodeListEntry entry;
  final bool isLocal;
  final Future<String> Function() expectedRawContentOf;
  final AdaptiveMenuBuilder builder;
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final canEdit = isLocal && entry.editable;

    Future<String> snapshot() => expectedRawContentOf();

    final items = [
      if (canEdit)
        AdaptiveMenuItem(
          leadingIcon: const Icon(Icons.edit_rounded),
          title: t.common.edit,
          onTap: () => context.goNamed(
            'nodeEdit',
            pathParameters: {'id': profileId},
            queryParameters: {'tag': entry.rawTag},
          ),
        ),
      AdaptiveMenuItem(
        leadingIcon: const Icon(Icons.link_rounded),
        title: t.pages.nodeEditor.actions.copyLink,
        onTap: () => copyNodeShareLink(ref, profileId: profileId, rawTag: entry.rawTag),
      ),
      if (canEdit)
        AdaptiveMenuItem(
          leadingIcon: const Icon(Icons.delete_outline_rounded),
          title: t.common.delete,
          onTap: () async {
            final content = await snapshot();
            if (!context.mounted) return;
            await confirmAndDeleteNode(
              ref,
              profileId: profileId,
              entry: entry,
              expectedRawContent: content,
            );
          },
        ),
    ];

    return AdaptiveMenu(builder: builder, items: items, child: child);
  }
}
