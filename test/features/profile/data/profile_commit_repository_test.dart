import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';

import 'profile_commit_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProfileCommitHarness storage;
  late TestProfileRepository repository;

  setUp(() async {
    storage = await ProfileCommitHarness.create();
    repository = storage.repository();
  });

  tearDown(() => storage.dispose());

  for (final remote in [false, true]) {
    test('override-only $remote keeps exact full config bytes and all unrelated metadata', () async {
      final profile = await storage.seed(remote: remote);
      final raw = await storage.paths.file(profile.id).readAsString();
      final override = testOverride.copyWith(preserveDomainForFallbackProxy: true);
      requireRight(
        await repository
            .commitDetails(profile.copyWith(userOverride: override), expectedUserOverride: testOverride)
            .run(),
      );
      expect(await storage.paths.file(profile.id).readAsString(), raw);
      expect(repository.validationInputs, isEmpty);
      await storage.verifyStored(repository, originalConfig(), userOverride: override);
      if (remote) {
        final restored = requireRight(await repository.getById(profile.id).run())! as RemoteProfileEntity;
        expect(restored.url, (profile as RemoteProfileEntity).url);
      }
    });
  }

  test('explicit full-document edit requires original raw snapshot at submission', () async {
    final profile = await storage.seed();
    final raw = await storage.paths.file(profile.id).readAsString();
    final edited = originalConfig();
    ((edited['outbounds'] as List).first as Map)['server_port'] = 9443;
    requireRight(
      await repository
          .commitDetails(
            profile,
            expectedUserOverride: testOverride,
            content: jsonEncode(edited),
            expectedRawContent: raw,
          )
          .run(),
    );
    await storage.verifyStored(repository, edited);

    final stale = await repository
        .commitDetails(profile, expectedUserOverride: testOverride, content: raw, expectedRawContent: raw)
        .run();
    expect(
      stale.getLeft().toNullable(),
      isA<ProfileUnexpectedFailure>().having((error) => error.error, 'cause', isA<ProfileCommitConflict>()),
    );
    await storage.verifyStored(repository, edited);
  });

  test('stale override cannot replace another writer override', () async {
    final profile = await storage.seed();
    final override = testOverride.copyWith(extraSecurity: 'psiphon');
    requireRight(
      await repository
          .commitDetails(profile.copyWith(userOverride: override), expectedUserOverride: testOverride)
          .run(),
    );
    final stale = await storage
        .repository()
        .commitDetails(
          profile.copyWith(userOverride: testOverride.copyWith(preserveDomainForFallbackProxy: true)),
          expectedUserOverride: testOverride,
        )
        .run();
    expect(
      stale.getLeft().toNullable(),
      isA<ProfileUnexpectedFailure>().having((error) => error.error, 'cause', isA<ProfileCommitConflict>()),
    );
    await storage.verifyStored(repository, originalConfig(), userOverride: override);
  });

  test('remote refresh queues behind actual offline commit and rereads the latest override', () async {
    final profile = (await storage.seed(remote: true)) as RemoteProfileEntity;
    final entered = Completer<void>();
    final release = Completer<void>();
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final override = testOverride.copyWith(preserveDomainForFallbackProxy: true);
    final first = repository
        .offlineUpdate(profile.copyWith(userOverride: override), jsonEncode(originalConfig()))
        .run();
    await entered.future;

    final refreshed = originalConfig();
    (refreshed['outbounds'] as List).add(addedNode());
    storage.parser.remoteContent = jsonEncode(refreshed);
    final remoteRepository = storage.repository();
    final second = remoteRepository.upsertRemote(profile.url).run();
    // DB read is deliberately awaited while the first writer still owns its
    // validation gate. The lazy remote task must not touch a temp file yet.
    await storage.dao.getById(profile.id);
    expect(storage.parser.remoteUpdates, 0);
    expect(remoteRepository.validationInputs, isEmpty);
    release.complete();
    requireRight(await first);
    requireRight(await second);
    expect(storage.parser.remoteUpdates, 1);
    expect(repository.validationInputs.single, isNot(remoteRepository.validationInputs.single));
    expect(
      await storage.paths.directory.list(followLinks: false).where((entry) => entry.path.endsWith('.tmp.json')).length,
      0,
    );
    await storage.verifyStored(remoteRepository, refreshed, userOverride: override);
  });
}
