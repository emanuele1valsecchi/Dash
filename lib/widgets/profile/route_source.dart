import 'package:dash/services/route_repository.dart';

enum RouteSource { 
  owned, 
  favorite,
  created
}

class RouteEntry {
  final SavedRoute route;
  final RouteSource source;

  const RouteEntry(
    this.route, 
    this.source
  );
}