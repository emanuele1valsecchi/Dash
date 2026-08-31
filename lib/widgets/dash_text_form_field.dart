import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

class DashTextFormField extends StatefulWidget {
  final double? widthFactor;
  final int? maxLength;
  final BorderRadius? borderRadius;

  final IconData? prefixIconSymbols;

  final String? label;
  final String? hintText;

  final bool largeText;
  final bool clearOption;
  final bool charactersCounter;

  final TextEditingController? controller;
  final Function(String)? onChanged;
  final String? Function(String?)? validator;

	const DashTextFormField({
    super.key,
    this.widthFactor = 0.8,
    this.maxLength,
    this.borderRadius,
    this.prefixIconSymbols,
    this.label,
    this.hintText,
    this.largeText = false,
    this.clearOption = false,
    this.charactersCounter = true,
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
    } else {
      _textEditingController.removeListener(_handleTextChange);
    }
    super.dispose();
  }

	@override
	Widget build(BuildContext context) {
    Widget textFormField = _buildTextFormField(context);

    if ( widget.widthFactor != null && widget.widthFactor! < 1.0 ){
      return SizedBox(
        width: MediaQuery.sizeOf(context).width * widget.widthFactor!,
        child: textFormField,
      );
    }

    return textFormField;
	}

  Widget _buildTextFormField(BuildContext context){
    final bool showClearButton = widget.clearOption && _textEditingController.text.isNotEmpty;

    final int? effectiveMaxLength = widget.charactersCounter 
        ? (widget.maxLength ?? (widget.largeText ? 100 : 20))
        : widget.maxLength;

    final BorderRadius effectiveRadius = widget.borderRadius ?? context.radiusMd;

    return TextFormField(
      textAlignVertical: widget.largeText 
        ? TextAlignVertical.top 
        : TextAlignVertical.center,
      controller: _textEditingController,
      maxLength: effectiveMaxLength,
      maxLines: widget.largeText ? 4 : 1,
      validator: widget.validator,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      obscureText: false,
      buildCounter: widget.charactersCounter 
        ? null 
        : (context, {required currentLength, required isFocused, maxLength}) => null,
      decoration: InputDecoration(
        alignLabelWithHint: true,
        labelText: widget.label,
        hintText: widget.hintText,
        hintStyle: TextStyle(color: Theme.of(context).hintColor),
        prefixIcon: (widget.prefixIconSymbols != null ) ? Icon(widget.prefixIconSymbols) : null,
        border: OutlineInputBorder(
          borderRadius: effectiveRadius,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: effectiveRadius,
          borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: effectiveRadius,
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 1.5,
          ),
        ),
        suffixIcon: showClearButton ? 
          IconButton(
            icon: const Icon(Symbols.clear_rounded),
            onPressed: _textEditingController.clear,
          )
        : null,
      ),
    );
  }

  void _handleTextChange(){
    setState(() {});
    
    if (widget.onChanged != null) {
      widget.onChanged!(_textEditingController.text);
    }
  }


}