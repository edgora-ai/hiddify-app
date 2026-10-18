import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/proxy/node/data/node_config_service.dart';
import 'package:hiddify/features/proxy/node/model/node_failure.dart';

import '../../../profile/data/profile_commit_test_support.dart';

class _PauseAfterProfileRead extends NodeConfigService {
  _PauseAfterProfileRead(ProfileRepository repository) : super(repository);

  final read = Completer<void>();
  final release = Completer<void>();
  bool _paused = false;

  @override
  Future<Either<NodeFailure, ProfileEntity>> loadProfile(String profileId) async {
    final result = await super.loadProfile(profileId);
    if (result.isLeft()) return result;
    if (!_paused) {
      _paused = true;
      read.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProfileCommitHarness storage;
  late TestProfileRepository repository;
  late NodeConfigService service;
  late ProfileEntity profile;
  late String raw;

  setUp(() async {
    storage = await ProfileCommitHarness.create();
    repository = storage.repository();
    service = NodeConfigService(repository);
    profile = await storage.seed();
    raw = requireRight(await repository.getRawConfig(profile.id).run());
  });

  tearDown(() => storage.dispose());

  test('add preserves the entire original node, unknown config and user override in real storage', () async {
    requireRight(
      await service.addNode(profileId: profile.id, expectedRawContent: raw, draft: addedNode(), groupTags: ['select']),
    );
    final expected = originalConfig();
    final outbounds = expected['outbounds'] as List;
    outbounds.add(addedNode());
    ((outbounds[1] as Map)['outbounds'] as List).add('B');
    await storage.verifyStored(repository, expected);
    final readback = requireRight(await service.loadConfig(profile.id));
    expect(requireRight(service.findOutbound(readback.config, 'A')), originalNode());
    expect(requireRight(service.findOutbound(readback.config, 'B')), addedNode());
    expect(
      service.listEntries(readback.config).map((node) => node.rawTag),
      containsAll(['A', 'B', 'select', 'direct']),
    );
  });

  test('checked task compares when run, not when constructed', () async {
    final proposed = originalConfig();
    (proposed['outbounds'] as List).add(addedNode());
    final task = repository.commitConfig(profile.id, jsonEncode(proposed), expectedRawContent: raw);
    expect(repository.validationInputs, isEmpty);

    final other = originalConfig();
    ((other['outbounds'] as List).first as Map)['password'] = 'other-writer-password';
    requireRight(await storage.repository().offlineUpdate(profile, jsonEncode(other)).run());
    final conflict = (await task.run()).getLeft().toNullable();
    expect(
      conflict,
      isA<ProfileUnexpectedFailure>().having((error) => error.error, 'cause', isA<ProfileCommitConflict>()),
    );
    expect(repository.validationInputs, isEmpty);
    await storage.verifyStored(repository, other);
  });

  test('detail C1 commit between node C0 read and submission rejects stale node write', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final detailWriter = storage.repository();
    detailWriter.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final other = originalConfig();
    ((other['outbounds'] as List).first as Map)['password'] = 'detail-writer-password';
    final detailSave = detailWriter.offlineUpdate(profile, jsonEncode(other)).run();
    final pending = <Future<Object?>>[detailSave];
    try {
      await waitForCheckpoint(entered.future, detailSave, description: 'detail writer validation');
      expect(await storage.paths.file(profile.id).readAsString(), raw);
      final requested = Completer<void>();
      repository.configCommitRequested = requested;
      final nodeSave = service.addNode(
        profileId: profile.id,
        expectedRawContent: raw,
        draft: addedNode(),
        groupTags: [],
      );
      pending.add(nodeSave);
      await waitForCheckpoint(requested.future, nodeSave, description: 'node checked commit request');
      expect(repository.validationInputs, isEmpty);
      release.complete();
      requireRight(await detailSave);
      expect((await nodeSave).getLeft().toNullable(), isA<NodeConfigChanged>());
      await storage.verifyStored(repository, other);
      expect(
        await storage.paths.directory
            .list(followLinks: false)
            .where((entry) => entry.path.endsWith('.tmp.json'))
            .length,
        0,
      );
    } finally {
      await releaseAndSettle(release, pending);
    }
  });

  test('node commit holds the shared lock through TaskEither.run before override-only save', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final nodeSave = service.addNode(profileId: profile.id, expectedRawContent: raw, draft: addedNode(), groupTags: []);
    final pending = <Future<Object?>>[nodeSave];
    try {
      await waitForCheckpoint(entered.future, nodeSave, description: 'node writer validation');
      final detailWriter = storage.repository();
      final override = testOverride.copyWith(preserveDomainForFallbackProxy: true);
      final detailSave = detailWriter
          .commitDetails(profile.copyWith(userOverride: override), expectedUserOverride: testOverride)
          .run();
      pending.add(detailSave);
      // No DB edit may escape the first writer's pending validation.
      expect((await storage.dao.getById(profile.id))!.userOverride, testOverride.toStr());
      release.complete();
      requireRight(await nodeSave);
      requireRight(await detailSave);
      final expected = originalConfig();
      (expected['outbounds'] as List).add(addedNode());
      await storage.verifyStored(repository, expected, userOverride: override);
      expect(detailWriter.validationInputs, isEmpty);
    } finally {
      await releaseAndSettle(release, pending);
    }
  });

