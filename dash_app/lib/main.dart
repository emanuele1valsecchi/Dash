import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'theme.dart';
import 'auth_gate.dart';

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
    // Create MaterialTheme with the default Material text theme
    final materialTheme = MaterialTheme(Typography.englishLike2018);

    return MaterialApp(
      title: 'DASH',
      // Automatically apply your Light and Dark themes!
      theme: materialTheme.light(),
      darkTheme: materialTheme.dark(),
      themeMode: ThemeMode.system, // Switches automatically based on phone settings
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}