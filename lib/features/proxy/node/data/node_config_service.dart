import 'dart:convert';

import 'package:dartx/dartx.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/data/node_protocol_templates.dart';
import 'package:hiddify/features/proxy/node/data/node_reference_sync.dart';
import 'package:hiddify/features/proxy/node/data/node_share_link_encoder.dart';
import 'package:hiddify/features/proxy/node/model/node_failure.dart';

/// One row of the profile-nodes list: raw identity plus display info.
class NodeListEntry {
  const NodeListEntry({
    required this.rawTag,
    required this.displayName,
    required this.type,
    required this.editable,
    this.server,
    this.port,
  });

  final String rawTag;
  final String displayName;
  final String type;
  final bool editable;
  final String? server;
  final int? port;
}

/// Single orchestration point for node persistence (add/edit/delete).
///
/// All writes go through [ProfileRepository.offlineUpdate]; this service adds
/// node-level locating, local-only gating, snapshot conflict detection and
/// reference syncing. It never touches files directly and never calls core.
///
/// Applying the saved config to the running core (reconnect) is the
/// notifier's job: it owns the connection state needed for that decision.
class NodeConfigService {
  NodeConfigService(this._profilesRepo);

  final ProfileRepository _profilesRepo;

  // Per-profile in-memory write locks to serialize concurrent saves.
  final _locks = <String, Future<void>>{};

  Future<T> _locked<T>(String profileId, Future<T> Function() fn) {
    final prev = _locks[profileId] ?? Future.value();
    final current = prev.then((_) => fn());
    final gate = current.then((_) {}, onError: (_) {});
    _locks[profileId] = gate;
    gate.whenComplete(() {
      // Only remove if no newer save chained behind us.
      if (identical(_locks[profileId], gate)) _locks.remove(profileId);
    });
    return current;
  }

  // ------------------------------------------------------------ read helpers

  /// Loads the profile entity; fails when missing.
  Future<Either<NodeFailure, ProfileEntity>> loadProfile(String profileId) async {
    final result = await _profilesRepo.getById(profileId).run();
    return result.match(
      (l) => Left(NodeFailure.unexpected(l)),
      (profile) => profile == null ? const Left(NodeFailure.notFound()) : Right(profile),
    );
  }

  /// Loads the raw config: the untouched file string plus the parsed JSON.
  /// The raw string is the conflict-detection snapshot; never re-encode it.
  Future<Either<NodeFailure, ({String rawContent, Map<String, dynamic> config})>> loadConfig(
    String profileId,
  ) async {
    final result = await _profilesRepo.getRawConfig(profileId).run();
    return result.match(
      (l) => Left(NodeFailure.unexpected(l)),
      (content) {
        try {
          final decoded = jsonDecode(content);
          if (decoded is! Map<String, dynamic>) {
            return const Left(NodeFailure.invalidStructure('root is not an object'));
          }
          if (decoded['outbounds'] != null && decoded['outbounds'] is! List) {
            return const Left(NodeFailure.invalidStructure('outbounds is not an array'));
          }
          return Right((rawContent: content, config: decoded));
        } catch (e) {
          return Left(NodeFailure.unexpected(e));
        }
      },
    );
  }

  /// Lists entries from a parsed config. Rows with malformed shapes or
  /// unsupported protocols are marked non-editable, never dropped.
  List<NodeListEntry> listEntries(Map<String, dynamic> config) {
    final outbounds = config['outbounds'];
    if (outbounds is! List) return [];
    final entries = <NodeListEntry>[];
    for (final o in outbounds) {
      if (o is! Map<String, dynamic>) {
        entries.add(const NodeListEntry(rawTag: '', displayName: '', type: '', editable: false));
        continue;
      }
      final type = o['type'];
      final tag = o['tag'];
      if (type is! String || tag is! String) {
        entries.add(const NodeListEntry(rawTag: '', displayName: '', type: '', editable: false));
        continue;
      }
      final (displayName, _) = NodeJson.splitTagSuffix(tag);
      entries.add(
        NodeListEntry(
          rawTag: tag,
          displayName: displayName,
          type: type,
          editable: NodeProtocolTemplates.isSupported(type),
          server: NodeJson.asString(o['server']),
          port: NodeJson.asInt(o['server_port']),
        ),
      );
    }
    return entries;
  }

  /// Locates exactly one outbound by raw tag; fails on zero/multiple matches.
  Either<NodeFailure, Map<String, dynamic>> findOutbound(Map<String, dynamic> config, String rawTag) {
    final outbounds = config['outbounds'];
    if (outbounds is! List) return const Left(NodeFailure.notFound());
    final matches = <Map<String, dynamic>>[];
    for (final o in outbounds) {
      if (o is Map<String, dynamic> && o['tag'] == rawTag) matches.add(o);
    }
    if (matches.isEmpty) return const Left(NodeFailure.notFound());
    if (matches.length > 1) return const Left(NodeFailure.ambiguousTag());
    return Right(matches.single);
  }

