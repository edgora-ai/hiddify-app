import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/proxy/node/data/node_config_service.dart';
import 'package:hiddify/features/proxy/node/model/node_failure.dart';
import 'package:hiddify/features/proxy/node/notifier/node_providers.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_nodes_notifier.g.dart';

/// Raw node directory of one profile. Independent of the connection state:
/// works offline and for non-active profiles.
class ProfileNodesData {
  const ProfileNodesData({
    required this.profile,
    required this.rawContent,
    required this.entries,
  });

  final ProfileEntity profile;
  final String rawContent;
  final List<NodeListEntry> entries;

  bool get isLocal => profile is LocalProfileEntity;
}

@riverpod
class ProfileNodesNotifier extends _$ProfileNodesNotifier with AppLogger {
  @override
  Future<ProfileNodesData> build(String profileId) async {
    final service = ref.watch(nodeConfigServiceProvider);
    final profile = (await service.loadProfile(profileId)).match((l) => throw l, (r) => r);
    final loaded = (await service.loadConfig(profileId)).match((l) => throw l, (r) => r);
    return ProfileNodesData(
      profile: profile,
      rawContent: loaded.rawContent,
      entries: service.listEntries(loaded.config),
    );
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {}
  }

  /// Deletes a node after the caller confirmed. Returns the failure or null.
  Future<NodeFailure?> deleteNode(String rawTag, String expectedRawContent) async {
    final service = ref.read(nodeConfigServiceProvider);
    final profileId = await future.then((d) => d.profile.id);
    final result = await service.deleteNode(
      profileId: profileId,
      expectedRawContent: expectedRawContent,
      rawTag: rawTag,
    );
    return result.match((l) => l, (_) {
      ref.invalidateSelf();
      return null;
    });
  }
}
