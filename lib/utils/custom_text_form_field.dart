import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/utils/text_utils.dart';

class CustomTextFormField extends StatefulWidget {
  const CustomTextFormField({
    super.key,
    this.onChanged,
    this.validator,
    this.controller,
    this.inputFormatters,
    this.initialValue = '',
    this.initialValueRevision,
    this.suffixIcon,
    this.label,
    this.hint,
    this.helperText,
    this.maxLines,
    this.isDense = false,
    this.autoValidate = false,
    this.autoCorrect = false,
    this.obscureText = false,
    this.keyboardType,
    this.textCapitalization,
    this.enableSuggestions,
    this.enabled = true,
  });

  final ValueChanged<String>? onChanged;
  final String? Function(String? value)? validator;
  final TextEditingController? controller;
  final List<TextInputFormatter>? inputFormatters;
  final String initialValue;

  /// Opt-in token for replacing the internally controlled text with
  /// [initialValue]. Change it only for programmatic edits, not input echoes.
  /// A null token retains the usual one-time initialValue semantics.
  /// An external [controller] is always authoritative and is never disposed.
  final Object? initialValueRevision;
  final Widget? suffixIcon;
  final String? label;
  final String? hint;
  final String? helperText;
  final int? maxLines;
  final bool isDense;
  final bool autoValidate;
  final bool autoCorrect;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextCapitalization? textCapitalization;
  final bool? enableSuggestions;
  final bool enabled;

  @override
  State<CustomTextFormField> createState() => _CustomTextFormFieldState();
}

class _CustomTextFormFieldState extends State<CustomTextFormField> {
  TextEditingController? _ownedController;

  TextEditingController get _controller => widget.controller ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = TextEditingController(text: widget.initialValue);
    }
  }

  @override
  void didUpdateWidget(covariant CustomTextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      if (widget.controller == null) {
        _ownedController = TextEditingController.fromValue(oldWidget.controller!.value);
      } else {
        _ownedController?.dispose();
        _ownedController = null;
      }
    }
    if (widget.controller == null &&
        widget.initialValueRevision != null &&
        widget.initialValueRevision != oldWidget.initialValueRevision &&
        _controller.text != widget.initialValue) {
      _controller.value = TextEditingValue(
        text: widget.initialValue,
        selection: TextSelection.collapsed(offset: widget.initialValue.length),
      );
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textController = _controller;
    final effectiveConstraints = widget.isDense ? const BoxConstraints(maxHeight: 56) : null;
    final effectiveBorder = widget.isDense
        ? OutlineInputBorder(borderRadius: BorderRadius.circular(36), borderSide: BorderSide.none)
        : null;

    return TextFormField(
      controller: textController,
      textCapitalization: widget.textCapitalization ?? TextCapitalization.sentences,
      maxLines: widget.maxLines,
      onChanged: widget.onChanged,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      enableSuggestions: widget.enableSuggestions ?? !widget.obscureText,
      enabled: widget.enabled,
      textDirection: textController.textDirection,
      decoration: InputDecoration(
        isDense: true,
        label: widget.label != null ? Text(widget.label!) : null,
        hintText: widget.hint,
        hintStyle: Theme.of(context).textTheme.bodySmall,
        helperText: widget.helperText,
        constraints: effectiveConstraints,
        suffixIcon: widget.suffixIcon,
        border: effectiveBorder,
        enabledBorder: effectiveBorder,
        errorBorder: effectiveBorder,
        focusedBorder: effectiveBorder,
        focusedErrorBorder: effectiveBorder,
      ),
      validator: widget.validator,
      textInputAction: TextInputAction.next,
      inputFormatters: widget.inputFormatters,
      autovalidateMode: widget.autoValidate ? AutovalidateMode.always : AutovalidateMode.disabled,
      autocorrect: widget.autoCorrect,
    );
  }
}
