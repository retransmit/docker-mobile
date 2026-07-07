import 'package:flutter/material.dart';

/// A styled text field with a prefix icon, built-in bottom spacing, an optional
/// show/hide eye for secrets, and keyboard next/done focus advance.
class AppTextField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final bool obscure;
  final int maxLines;
  final bool last;
  final VoidCallback? onSubmit;
  final String? hint;

  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.obscure = false,
    this.maxLines = 1,
    this.last = false,
    this.onSubmit,
    this.hint,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _hidden = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final canObscure = widget.obscure && widget.maxLines == 1;
    final multiline = widget.maxLines > 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: widget.controller,
        keyboardType: widget.keyboardType,
        obscureText: canObscure && _hidden,
        maxLines: multiline ? widget.maxLines : 1,
        textInputAction: multiline ? null : (widget.last ? TextInputAction.done : TextInputAction.next),
        onSubmitted: multiline
            ? null
            : (_) {
                if (widget.last) {
                  widget.onSubmit?.call();
                } else {
                  FocusScope.of(context).nextFocus();
                }
              },
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          prefixIcon: Icon(widget.icon),
          suffixIcon: canObscure
              ? IconButton(
                  icon: Icon(_hidden ? Icons.visibility_off : Icons.visibility),
                  tooltip: _hidden ? 'Show' : 'Hide',
                  onPressed: () => setState(() => _hidden = !_hidden),
                )
              : null,
        ),
      ),
    );
  }
}
