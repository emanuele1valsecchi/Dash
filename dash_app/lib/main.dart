import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  // 1. Ensure Flutter is initialized before calling native code
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Load the environment variables from the .env file
  await dotenv.load(fileName: ".env");

  // 3. Initialize the Supabase connection
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  debugPrint('DASH - Supabase Initialized!');

  // 4. Run the app
  runApp(const DashApp());
}

class DashApp extends StatelessWidget {
  const DashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DASH Running App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(
          child: Text(
            'DASH - Connection Successful!',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}