  /// All selector/urltest group tags (for the add-node group picker).
  List<String> groupTags(Map<String, dynamic> config) {
    final outbounds = config['outbounds'];
    if (outbounds is! List) return [];
    return outbounds
        .whereType<Map<String, dynamic>>()
        .where(
          (o) =>
              (o['type'] == 'selector' || o['type'] == 'urltest') &&
              o['tag'] is String &&
              (o['tag'] as String).isNotEmpty,
        )
        .map((o) => o['tag'] as String)
        .toList();
  }

  // ------------------------------------------------------------------- write

  /// Core save pipeline shared by add/update/delete.
  ///
  /// [mutate] receives a deep copy of the freshly loaded config and applies
  /// the change. Returns the re-read saved profile on success.
  Future<Either<NodeFailure, ProfileEntity>> _commit({
    required String profileId,
    required String expectedRawContent,
    required Either<NodeFailure, void> Function(Map<String, dynamic> config) mutate,
  }) {
    return _locked(profileId, () async {
      // 1. Re-read profile: must exist and still be local.
      final profileEither = await loadProfile(profileId);
      if (profileEither.isLeft()) {
        return Left<NodeFailure, ProfileEntity>(profileEither.getLeft().toNullable()!);
      }
      final profile = profileEither.getRight().toNullable()!;
      if (profile is! LocalProfileEntity) return const Left(NodeFailure.readOnly());

      // 2. Re-read raw content and compare with the editor snapshot.
      final rawEither = await _profilesRepo.getRawConfig(profileId).run();
      if (rawEither.isLeft()) {
        return Left<NodeFailure, ProfileEntity>(NodeFailure.unexpected(rawEither.getLeft().toNullable()));
      }
      final freshContent = rawEither.getRight().toNullable()!;
      if (freshContent != expectedRawContent) {
        return const Left(NodeFailure.configChanged());
      }

      // 3. Parse + mutate a copy.
      Map<String, dynamic> config;
      try {
        final decoded = jsonDecode(freshContent);
        if (decoded is! Map<String, dynamic>) {
          return const Left(NodeFailure.invalidStructure('root is not an object'));
        }
        config = NodeJson.deepCopyMap(decoded);
      } catch (e) {
        return Left<NodeFailure, ProfileEntity>(NodeFailure.unexpected(e));
      }
      final mutateResult = mutate(config);
      if (mutateResult.isLeft()) {
        return Left<NodeFailure, ProfileEntity>(mutateResult.getLeft().toNullable()!);
      }

      // 4. Persist via repository (core validates + writes the file).
      final saveResult = await _profilesRepo.offlineUpdate(profile, jsonEncode(config)).run();
      if (saveResult.isLeft()) {
        final err = saveResult.getLeft().toNullable()!;
        return Left<NodeFailure, ProfileEntity>(NodeFailure.validationFailed(err.toString()));
      }

      // 5. Re-read the saved entity.
      return loadProfile(profileId);
    });
  }

  /// Updates one outbound. When [newDraft] carries a different tag this is
  /// a rename: references are synced first, then the node is replaced.
  Future<Either<NodeFailure, ProfileEntity>> updateNode({
    required String profileId,
    required String expectedRawContent,
    required String rawTag,
    required Map<String, dynamic> newDraft,
  }) {
    return _commit(
      profileId: profileId,
      expectedRawContent: expectedRawContent,
      mutate: (config) {
        final found = findOutbound(config, rawTag);
        if (found.isLeft()) return Left(found.getLeft().toNullable()!);
        final outbounds = config['outbounds'] as List;
        final index = outbounds.indexWhere((o) => o is Map<String, dynamic> && o['tag'] == rawTag);

        final newTag = newDraft['tag'];
        if (newTag is! String || newTag.isEmpty) {
          return const Left(NodeFailure.invalidStructure('missing tag'));
        }
        if (newTag != rawTag) {
          if (outbounds.any((o) => o is Map<String, dynamic> && o['tag'] == newTag)) {
            return const Left(NodeFailure.duplicateName());
          }
          final endpoints = config['endpoints'];
          if (endpoints is List &&
              endpoints.any((e) => e is Map<String, dynamic> && e['tag'] == newTag)) {
            return const Left(NodeFailure.duplicateName());
          }
          final check = NodeReferenceSync.check(config: config, tag: rawTag);
          if (check.hasBlockingRefs) {
            return Left(NodeFailure.referenceConflict(
              [...check.ruleTargets, ...check.patternRefs].join(', '),
            ));
          }
          // Sync refs while the old tag still exists, then replace.
          NodeReferenceSync.applyRename(config: config, oldTag: rawTag, newTag: newTag);
        }
        outbounds[index] = newDraft;
        return const Right(null);
      },
    );
  }

