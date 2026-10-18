import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';

class _CallerController extends TextEditingController {
  _CallerController({super.text});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

class _RevisionHost extends StatefulWidget {
  const _RevisionHost({super.key});

  @override
  State<_RevisionHost> createState() => _RevisionHostState();
}

class _RevisionHostState extends State<_RevisionHost> {
  String _initialValue = 'initial';
  Object? _revision = 0;
  TextEditingController? _externalController;
  final validations = <String?>[];
  final userChanges = <String>[];
  int builds = 0;

  void replace({required String text, required Object? revision, TextEditingController? controller}) {
    setState(() {
      _initialValue = text;
      _revision = revision;
      _externalController = controller;
    });
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: CustomTextFormField(
        initialValue: _initialValue,
        initialValueRevision: _revision,
        controller: _externalController,
        maxLines: 1,
        validator: (value) {
          validations.add(value);
          return value == 'initial' ? 'initial error' : null;
        },
        onChanged: (text) {
          userChanges.add(text);
          setState(() => _initialValue = text.trim());
        },
      ),
    );
  }
}

Future<GlobalKey<_RevisionHostState>> _mountRevisionHost(
  WidgetTester tester, {
  VoidCallback? onFormChanged,
  TextDirection textDirection = TextDirection.ltr,
}) async {
  final key = GlobalKey<_RevisionHostState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Directionality(
          textDirection: textDirection,
          child: Form(
            autovalidateMode: AutovalidateMode.always,
            onChanged: onFormChanged,
            child: _RevisionHost(key: key),
          ),
        ),
      ),
    ),
  );
  // Seed a registered field's error, then let automatic validation observe
  // programmatic changes made by the descendant without rebuilding the Form.
  tester.state<FormState>(find.byType(Form)).validate();
  await tester.pumpAndSettle();
  return key;
}

Future<void> _queueRevisionAfterFrame(
  WidgetTester tester,
  GlobalKey<_RevisionHostState> key, {
  required String text,
  required Object? revision,
}) async {
  // Deliver a late widget update after this frame's callback list was taken.
  // Its controller sync must wait for the next frame, allowing a newer update,
  // edit, controller handoff or unmount to invalidate it before delivery.
  tester.binding.addPostFrameCallback((_) {
    key.currentState!.replace(text: text, revision: revision);
    tester.binding.buildOwner!.buildScope(tester.element(find.byKey(key)));
  });
  await tester.pump();
}

Future<void> _mountField(
  WidgetTester tester, {
  required String initialValue,
  Object? revision,
  TextEditingController? controller,
  ValueChanged<String>? onChanged,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: CustomTextFormField(
        initialValue: initialValue,
        initialValueRevision: revision,
        controller: controller,
        onChanged: onChanged,
        maxLines: 1,
      ),
    ),
  ),
);

EditableText _editable(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText));

