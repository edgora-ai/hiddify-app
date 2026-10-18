import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
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

  final headerCases = <({String name, String? stored, Map<String, dynamic>? expected})>[
    (name: 'SQL NULL', stored: null, expected: null),
    (name: 'JSON null', stored: 'null', expected: null),
    (name: 'empty object', stored: '{}', expected: <String, dynamic>{}),
    (
      name: 'complete object',
      stored: '{"profile-title":"Header title","future-header":{"enabled":true,"values":[null,7,"kept"]}}',
      expected: <String, dynamic>{
        'profile-title': 'Header title',
        'future-header': <String, dynamic>{
          'enabled': true,
          'values': <dynamic>[null, 7, 'kept'],
        },
      },
    ),
  ];

  for (final remote in [false, true]) {
    for (final headers in headerCases) {
      test('$remote ${headers.name} headers preserve the nullable entity and full DB roundtrip', () async {
        final original = await storage.seed(remote: remote);
        // New writes use SQL NULL; the JSON-null case below models rows written
        // by the previous mapper, not an invalid fixture or an empty object.
        expect(original.toInsertEntry().populatedHeaders.value, isNull);
        expect(ProfileParser.profileOverrideHelper(profile: original.toInsertEntry()), original.profileOverride());
        final initial = await storage.db
            .customSelect(
              'SELECT populated_headers FROM profile_entries WHERE id = ?',
              variables: [Variable<String>(original.id)],
            )
            .getSingle();
        expect(initial.data['populated_headers'], isNull);
        await storage.dao.edit(original.id, ProfileEntriesCompanion(populatedHeaders: Value(headers.stored)));
        final stored = await storage.db
            .customSelect(
              'SELECT populated_headers FROM profile_entries WHERE id = ?',
              variables: [Variable<String>(original.id)],
            )
            .getSingle();
        expect(stored.data['populated_headers'], headers.stored);
        final expected = original.copyWith(populatedHeaders: headers.expected);
        final restored = (await storage.dao.getById(original.id))!.toEntity();
        expect(restored, expected);
        expect(requireRight(await repository.getById(original.id).run()), expected);
        expect((await storage.dao.getByName(restored.name))!.toEntity(), expected);
        final afterReads = await storage.db
            .customSelect(
              'SELECT populated_headers FROM profile_entries WHERE id = ?',
              variables: [Variable<String>(original.id)],
            )
            .getSingle();
        expect(afterReads.data['populated_headers'], headers.stored);

        // This is an explicit writer roundtrip, not a normalization on read.
        expect(ProfileParser.profileOverrideHelper(profile: restored.toUpdateEntry()), restored.profileOverride());
        await storage.dao.edit(original.id, restored.toUpdateEntry());
        final updated = await storage.db
            .customSelect(
              'SELECT populated_headers FROM profile_entries WHERE id = ?',
              variables: [Variable<String>(original.id)],
            )
            .getSingle();
        expect(updated.data['populated_headers'], headers.expected == null ? null : jsonEncode(headers.expected));
        expect((await storage.dao.getById(original.id))!.toEntity(), expected);
        expect((await storage.dao.getByName(restored.name))!.toEntity(), expected);
        await storage.verifyStored(repository, originalConfig());
      });
    }

    test(
      'override-only $remote preserves config/metadata while explicitly rewriting legacy null as SQL NULL',
      () async {
        final profile = await storage.seed(remote: remote);
        await storage.dao.edit(profile.id, const ProfileEntriesCompanion(populatedHeaders: Value('null')));
        final before = await storage.db
            .customSelect(
              'SELECT populated_headers FROM profile_entries WHERE id = ?',
              variables: [Variable<String>(profile.id)],
            )
            .getSingle();
        expect(before.data['populated_headers'], 'null');
        final raw = await storage.paths.file(profile.id).readAsString();
        final override = testOverride.copyWith(preserveDomainForFallbackProxy: true);
        requireRight(
          await repository
              .commitDetails(profile.copyWith(userOverride: override), expectedUserOverride: testOverride)
              .run(),
        );
        expect(await storage.paths.file(profile.id).readAsString(), raw);
        expect(repository.validationInputs, isEmpty);
        final after = await storage.db
            .customSelect(
              'SELECT populated_headers FROM profile_entries WHERE id = ?',
              variables: [Variable<String>(profile.id)],
            )
            .getSingle();
        expect(after.data['populated_headers'], isNull);
        final entry = (await storage.dao.getById(profile.id))!;
        expect(entry.toEntity(), profile.copyWith(userOverride: override, lastUpdate: entry.lastUpdate));
        await storage.verifyStored(repository, originalConfig(), userOverride: override);
        if (remote) {
          final restored = requireRight(await repository.getById(profile.id).run())! as RemoteProfileEntity;
          expect(restored.url, (profile as RemoteProfileEntity).url);
        }
      },
    );
  }

  for (final invalid in ['[]', '42', 'true', '"synthetic-header-secret"', '{"synthetic-header-secret":']) {
    test('invalid headers $invalid fail without rewriting storage or exposing their source', () async {
      final profile = await storage.seed();
      final bytes = await storage.paths.file(profile.id).readAsString();
      await storage.dao.edit(profile.id, ProfileEntriesCompanion(populatedHeaders: Value(invalid)));
      final row = await storage.db
          .customSelect(
            'SELECT populated_headers FROM profile_entries WHERE id = ?',
            variables: [Variable<String>(profile.id)],
          )
          .getSingle();
      expect(row.data['populated_headers'], invalid);
      final rawEntry = (await storage.dao.getById(profile.id))!;
      expect(rawEntry.toEntity, throwsFormatException);
      final result = await repository.getById(profile.id).run();
      final failure = result.getLeft().toNullable();
      expect(
        failure,
        isA<ProfileUnexpectedFailure>().having(
          (error) => error.error,
          'cause',
          isA<FormatException>().having((error) => error.source, 'stored source', isNull),
        ),
      );
      expect(failure.toString(), isNot(contains('synthetic-header-secret')));
      expect((await storage.dao.getByName(profile.name))!.populatedHeaders, invalid);
      expect((await storage.dao.getById(profile.id))!.populatedHeaders, invalid);
      expect(requireRight(await repository.getRawConfig(profile.id).run()), bytes);
      expect(await storage.paths.file(profile.id).readAsString(), bytes);
    });
  }

  test('checkpoint reports an early mapper Left instead of waiting for validation forever', () async {
    final profile = await storage.seed();
    await storage.dao.edit(profile.id, const ProfileEntriesCompanion(populatedHeaders: Value('[]')));
    final entered = Completer<void>();
    final release = Completer<void>();
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final operation = repository.offlineUpdate(profile, jsonEncode(originalConfig())).run();
    try {
      await expectLater(
        waitForCheckpoint(entered.future, operation, description: 'offlineUpdate validation'),
        throwsA(
          isA<TestFailure>().having(
            (error) => error.message,
            'missing checkpoint',
            contains('offlineUpdate validation was not reached'),
          ),
        ),
      );
      expect(repository.validationInputs, isEmpty);
      expect(entered.isCompleted, isFalse);
    } finally {
      await releaseAndSettle(release, [operation]);
    }
    final failure = (await operation).getLeft().toNullable();
    expect(failure, isA<ProfileUnexpectedFailure>().having((error) => error.error, 'cause', isA<FormatException>()));
  });

  test('checkpoint propagates a pre-validation throw unchanged', () async {
    final failure = StateError('synthetic pre-validation failure');
    await expectLater(
      waitForCheckpoint(Completer<void>().future, Future<void>.error(failure), description: 'validation'),
      throwsA(same(failure)),
    );
  });

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
    final pending = <Future<Object?>>[first];
    try {
      await waitForCheckpoint(entered.future, first, description: 'offlineUpdate validation before remote refresh');
      final refreshed = originalConfig();
      (refreshed['outbounds'] as List).add(addedNode());
      storage.parser.remoteContent = jsonEncode(refreshed);
      final remoteRepository = storage.repository();
      final second = remoteRepository.upsertRemote(profile.url).run();
      pending.add(second);
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
        await storage.paths.directory
            .list(followLinks: false)
            .where((entry) => entry.path.endsWith('.tmp.json'))
            .length,
        0,
      );
      await storage.verifyStored(remoteRepository, refreshed, userOverride: override);
    } finally {
      await releaseAndSettle(release, pending);
    }
  });
}