  test('node content commit uses the latest override instead of the preflight entity', () async {
    final paused = _PauseAfterProfileRead(repository);
    final nodeSave = paused.addNode(profileId: profile.id, expectedRawContent: raw, draft: addedNode(), groupTags: []);
    try {
      await waitForCheckpoint(paused.read.future, nodeSave, description: 'successful node profile read');
      final override = testOverride.copyWith(preserveDomainForFallbackProxy: true);
      requireRight(
        await storage
            .repository()
            .commitDetails(profile.copyWith(userOverride: override), expectedUserOverride: testOverride)
            .run(),
      );
      paused.release.complete();
      requireRight(await nodeSave);
      final expected = originalConfig();
      (expected['outbounds'] as List).add(addedNode());
      await storage.verifyStored(repository, expected, userOverride: override);
    } finally {
      await releaseAndSettle(paused.release, [nodeSave]);
    }
  });

  test('failed validation releases lock and removes only its own temporary file', () async {
    repository.rejectValidation = true;
    expect(
      (await service.addNode(
        profileId: profile.id,
        expectedRawContent: raw,
        draft: addedNode(),
        groupTags: [],
      )).getLeft().toNullable(),
      isA<NodeValidationFailed>(),
    );
    await storage.verifyStored(repository, originalConfig());
    repository.rejectValidation = false;
    requireRight(
      await service.addNode(profileId: profile.id, expectedRawContent: raw, draft: addedNode(), groupTags: []),
    );
    expect(repository.validationInputs.toSet(), hasLength(2));
    expect(
      await storage.paths.directory.list(followLinks: false).where((entry) => entry.path.endsWith('.tmp.json')).length,
      0,
    );
    final expected = originalConfig();
    (expected['outbounds'] as List).add(addedNode());
    await storage.verifyStored(repository, expected);
  });

  test('reserved any rename returns validation failure with no partial reference or storage write', () async {
    final config = originalConfig();
    (config['route'] as Map)['final'] = 'A';
    ((config['outbounds'] as List)[1] as Map)['default'] = 'A';
    ((config['outbounds'] as List)[2] as Map)['detour'] = 'A';
    (config['dns'] as Map)['rules'] = [
      {'outbound': 'A', 'server': 'dns'},
      {
        'type': 'logical',
        'mode': 'or',
        'rules': [
          {
            'outbound': ['A', 'any'],
            'server': 'dns',
          },
        ],
      },
    ];
    config['services'] = [
      {'type': 'ccm', 'detour': 'A'},
      {'type': 'ocm', 'detour': 'A'},
    ];
    requireRight(await repository.offlineUpdate(profile, jsonEncode(config)).run());
    final before = await storage.paths.file(profile.id).readAsString();
    final validations = repository.validationInputs.length;
    final draft = originalNode()..['tag'] = 'any';
    final result = await service.updateNode(
      profileId: profile.id,
      expectedRawContent: before,
      rawTag: 'A',
      newDraft: draft,
    );
    expect(
      result.getLeft().toNullable(),
      isA<NodeValidationFailed>().having((error) => error.detail, 'cause', contains('reservedDnsOutboundMatcher')),
    );
    expect(repository.validationInputs, hasLength(validations));
    expect(await storage.paths.file(profile.id).readAsString(), before);
    await storage.verifyStored(repository, config);
    final loaded = requireRight(await service.loadConfig(profile.id));
    expect(requireRight(service.findOutbound(loaded.config, 'A')), originalNode());
    expect(service.findOutbound(loaded.config, 'any').getLeft().toNullable(), isA<NodeNotFound>());
  });

  test('a deleted profile cannot be rebuilt by a stale node submission', () async {
    requireRight(await repository.deleteById(profile.id, false).run());
    expect(
      (await service.addNode(
        profileId: profile.id,
        expectedRawContent: raw,
        draft: addedNode(),
        groupTags: [],
      )).getLeft().toNullable(),
      isA<NodeNotFound>(),
    );
    expect(await storage.paths.file(profile.id).exists(), isFalse);
    expect(await storage.db.customSelect('SELECT id FROM profile_entries').get(), isEmpty);
    expect(requireRight(await repository.getById(profile.id).run()), isNull);
    expect(await storage.dao.getByName(profile.name), isNull);
  });
}
