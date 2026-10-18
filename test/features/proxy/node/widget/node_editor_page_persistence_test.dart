import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/proxy/node/data/node_json_adapter.dart';
import 'package:hiddify/features/proxy/node/model/node_editor_state.dart';
import 'package:hiddify/features/proxy/node/notifier/node_editor_notifier.dart';
import 'package:hiddify/features/proxy/node/widget/fields/node_form_widgets.dart';
import 'package:hiddify/features/proxy/node/widget/node_editor_page.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../profile/data/profile_commit_test_support.dart';
import '../notifier/node_editor_test_support.dart';

void main() {
  late ProfileCommitHarness storage;
  late TestProfileRepository repository;
  late ProviderContainer container;
  late GoRouter router;
  final provider = nodeEditorNotifierProvider(testProfileId, 'A');
  final t = TranslationsEn();
  late TestDialogs dialogs;

  setUp(() async {
    storage = await ProfileCommitHarness.create();
    repository = storage.repository();
    await storage.seed();
    dialogs = TestDialogs();
    container = editorContainer(
      repository,
      dialogs: dialogs,
      overrides: [provider.overrideWith(ObservedNodeEditorNotifier.new)],
    );
    await container.read(profileRepositoryProvider.future);
    await container.read(translationsProvider.future);
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Directory')),
        ),
        GoRoute(
          path: '/node',
          builder: (_, _) => const NodeEditorPage(profileId: testProfileId, rawTag: 'A'),
        ),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    container.dispose();
    await storage.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    final loaded = await tester.runAsync(() async {
      await container.read(profileRepositoryProvider.future);
      await container.read(translationsProvider.future);
      // Starting the provider must happen here too, not just awaiting a future
      // whose File/SQLite work was already scheduled in FakeAsync.
      container.listen(provider, (_, _) {});
      return await container.read(provider.future);
    });
    expect(loaded, isNotNull);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    unawaited(router.push<void>('/node'));
    await tester.pumpAndSettle();
  }

  Finder password() => find.descendant(of: find.byType(NodePasswordField), matching: find.byType(TextField));

  testWidgets('save detaches IME, blocks new focus and back navigation until D0 is stored', (tester) async {
    await mount(tester);
    await tester.ensureVisible(password());
    await tester.enterText(password(), 'submitted-password');
    expect(container.read(provider).requireValue.draft['password'], 'submitted-password');
    expect(container.read(provider).requireValue.isDirty, isTrue);
    // Render the dirty state before tapping the previously disabled Save action.
    await tester.pump();
    final saveButton = find.ancestor(
      of: find.text(t.common.save),
      matching: find.byWidgetPredicate((widget) => widget is TextButton),
    );
    expect(tester.widget<TextButton>(saveButton).onPressed, isNotNull);
    expect(saveButton.hitTestable(), findsOneWidget);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    final submitted = NodeJson.deepCopyMap(container.read(provider).requireValue.draft);
    // Gate futures must originate in the real zone, just like the IO they gate.
    final gates = (await tester.runAsync(() async => (entered: Completer<void>(), release: Completer<void>())))!;
    final entered = gates.entered;
    final release = gates.release;
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final editor = container.read(provider.notifier) as ObservedNodeEditorNotifier;
    try {
      final busy = await tester.runAsync(() async {
        // The real tap must create the save/DB future in this real async zone.
        await tester.tap(saveButton);
        final operation = editor.lastSave;
        if (operation == null) throw TestFailure('Save tap did not start a node save');
        await waitForCheckpoint(
          entered.future,
          operation,
          description: 'UI D0 save validation',
          describeResult: (result) => '${result.kind}: ${result.failure}',
        );
        return container.read(provider).requireValue;
      });
      expect(busy?.isSaving, isTrue);
      await tester.pump();
      expect(container.read(provider).requireValue.isSaving, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(isA<EditableText>()));

      await tester.tap(password(), warnIfMissed: false);
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      container.read(provider.notifier).setPath(['password'], 'attempted-during-save');
      await tester.pageBack();
      await tester.pump();
      expect(find.byType(NodeEditorPage), findsOneWidget);
      expect(dialogs.confirmations, 0);
      expect(container.read(provider).requireValue.draft, submitted);

      final result = await tester.runAsync(() async {
        release.complete();
        return await editor.lastSave!;
      });
      expect(result?.kind, NodeSaveKind.saved);
      await tester.pumpAndSettle();
      expect(find.byType(NodeEditorPage), findsNothing);
      final expected = originalConfig();
      (expected['outbounds'] as List)[0] = submitted;
      await tester.runAsync(() => storage.verifyStored(repository, expected));
    } finally {
      await tester.runAsync(() => releaseAndSettle(release, [if (editor.lastSave != null) editor.lastSave!]));
    }
  });

  testWidgets('unexpected D1 during delayed save stays dirty and the page does not pop', (tester) async {
    container.dispose();
    container = editorContainer(repository, overrides: [provider.overrideWith(InjectingNodeEditorNotifier.new)]);
    await mount(tester);
    final notifier = container.read(provider.notifier) as InjectingNodeEditorNotifier;
    notifier.setPath(['server'], 'submitted.example.invalid');
    final submitted = NodeJson.deepCopyMap(container.read(provider).requireValue.draft);
    // Gate futures must originate in the real zone, just like the IO they gate.
    final gates = (await tester.runAsync(() async => (entered: Completer<void>(), release: Completer<void>())))!;
    final entered = gates.entered;
    final release = gates.release;
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    try {
      await tester.pump();
      final busy = await tester.runAsync(() async {
        await tester.tap(
          find.ancestor(
            of: find.text(t.common.save),
            matching: find.byWidgetPredicate((widget) => widget is TextButton),
          ),
        );
        final operation = notifier.lastSave;
        if (operation == null) throw TestFailure('Save tap did not start the D0 operation');
        await waitForCheckpoint(
          entered.future,
          operation,
          description: 'UI validation before D1 injection',
          describeResult: (result) => '${result.kind}: ${result.failure}',
        );
        return container.read(provider).requireValue;
      });
      expect(busy?.isSaving, isTrue);
      notifier.injectDraft(NodeJson.deepCopyMap(submitted)..['password'] = 'newer-not-saved');
      final result = await tester.runAsync(() async {
        release.complete();
        return await notifier.lastSave!;
      });
      expect(result?.kind, NodeSaveKind.saved);
      await tester.pumpAndSettle();
      expect(find.byType(NodeEditorPage), findsOneWidget);
      final data = container.read(provider).requireValue;
      expect(data.originalDraft, submitted);
      expect(data.draft['password'], 'newer-not-saved');
      expect(data.isDirty, isTrue);
      final expected = originalConfig();
      (expected['outbounds'] as List)[0] = submitted;
      await tester.runAsync(() => storage.verifyStored(repository, expected));
    } finally {
      await tester.runAsync(() => releaseAndSettle(release, [if (notifier.lastSave != null) notifier.lastSave!]));
    }
  });

  testWidgets('conflict offers explicit confirmed reload and replaces complete credential draft', (tester) async {
    await mount(tester);
    final notifier = container.read(provider.notifier) as ObservedNodeEditorNotifier;
    notifier.setPath(['server'], 'unsaved.example.invalid');
    final profile = requireRight((await tester.runAsync(() => repository.getById(testProfileId).run()))!)!;
    final other = originalConfig();
    ((other['outbounds'] as List).first as Map)['password'] = 'new-owner-password';
    requireRight(
      (await tester.runAsync(() => repository.offlineUpdate(profile, const JsonEncoder().convert(other)).run()))!,
    );
    final conflict = await tester.runAsync(() => notifier.save(t));
    expect(conflict?.kind, NodeSaveKind.failed);
    await tester.pumpAndSettle();
    final button = tester.widget<TextButton>(
      find.ancestor(of: find.text(t.common.save), matching: find.byWidgetPredicate((widget) => widget is TextButton)),
    );
    expect(button.onPressed, isNull);
    expect(container.read(provider).requireValue.needsReload, isTrue);
    final conflictSnapshot = container.read(provider).requireValue.rawContentSnapshot;
    dialogs.confirmDiscard = false;
    await tester.tap(find.text(t.pages.nodeEditor.actions.reload));
    await tester.pumpAndSettle();
    expect(container.read(provider).requireValue.needsReload, isTrue);
    expect(container.read(provider).requireValue.rawContentSnapshot, conflictSnapshot);
    expect(container.read(provider).requireValue.draft['server'], 'unsaved.example.invalid');
    dialogs.confirmDiscard = true;
    final loaded = await tester.runAsync(() async {
      // Confirmation and invalidation must start the reload in this same zone.
      await tester.tap(find.text(t.pages.nodeEditor.actions.reload));
      final operation = notifier.lastReload;
      if (operation == null) throw TestFailure('Confirmed Reload tap did not start a reload');
      return await operation;
    });
    expect(loaded, isNotNull);
    await tester.pumpAndSettle();
    expect(dialogs.confirmations, 2);
    final reloaded = container.read(provider).requireValue;
    expect(reloaded.draft, (other['outbounds'] as List).first);
    expect(reloaded.isDirty, isFalse);
    final field = tester.widget<TextField>(password());
    expect(field.controller!.text, 'new-owner-password');
    await tester.runAsync(() => storage.verifyStored(repository, other));
  });
}
