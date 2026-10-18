import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/details/profile_details_notifier.dart';
import 'package:hiddify/features/profile/details/profile_details_page.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/proxy/node/data/node_config_service.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/node_editor_page.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../data/profile_commit_test_support.dart';
import '../../proxy/node/notifier/node_editor_test_support.dart';

void main() {
  late ProfileCommitHarness storage;
  late TestProfileRepository repository;
  late ProviderContainer container;
  late TestDialogs dialogs;
  final t = TranslationsEn();
  final details = profileDetailsNotifierProvider(testProfileId);

  setUp(() async {
    storage = await ProfileCommitHarness.create();
    repository = storage.repository();
    await storage.seed();
    dialogs = TestDialogs();
    container = editorContainer(repository, dialogs: dialogs);
    await container.read(profileRepositoryProvider.future);
    await container.read(translationsProvider.future);
    container.listen(details, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await storage.dispose();
  });

  test('stale details fallback save preserves child-added B and every original configuration field', () async {
    final parent = await container.read(details.future);
    expect(jsonDecode(parent.configContent), originalConfig());
    requireRight(
      await NodeConfigService(
        repository,
      ).addNode(profileId: testProfileId, expectedRawContent: parent.configContent, draft: addedNode(), groupTags: []),
    );
    final childBytes = await storage.paths.file(testProfileId).readAsString();
    expect(container.read(details).requireValue.configContent, parent.configContent);
    final notifier = container.read(details.notifier);
    final override = testOverride.copyWith(preserveDomainForFallbackProxy: true);
    notifier.setUserOverride(override);
    expect(await notifier.save(), isTrue);
    expect(await storage.paths.file(testProfileId).readAsString(), childBytes);
    final expected = originalConfig();
    (expected['outbounds'] as List).add(addedNode());
    await storage.verifyStored(repository, expected, userOverride: override);
    expect(repository.validationInputs, hasLength(1));
  });

  test('untouched generated display for non-JSON input is not written on fallback save', () async {
    const source = 'trojan://synthetic-password@source.example.invalid:443#Synthetic';
    await storage.paths.file(testProfileId).writeAsString(source);
    repository.generatedContent = jsonEncode(originalConfig());
    final parent = await container.read(details.future);
    expect(jsonDecode(parent.configContent), originalConfig());
    final override = testOverride.copyWith(preserveDomainForFallbackProxy: true);
    final notifier = container.read(details.notifier);
    notifier.setUserOverride(override);
    expect(await notifier.save(), isTrue);
    expect(await storage.paths.file(testProfileId).readAsString(), source);
    expect(repository.validationInputs, isEmpty);
    final row = await storage.db
        .customSelect(
          'SELECT user_override FROM profile_entries WHERE id = ?',
          variables: [Variable<String>(testProfileId)],
        )
        .getSingle();
    expect(UserOverride.fromStr(row.read<String>('user_override')), override);
    expect(requireRight(await repository.getRawConfig(testProfileId).run()), source);
    final restored = requireRight(await repository.getById(testProfileId).run())!;
    expect(restored.userOverride, override);
    expect((await storage.dao.getByName(restored.name))?.id, testProfileId);
  });

  test('explicit stale JSON edit fails CAS instead of deleting child-added B', () async {
    final parent = await container.read(details.future);
    final notifier = container.read(details.notifier);
    notifier.setContent(
      jsonEncode({
        'outbounds': [originalNode()],
        'endpoints': [],
      }),
    );
    requireRight(
      await NodeConfigService(
        repository,
      ).addNode(profileId: testProfileId, expectedRawContent: parent.configContent, draft: addedNode(), groupTags: []),
    );
    expect(await notifier.save(), isFalse);
    expect(dialogs.errors.single.type, t.errors.nodes.configChanged);
    expect(container.read(details).requireValue.isDetailsChanged, isTrue);
    final expected = originalConfig();
    (expected['outbounds'] as List).add(addedNode());
    await storage.verifyStored(repository, expected);
  });

  testWidgets('parent details -> add child -> return -> fallback toggle cannot overwrite B', (tester) async {
    await tester.runAsync(() => container.read(details.future));
    final parentSnapshot = container.read(details).requireValue.configContent;
    final child = nodeEditorNotifierProvider(testProfileId, null);
    container.listen(child, (_, _) {});
    await tester.runAsync(() => container.read(child.future));
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Directory')),
        ),
        GoRoute(
          path: '/details',
          builder: (_, _) => const ProfileDetailsPage(id: testProfileId),
        ),
        GoRoute(
          path: '/node',
          builder: (_, _) => const NodeEditorPage(profileId: testProfileId),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(router.push<void>('/details'));
    await tester.pumpAndSettle();
    unawaited(router.push<void>('/node'));
    await tester.pumpAndSettle();
    final editor = container.read(child.notifier);
    editor.switchProtocol('trojan', keepName: 'B');
    editor.setPath(['server'], 'b.example.invalid');
    editor.setPath(['password'], 'new-password');
    editor.setPath(['future_added_option'], {'preserved': true});
    final submitted = NodeJson.deepCopyMap(container.read(child).requireValue.draft);
    await tester.pumpAndSettle();
    final childSaved = Completer<void>();
    final childSubscription = container.listen(child, (_, next) {
      final data = next.asData?.value;
      if (data != null && data.hasSaved && !data.isSaving && !childSaved.isCompleted) childSaved.complete();
    });
    addTearDown(childSubscription.close);
    await tester.tap(find.text(t.common.save));
    await tester.runAsync(() => childSaved.future);
    await tester.pumpAndSettle();
    expect(find.byType(NodeEditorPage), findsNothing);
    expect(find.byType(ProfileDetailsPage), findsOneWidget);
    expect(container.read(details).requireValue.configContent, parentSnapshot);
    final childBytes = await tester.runAsync(() => storage.paths.file(testProfileId).readAsString());

    final toggle = find.ancestor(
      of: find.text(t.pages.profileDetails.form.preserveDomainForFallbackProxy),
      matching: find.byType(SwitchListTile),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final parentSaved = Completer<void>();
    final parentSubscription = container.listen(details, (_, next) {
      final data = next.asData?.value;
      if (data != null && !data.isDetailsChanged && !parentSaved.isCompleted) parentSaved.complete();
    });
    addTearDown(parentSubscription.close);
    await tester.tap(find.text(t.common.save));
    await tester.runAsync(() => parentSaved.future);
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => storage.paths.file(testProfileId).readAsString()), childBytes);
    final expected = originalConfig();
    (expected['outbounds'] as List).add(submitted);
    await tester.runAsync(
      () => storage.verifyStored(
        repository,
        expected,
        userOverride: testOverride.copyWith(preserveDomainForFallbackProxy: true),
      ),
    );
    expect(repository.validationInputs, hasLength(1));
  });
}