void main() {
  testWidgets('descendant revision sync safely notifies and revalidates an ancestor Form after build', (tester) async {
    var formChanges = 0;
    final host = await _mountRevisionHost(tester, onFormChanged: () => formChanges++);
    final controller = _editable(tester).controller;
    final editableState = tester.state<EditableTextState>(find.byType(EditableText));
    expect(find.text('initial error'), findsOneWidget);

    // Only the Form's descendant is dirty, matching the node-field failures.
    host.currentState!.replace(text: 'replacement', revision: 1);
    await tester.pumpAndSettle();
    expect(_editable(tester).controller, same(controller));
    expect(tester.state<EditableTextState>(find.byType(EditableText)), same(editableState));
    expect(controller.text, 'replacement');
    expect(tester.state<FormFieldState<String>>(find.byType(TextFormField)).value, 'replacement');
    expect(host.currentState!.validations.last, 'replacement');
    expect(host.currentState!.userChanges, isEmpty);
    expect(formChanges, greaterThan(0));
    expect(find.text('initial error'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  final directionChanges = <(String, TextDirection, String)>[
    ('updates LTR to RTL', TextDirection.ltr, 'مرحبا'),
    ('restores inherited RTL after clearing Latin text', TextDirection.rtl, ''),
  ];
  for (final (description, inheritedDirection, text) in directionChanges) {
    testWidgets('descendant-only revision $description under a stable Form', (tester) async {
      final host = await _mountRevisionHost(tester, textDirection: inheritedDirection);
      final controller = _editable(tester).controller;
      final editableState = tester.state<EditableTextState>(find.byType(EditableText));
      final formWidget = tester.widget<Form>(find.byType(Form));
      final formState = tester.state<FormState>(find.byType(Form));
      final hostBuilds = host.currentState!.builds;
      expect(controller.text, 'initial');
      expect(_editable(tester).textDirection, TextDirection.ltr);
      expect(Directionality.of(tester.element(find.byType(EditableText))), inheritedDirection);
      var notifications = 0;
      controller.addListener(() => notifications++);

      host.currentState!.replace(text: text, revision: 1);
      await tester.pumpAndSettle();
      expect(_editable(tester).controller, same(controller));
      expect(tester.state<EditableTextState>(find.byType(EditableText)), same(editableState));
      expect(controller.text, text);
      expect(tester.state<FormFieldState<String>>(find.byType(TextFormField)).value, text);
      expect(editableState.renderEditable.textDirection, TextDirection.rtl);
      if (text.isEmpty) {
        expect(tester.widget<TextField>(find.byType(TextField)).textDirection, isNull);
        expect(_editable(tester).textDirection, isNull);
      } else {
        expect(_editable(tester).textDirection, TextDirection.rtl);
      }
      // No pumpWidget or extra parent rebuild may mask the wrapper's stale direction.
      expect(host.currentState!.builds, hostBuilds + 1);
      expect(tester.widget<Form>(find.byType(Form)), same(formWidget));
      expect(tester.state<FormState>(find.byType(Form)), same(formState));
      expect(notifications, 1);
      expect(host.currentState!.userChanges, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  final replacements = <(String, String, Object?, String)>[
    ('a newer revision', 'newest', 2, 'newest'),
    ('a null revision', 'ignored', null, 'initial'),
    ('a same-text revision', 'initial', 2, 'initial'),
    ('an initialValue echo without a new revision', 'echo', 1, 'initial'),
  ];
  for (final (description, text, revision, expected) in replacements) {
    testWidgets('$description invalidates a late queued revision without a stale write', (tester) async {
      final host = await _mountRevisionHost(tester);
      final controller = _editable(tester).controller;
      controller.value = const TextEditingValue(
        text: 'initial',
        selection: TextSelection(baseOffset: 1, extentOffset: 3),
        composing: TextRange(start: 1, end: 4),
      );
      final before = controller.value;
      final writes = <String>[];
      controller.addListener(() => writes.add(controller.text));
      await _queueRevisionAfterFrame(tester, host, text: 'stale', revision: 1);
      expect(controller.value, before);

      host.currentState!.replace(text: text, revision: revision);
      await tester.pumpAndSettle();
      expect(_editable(tester).controller, same(controller));
      expect(controller.text, expected);
      expect(writes, expected == 'initial' ? isEmpty : equals(['newest']));
      if (expected == 'initial') expect(controller.value, before);
      expect(tester.state<FormFieldState<String>>(find.byType(TextFormField)).value, expected);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('user input wins over a late queued revision and preserves focus, selection and IME', (tester) async {
    final host = await _mountRevisionHost(tester);
    await tester.showKeyboard(find.byType(TextFormField));
    final controller = _editable(tester).controller;
    final focusNode = _editable(tester).focusNode;
    final editableState = tester.state<EditableTextState>(find.byType(EditableText));
    await _queueRevisionAfterFrame(tester, host, text: 'stale', revision: 1);
    expect(controller.text, 'initial');
    const input = TextEditingValue(
      text: 'typed 中 ',
      selection: TextSelection(baseOffset: 6, extentOffset: 7),
      composing: TextRange(start: 6, end: 7),
    );
    editableState.updateEditingValue(input);
    await tester.pumpAndSettle();
    expect(_editable(tester).controller, same(controller));
    expect(tester.state<EditableTextState>(find.byType(EditableText)), same(editableState));
    expect(_editable(tester).focusNode, same(focusNode));
    expect(focusNode.hasFocus, isTrue);
    expect(controller.value, input);
    expect(host.currentState!._initialValue, input.text.trim());
    expect(host.currentState!.userChanges, [input.text]);
    expect(tester.state<FormFieldState<String>>(find.byType(TextFormField)).value, input.text);
    expect(tester.takeException(), isNull);
  });

  for (final revert in [false, true]) {
    final change = revert ? 'an edit followed by a revert' : 'a selection and IME change';
    testWidgets('late revision cannot overwrite $change', (tester) async {
      final host = await _mountRevisionHost(tester);
      final controller = _editable(tester).controller;
      final before = controller.value;
      final writes = <String>[];
      controller.addListener(() => writes.add(controller.text));
      await _queueRevisionAfterFrame(tester, host, text: 'stale', revision: 1);
      final edited = revert
          ? const TextEditingValue(text: 'intermediate', selection: TextSelection.collapsed(offset: 12))
          : before.copyWith(
              selection: const TextSelection(baseOffset: 1, extentOffset: 3),
              composing: const TextRange(start: 1, end: 4),
            );
      controller.value = edited;
      if (revert) controller.value = before;
      final expected = controller.value;
      await tester.pumpAndSettle();
      expect(_editable(tester).controller, same(controller));
      expect(controller.value, expected);
      expect(writes, isNot(contains('stale')));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('external controller handoff invalidates queued owned sync without touching or disposing the caller', (
    tester,
  ) async {
    final host = await _mountRevisionHost(tester);
    final writes = <String>[];
    final owned = _editable(tester).controller;
    owned.addListener(() => writes.add(owned.text));
    await _queueRevisionAfterFrame(tester, host, text: 'stale', revision: 1);
    final external = _CallerController()
      ..value = const TextEditingValue(
        text: 'caller',
        selection: TextSelection(baseOffset: 1, extentOffset: 3),
        composing: TextRange(start: 1, end: 4),
      );
    addTearDown(external.dispose);
    final before = external.value;
    host.currentState!.replace(text: 'ignored', revision: 2, controller: external);
    await tester.pumpAndSettle();
    expect(_editable(tester).controller, same(external));
    expect(external.value, before);
    expect(writes, isNot(contains('stale')));
    expect(external.wasDisposed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(external.wasDisposed, isFalse);
    external.text = 'still caller-owned';
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmount invalidates a late queued sync before the owned controller is disposed', (tester) async {
    final host = await _mountRevisionHost(tester);
    final controller = _editable(tester).controller;
    final writes = <String>[];
    controller.addListener(() => writes.add(controller.text));
    await _queueRevisionAfterFrame(tester, host, text: 'stale', revision: 1);
    expect(controller.text, 'initial');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(host.currentState, isNull);
    expect(writes, isNot(contains('stale')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('default initialValue remains initialization-only on rebuild', (tester) async {
    await _mountField(tester, initialValue: 'initial');
    await tester.enterText(find.byType(TextFormField), 'user text');
    final controller = _editable(tester).controller;
    const selection = TextSelection(baseOffset: 1, extentOffset: 5);
    controller.selection = selection;

    await _mountField(tester, initialValue: 'new draft value');
    expect(_editable(tester).controller, same(controller));
    expect(controller.text, 'user text');
    expect(controller.selection, selection);
    expect(_editable(tester).focusNode.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a programmatic revision replaces text in place without an input callback', (tester) async {
    final changes = <String>[];
    await _mountField(tester, initialValue: 'old', revision: 0, onChanged: changes.add);
    await tester.showKeyboard(find.byType(TextFormField));
    final controller = _editable(tester).controller;
    final focusNode = _editable(tester).focusNode;
    controller.value = const TextEditingValue(
      text: 'old',
      selection: TextSelection(baseOffset: 0, extentOffset: 2),
      composing: TextRange(start: 0, end: 3),
    );

    await _mountField(tester, initialValue: 'generated uuid', revision: 1, onChanged: changes.add);
    expect(_editable(tester).controller, same(controller));
    expect(_editable(tester).focusNode, same(focusNode));
    expect(focusNode.hasFocus, isTrue);
    expect(controller.text, 'generated uuid');
    expect(controller.selection, const TextSelection.collapsed(offset: 14));
    expect(controller.value.composing, TextRange.empty);
    expect(changes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged revision preserves typing, selection and IME across normalized echoes', (tester) async {
    final draft = ValueNotifier('');
    addTearDown(draft.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: draft,
            builder: (context, value, child) => CustomTextFormField(
              initialValue: value,
              initialValueRevision: 0,
              onChanged: (text) => draft.value = text.trim(),
              maxLines: 1,
            ),
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextFormField));
    final controller = _editable(tester).controller;
    final focusNode = _editable(tester).focusNode;
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    const values = [
      TextEditingValue(
        text: 'ab ',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
      TextEditingValue(
        text: 'ab中 ',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 2, end: 3),
      ),
      TextEditingValue(
        text: 'ab中文 ',
        selection: TextSelection(baseOffset: 2, extentOffset: 4),
        composing: TextRange(start: 2, end: 4),
      ),
    ];
    for (final value in values) {
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
      expect(draft.value, value.text.trim());
      expect(controller.value, value);
      expect(_editable(tester).controller, same(controller));
      expect(_editable(tester).focusNode, same(focusNode));
      expect(focusNode.hasFocus, isTrue);
      expect(tester.state<EditableTextState>(find.byType(EditableText)), same(state));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a same-text revision leaves selection and composing intact', (tester) async {
    await _mountField(tester, initialValue: 'same', revision: 0);
    final controller = _editable(tester).controller;
    const value = TextEditingValue(
      text: 'same',
      selection: TextSelection(baseOffset: 1, extentOffset: 3),
      composing: TextRange(start: 1, end: 4),
    );
    controller.value = value;
    var notifications = 0;
    controller.addListener(() => notifications++);

    await _mountField(tester, initialValue: 'same', revision: 1);
    expect(_editable(tester).controller, same(controller));
    expect(controller.value, value);
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('external controllers stay authoritative and caller-owned through replacement and unmount', (
    tester,
  ) async {
    final first = _CallerController(text: 'external first');
    final second = _CallerController(text: 'external second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await _mountField(tester, initialValue: 'ignored', revision: 0, controller: first);
    expect(_editable(tester).controller, same(first));
    expect(first.text, 'external first');

    first.value = const TextEditingValue(
      text: 'external edit',
      selection: TextSelection(baseOffset: 1, extentOffset: 4),
      composing: TextRange(start: 0, end: 4),
    );
    final value = first.value;
    await _mountField(tester, initialValue: 'also ignored', revision: 1, controller: first);
    expect(first.value, value);

    await _mountField(tester, initialValue: 'ignored again', revision: 2, controller: second);
    expect(_editable(tester).controller, same(second));
    expect(first.wasDisposed, isFalse);
    first.text = 'still usable after detach';
    await tester.pumpWidget(const SizedBox.shrink());
    expect(first.wasDisposed, isFalse);
    expect(second.wasDisposed, isFalse);
    second.text = 'still usable after unmount';
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching between owned and external controllers preserves caller state and ownership', (tester) async {
    final external = _CallerController(text: 'caller value');
    addTearDown(external.dispose);
    await _mountField(tester, initialValue: 'initial');
    final initialController = _editable(tester).controller;
    await _mountField(tester, initialValue: 'ignored', controller: external);
    expect(_editable(tester).controller, same(external));
    expect(external.text, 'caller value');

    external.value = const TextEditingValue(
      text: 'caller edit',
      selection: TextSelection(baseOffset: 1, extentOffset: 3),
      composing: TextRange(start: 0, end: 3),
    );
    final value = external.value;
    await _mountField(tester, initialValue: 'not a reset');
    final ownedController = _editable(tester).controller;
    expect(ownedController, isNot(same(initialController)));
    expect(ownedController, isNot(same(external)));
    expect(ownedController.value, value);
    expect(external.wasDisposed, isFalse);

    external.text = 'caller after handoff';
    expect(ownedController.value, value);
    await _mountField(tester, initialValue: 'reset', revision: 1);
    expect(_editable(tester).controller, same(ownedController));
    expect(ownedController.text, 'reset');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(external.wasDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });
}
