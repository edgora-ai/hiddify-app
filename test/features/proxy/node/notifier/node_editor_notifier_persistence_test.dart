import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/model/node_failure.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../profile/data/profile_commit_test_support.dart';
import 'node_editor_test_support.dart';

class _UnavailableActiveProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.error(StateError('synthetic active-profile lookup failure'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProfileCommitHarness storage;
  late TestProfileRepository repository;
  late ProviderContainer container;
  late ProfileEntity profile;
  final t = TranslationsEn();
  final provider = nodeEditorNotifierProvider(testProfileId, 'A');

  setUp(() async {
    storage = await ProfileCommitHarness.create();
    repository = storage.repository();
    profile = await storage.seed();
    container = editorContainer(repository);
    await container.read(profileRepositoryProvider.future);
    await container.read(translationsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await storage.dispose();
  });

  Future<NodeEditorNotifier> open() async {
    container.listen(provider, (_, _) {});
    await container.read(provider.future);
    return container.read(provider.notifier);
  }

  test('conflict stays blocked on second save and reload coordinates the entire node', () async {
    final notifier = await open();
    final originalSnapshot = container.read(provider).requireValue.rawContentSnapshot;
    notifier.setPath(['server'], 'edited.example.invalid');
    final other = originalConfig();
    ((other['outbounds'] as List).first as Map)['password'] = 'concurrent-password';
    requireRight(await storage.repository().offlineUpdate(profile, jsonEncode(other)).run());
    final writesBefore = repository.validationInputs.length;

    final first = await notifier.save(t);
    expect(first.failure, isA<NodeConfigChanged>());
    final conflict = container.read(provider).requireValue;
    expect(conflict.needsReload, isTrue);
    expect(conflict.rawContentSnapshot, originalSnapshot);
    expect(conflict.draft['password'], 'original-password');
    expect(conflict.draft['server'], 'edited.example.invalid');
    expect(conflict.isDirty, isTrue);

    final second = await notifier.save(t);
    expect(second.failure, isA<NodeConfigChanged>());
    expect(repository.validationInputs, hasLength(writesBefore));
    expect(container.read(provider).requireValue.rawContentSnapshot, originalSnapshot);
    await storage.verifyStored(repository, other);

    notifier.reload();
    final reloaded = await container.read(provider.future);
    expect(reloaded.needsReload, isFalse);
    expect(reloaded.draft, (other['outbounds'] as List).first);
    expect(reloaded.originalDraft, reloaded.draft);
    expect(reloaded.isDirty, isFalse);
    notifier.setPath(['server'], 'coordinated.example.invalid');
    expect((await notifier.save(t)).kind, NodeSaveKind.saved);
    ((other['outbounds'] as List).first as Map)['server'] = 'coordinated.example.invalid';
    await storage.verifyStored(repository, other);
  });

  test('reload after conflicting deletion fails instead of recreating the original node', () async {
    final notifier = await open();
    notifier.setPath(['server'], 'edited.example.invalid');
    final other = originalConfig();
    (other['outbounds'] as List).removeAt(0);
    requireRight(await storage.repository().offlineUpdate(profile, jsonEncode(other)).run());
    expect((await notifier.save(t)).failure, isA<NodeConfigChanged>());
    notifier.reload();
    await expectLater(container.read(provider.future), throwsA(isA<NodeNotFound>()));
    final readback = jsonDecode(await storage.paths.file(profile.id).readAsString()) as Map;
    expect(readback, other);
    expect((readback['outbounds'] as List).whereType<Map>().where((node) => node['tag'] == 'A'), isEmpty);
    expect(requireRight(await repository.getById(profile.id).run())!.userOverride, testOverride);
    expect((await storage.dao.getByName(profile.name))?.id, profile.id);
  });

  test('delayed save freezes every draft mutator and confirms only submitted D0', () async {
    final notifier = await open();
    notifier.setPath(['server'], 'submitted.example.invalid');
    final submitted = NodeJson.deepCopyMap(container.read(provider).requireValue.draft);
    final entered = Completer<void>();
    final release = Completer<void>();
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final saving = notifier.save(t);
    await entered.future;
    expect(container.read(provider).requireValue.isSaving, isTrue);
    notifier.setPath(['password'], 'must-not-enter');
    notifier.setTlsMode('none');
    notifier.toggleGroup('select', true);
    notifier.switchProtocol('vmess', keepName: 'must-not-enter');
    expect(notifier.validate(t), isFalse);
    expect((await notifier.save(t)).kind, NodeSaveKind.aborted);
    expect(container.read(provider).requireValue.draft, submitted);
    expect(container.read(provider).requireValue.selectedGroups, isEmpty);
    release.complete();
    expect((await saving).kind, NodeSaveKind.saved);
    final saved = container.read(provider).requireValue;
    expect(saved.originalDraft, submitted);
    expect(saved.draft, submitted);
    expect(saved.isDirty, isFalse);
    final expected = originalConfig();
    (expected['outbounds'] as List)[0] = submitted;
    await storage.verifyStored(repository, expected);
  });

  test('unexpected D1 remains dirty rather than being acknowledged as persisted D0', () async {
    container.dispose();
    container = editorContainer(repository, overrides: [provider.overrideWith(InjectingNodeEditorNotifier.new)]);
    await container.read(profileRepositoryProvider.future);
    final notifier = (await open()) as InjectingNodeEditorNotifier;
    notifier.setPath(['server'], 'submitted.example.invalid');
    final submitted = NodeJson.deepCopyMap(container.read(provider).requireValue.draft);
    final entered = Completer<void>();
    final release = Completer<void>();
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final saving = notifier.save(t);
    await entered.future;
    final newer = NodeJson.deepCopyMap(submitted)..['password'] = 'newer-unsubmitted-password';
    notifier.injectDraft(newer);
    release.complete();
    expect((await saving).kind, NodeSaveKind.saved);
    final saved = container.read(provider).requireValue;
    expect(saved.originalDraft, submitted);
    expect(saved.draft, newer);
    expect(saved.isDirty, isTrue);
    final expected = originalConfig();
    (expected['outbounds'] as List)[0] = submitted;
    await storage.verifyStored(repository, expected);
  });

  test('active target lookup failure after persistence leaves saved data and a non-busy apply failure', () async {
    container.dispose();
    container = editorContainer(
      repository,
      overrides: [activeProfileProvider.overrideWith(_UnavailableActiveProfile.new)],
    );
    await container.read(profileRepositoryProvider.future);
    final notifier = await open();
    notifier.setPath(['server'], 'saved.example.invalid');
    expect((await notifier.save(t)).kind, NodeSaveKind.applyFailed);
    final saved = container.read(provider).requireValue;
    expect(saved.isSaving, isFalse);
    expect(saved.isDirty, isFalse);
    expect(saved.savePhase, NodeSavePhase.applyFailed);
    final expected = originalConfig();
    ((expected['outbounds'] as List).first as Map)['server'] = 'saved.example.invalid';
    await storage.verifyStored(repository, expected);
  });

  test('reserved DNS matcher target is a save failure, never an unhandled busy editor', () async {
    final config = originalConfig();
    (config['dns'] as Map)['rules'] = [
      {
        'outbound': ['A', 'any'],
        'server': 'dns',
      },
    ];
    (config['route'] as Map)['final'] = 'A';
    requireRight(await repository.offlineUpdate(profile, jsonEncode(config)).run());
    final notifier = await open();
    notifier.setPath(['tag'], 'any');
    final result = await notifier.save(t);
    expect(result.failure, isA<NodeValidationFailed>());
    final failed = container.read(provider).requireValue;
    expect(failed.isSaving, isFalse);
    expect(failed.savePhase, NodeSavePhase.saveFailed);
    expect(failed.draft['tag'], 'any');
    expect(failed.originalDraft, originalNode());
    expect(failed.isDirty, isTrue);
    await storage.verifyStored(repository, config);
  });

  test('validation failure preserves unsaved draft and existing complete config', () async {
    final notifier = await open();
    notifier.setPath(['password'], 'unsaved-password');
    repository.rejectValidation = true;
    expect((await notifier.save(t)).failure, isA<NodeValidationFailed>());
    final failed = container.read(provider).requireValue;
    expect(failed.savePhase, NodeSavePhase.saveFailed);
    expect(failed.draft['password'], 'unsaved-password');
    expect(failed.originalDraft, originalNode());
    expect(failed.isDirty, isTrue);
    await storage.verifyStored(repository, originalConfig());
  });
}
