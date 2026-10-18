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
    container = editorContainer(repository, dialogs: dialogs);
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
    container.listen(provider, (_, _) {});
    await tester.runAsync(() => container.read(provider.future));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    unawaited(router.push<void>('/node'));
    await tester.pumpAndSettle();
  }

  Future<void> saved() {
    final done = Completer<void>();
    final subscription = container.listen(provider, (_, next) {
      final data = next.asData?.value;
      if (data != null && data.hasSaved && !data.isSaving && !done.isCompleted) done.complete();
    });
    return done.future.whenComplete(subscription.close);
  }

  Finder password() => find.descendant(of: find.byType(NodePasswordField), matching: find.byType(TextField));

  testWidgets('save detaches IME, blocks new focus and back navigation until D0 is stored', (tester) async {
    await mount(tester);
    await tester.ensureVisible(password());
    await tester.enterText(password(), 'submitted-password');
    expect(tester.testTextInput.hasAnyClients, isTrue);
    final submitted = NodeJson.deepCopyMap(container.read(provider).requireValue.draft);
    final entered = Completer<void>();
    final release = Completer<void>();
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final finished = saved();
    await tester.tap(
      find.ancestor(of: find.text(t.common.save), matching: find.byWidgetPredicate((widget) => widget is TextButton)),
    );
    await tester.runAsync(() => entered.future);
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

    release.complete();
    await tester.runAsync(() => finished);
    await tester.pumpAndSettle();
    expect(find.byType(NodeEditorPage), findsNothing);
    final expected = originalConfig();
    (expected['outbounds'] as List)[0] = submitted;
    await tester.runAsync(() => storage.verifyStored(repository, expected));
  });

  testWidgets('unexpected D1 during delayed save stays dirty and the page does not pop', (tester) async {
    container.dispose();
    container = editorContainer(repository, overrides: [provider.overrideWith(InjectingNodeEditorNotifier.new)]);
    await container.read(profileRepositoryProvider.future);
    await container.read(translationsProvider.future);
    await mount(tester);
    final notifier = container.read(provider.notifier) as InjectingNodeEditorNotifier;
    notifier.setPath(['server'], 'submitted.example.invalid');
    final submitted = NodeJson.deepCopyMap(container.read(provider).requireValue.draft);
    final entered = Completer<void>();
    final release = Completer<void>();
    repository.beforeValidation = () async {
      entered.complete();
      await release.future;
    };
    final finished = saved();
    await tester.pump();
    await tester.tap(
      find.ancestor(of: find.text(t.common.save), matching: find.byWidgetPredicate((widget) => widget is TextButton)),
    );
    await tester.runAsync(() => entered.future);
    notifier.injectDraft(NodeJson.deepCopyMap(submitted)..['password'] = 'newer-not-saved');
    release.complete();
    await tester.runAsync(() => finished);
    await tester.pumpAndSettle();
    expect(find.byType(NodeEditorPage), findsOneWidget);
    final data = container.read(provider).requireValue;
    expect(data.originalDraft, submitted);
    expect(data.draft['password'], 'newer-not-saved');
    expect(data.isDirty, isTrue);
    final expected = originalConfig();
    (expected['outbounds'] as List)[0] = submitted;
    await tester.runAsync(() => storage.verifyStored(repository, expected));
  });

  testWidgets('conflict offers explicit confirmed reload and replaces complete credential draft', (tester) async {
    await mount(tester);
    final notifier = container.read(provider.notifier);
    notifier.setPath(['server'], 'unsaved.example.invalid');
    final profile = requireRight((await tester.runAsync(() => repository.getById(testProfileId).run()))!)!;
    final other = originalConfig();
    ((other['outbounds'] as List).first as Map)['password'] = 'new-owner-password';
    await tester.runAsync(() => repository.offlineUpdate(profile, const JsonEncoder().convert(other)).run());
    await tester.runAsync(() => notifier.save(t));
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
    await tester.tap(find.text(t.pages.nodeEditor.actions.reload));
    await tester.pump();
    await tester.runAsync(() => container.read(provider.future));
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
