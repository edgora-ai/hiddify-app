import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Section header for the node editor form.
class NodeSectionHeader extends StatelessWidget {
  const NodeSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

/// Padded wrapper used by every form row.
class NodeFieldPadding extends StatelessWidget {
  const NodeFieldPadding({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: child);
  }
}

/// Dropdown form field matching the app's text field look.
class NodeDropdownField<T> extends StatelessWidget {
  const NodeDropdownField({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.helperText,
    this.enabled = true,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String? helperText;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final knownValue = items.any((item) => item.value == value);
    return DropdownButtonFormField<T>(
      // A form reset may change the selection without a user dropdown event.
      key: ValueKey(value),
      initialValue: value,
      items: [
        ...items,
        if (!knownValue) DropdownMenuItem<T>(value: value, enabled: false, child: Text(value.toString())),
      ],
      // Unknown values are display-only, not a request to coerce the draft to
      // the first supported item. In particular, never replace http/quic.
      onChanged: enabled && knownValue ? onChanged : null,
      decoration: InputDecoration(isDense: true, label: Text(label), helperText: helperText),
    );
  }
}

/// Password field with a visibility toggle. Suggestions and autocorrect are
/// always off for credential inputs.
class NodePasswordField extends HookConsumerWidget {
  const NodePasswordField({
    super.key,
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.initialValueRevision,
    this.enabled = true,
    this.validator,
    this.helperText,
    this.keyboardType,
  });

  final String label;
  final String initialValue;
  final ValueChanged<String> onChanged;
  final Object? initialValueRevision;
  final bool enabled;
  final String? Function(String?)? validator;
  final String? helperText;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final obscured = useState(true);
    return CustomTextFormField(
      label: label,
      initialValue: initialValue,
      initialValueRevision: initialValueRevision,
      enabled: enabled,
      onChanged: onChanged,
      validator: validator,
      helperText: helperText,
      obscureText: obscured.value,
      keyboardType: keyboardType,
      textCapitalization: TextCapitalization.none,
      enableSuggestions: false,
      maxLines: 1,
      suffixIcon: IconButton(
        icon: Icon(obscured.value ? Icons.visibility_outlined : Icons.visibility_off_outlined),
        onPressed: enabled ? () => obscured.value = !obscured.value : null,
      ),
    );
  }
}

/// Two-column row for short fields (e.g. up/down Mbps).
class NodeFieldRow extends StatelessWidget {
  const NodeFieldRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) const Gap(12), Expanded(child: children[i])],
        ],
      ),
    );
  }
}