  /// Appends a new outbound; optionally joins [groupTags].
  Future<Either<NodeFailure, ProfileEntity>> addNode({
    required String profileId,
    required String expectedRawContent,
    required Map<String, dynamic> draft,
    required List<String> groupTags,
  }) {
    return _commit(
      profileId: profileId,
      expectedRawContent: expectedRawContent,
      mutate: (config) {
        final tag = draft['tag'];
        if (tag is! String || tag.isEmpty) {
          return const Left(NodeFailure.invalidStructure('missing tag'));
        }
        var outbounds = config['outbounds'];
        if (outbounds == null) {
          outbounds = <dynamic>[];
          config['outbounds'] = outbounds;
        }
        if (outbounds is! List) {
          return const Left(NodeFailure.invalidStructure('outbounds is not an array'));
        }
        if (outbounds.any((o) => o is Map<String, dynamic> && o['tag'] == tag)) {
          return const Left(NodeFailure.duplicateName());
        }
        final endpoints = config['endpoints'];
        if (endpoints is List && endpoints.any((e) => e is Map<String, dynamic> && e['tag'] == tag)) {
          return const Left(NodeFailure.duplicateName());
        }
        outbounds.add(draft);
        for (final groupTag in groupTags) {
          for (final o in outbounds.whereType<Map<String, dynamic>>()) {
            if (o['tag'] != groupTag) continue;
            final members = o['outbounds'];
            if (members is List && !members.contains(tag)) members.add(tag);
          }
        }
        return const Right(null);
      },
    );
  }

  /// Deletes one outbound after reference safety checks.
  Future<Either<NodeFailure, ProfileEntity>> deleteNode({
    required String profileId,
    required String expectedRawContent,
    required String rawTag,
  }) {
    return _commit(
      profileId: profileId,
      expectedRawContent: expectedRawContent,
      mutate: (config) {
        final found = findOutbound(config, rawTag);
        if (found.isLeft()) return Left(found.getLeft().toNullable()!);

        final check = NodeReferenceSync.check(config: config, tag: rawTag);
        if (check.hasBlockingRefs) {
          return Left(NodeFailure.referenceConflict(
            [...check.ruleTargets, ...check.patternRefs].join(', '),
          ));
        }
        if (check.finalRoute || check.detours.isNotEmpty) {
          return Left(NodeFailure.referenceConflict(
            [if (check.finalRoute) 'route.final', ...check.detours.map((d) => 'detour:$d')].join(', '),
          ));
        }
        if (check.defaults.isNotEmpty) {
          return Left(NodeFailure.referenceConflict('default:${check.defaults.join(',')}'));
        }

        final outbounds = config['outbounds'] as List;
        final proxyCount = outbounds
            .whereType<Map<String, dynamic>>()
            .where((o) => NodeProtocolTemplates.isSupported(o['type'] as String?))
            .length;
        if (proxyCount <= 1) {
          return const Left(NodeFailure.wouldBreakConfig('last proxy node'));
        }
        for (final g in check.groups) {
          final group = outbounds.whereType<Map<String, dynamic>>().where((o) => o['tag'] == g).firstOrNull;
          final members = group?['outbounds'];
          if (members is List && members.length <= 1) {
            return Left(NodeFailure.wouldBreakConfig('group $g would become empty'));
          }
        }

        NodeReferenceSync.applyDeleteMemberRefs(config: config, tag: rawTag);
        outbounds.removeWhere((o) => o is Map<String, dynamic> && o['tag'] == rawTag);
        return const Right(null);
      },
    );
  }

  /// Extracts a complete outbound for share-link encoding. Read-only:
  /// allowed for remote profiles too.
  Future<Either<NodeFailure, Map<String, dynamic>>> extractForShare(String profileId, String rawTag) async {
    final configEither = await loadConfig(profileId);
    if (configEither.isLeft()) {
      return Left(configEither.getLeft().toNullable()!);
    }
    return findOutbound(configEither.getRight().toNullable()!.config, rawTag);
  }

  /// Convenience: extract + encode in one call.
  Future<Either<NodeFailure, NodeShareOutcome>> shareLink(String profileId, String rawTag) async {
    final extracted = await extractForShare(profileId, rawTag);
    if (extracted.isLeft()) {
      return Left(extracted.getLeft().toNullable()!);
    }
    final outcome = NodeShareLinkEncoder.encode(extracted.getRight().toNullable()!);
    if (outcome.blocked) {
      return Left(NodeFailure.shareUnsupported(outcome.blockedReason!));
    }
    return Right(outcome);
  }
}
