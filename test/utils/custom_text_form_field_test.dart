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

    await _mountField(tester, initialValue: 'same', revision: 1);
    expect(_editable(tester).controller, same(controller));
    expect(controller.value, value);
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
