import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

class DashTextFormField extends StatefulWidget {
  final double widthFactor;
  final String label;
  final bool largeText;
  final bool clearOption;

  final TextEditingController? controller;
  final Function(String)? onChanged;
  final String? Function(String?)? validator;

	const DashTextFormField({
    super.key, 
    required this.label,
    this.widthFactor = 0.8, 
    this.largeText = false,
    this.clearOption = false,
    this.controller,
    this.onChanged,
    this.validator
  });

	@override
	State<DashTextFormField> createState() => _DashTextFormFieldState();
}

class _DashTextFormFieldState extends State<DashTextFormField> {
  late final TextEditingController _textEditingController;

  @override
  void initState() {
    super.initState();
    _textEditingController = widget.controller ?? TextEditingController();
    _textEditingController.addListener(_handleTextChange);
  }

  @override
  void dispose(){
    if (widget.controller == null) {
      _textEditingController.dispose();
    }
    super.dispose();
  }

	@override
	Widget build(BuildContext context) {
    final bool showClearButton = widget.clearOption && _textEditingController.text.isNotEmpty;

		return SizedBox(
      width: MediaQuery.sizeOf(context).width * widget.widthFactor,
      child: TextFormField(
        textAlignVertical: TextAlignVertical.top,
        controller: _textEditingController,
        maxLength: widget.largeText ? 100 : 20,
        maxLines: widget.largeText ? 4 : 1,
        validator: widget.validator,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        obscureText: false,
        decoration: InputDecoration(
          alignLabelWithHint: true,
          border: const OutlineInputBorder(),
          labelText: widget.label,
          suffixIcon: (showClearButton & widget.clearOption) ? 
            IconButton(
              icon: const Icon(Symbols.clear_rounded),
              onPressed: _textEditingController.clear,
            )
          : null,
        ),
      ),
    );
	}

  void _handleTextChange(){
    setState(() {
    });
    
    if (widget.onChanged != null) {
      widget.onChanged!(_textEditingController.text);
    }
  }


}