import 'package:flutter/material.dart';

class BioTextBox extends StatefulWidget {
  final String bio;

  const BioTextBox({super.key, required this.bio});

  @override
  State<BioTextBox> createState() => _BioTextBoxState();
}

class _BioTextBoxState extends State<BioTextBox> {
  final ScrollController _bioScrollController = ScrollController();

  _BioTextBoxState();

  @override
  void dispose() {
    // 2. Clean it up when the widget is destroyed
    _bioScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double screenHeight = MediaQuery.sizeOf(context).height; 
    final double screenWidth = MediaQuery.sizeOf(context).width; 

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.16, // Maximum height before scrolling begins
      ),
      child: Scrollbar(
        controller: _bioScrollController,
        thumbVisibility: true,
        thickness: screenWidth * 0.02,
        radius: Radius.circular(screenHeight),
        child: SingleChildScrollView(
          controller: _bioScrollController,
          child: Padding(
            padding: EdgeInsets.only(right: screenWidth * 0.04),
            child: Text(
              widget.bio,
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: Theme.of(context).colorScheme.outline
              )), 
            ),
        ),
      )
    );
  }
}