import 'package:flutter/material.dart';

class ErrorPage extends StatelessWidget{
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: MediaQuery.widthOf(context) * 0.02),
          child: Column(
            children: [
              Text(
                "Unexpected behavior, the app will relaunch from start",
                style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                  color: Theme.of(context).colorScheme.error
                ),
              ),
              SizedBox(height: MediaQuery.heightOf(context) * 0.04,),
              ElevatedButton(
                onPressed: (){}, 
                child: Text("Return to login")
              )
            ],
          ),
        ),
      )
    );
  }
}