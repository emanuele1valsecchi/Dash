import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'run_session_detail_page.dart';
import '../services/run_session_repository.dart';
import '../widgets/dash_run_card.dart';
import '../services/unit_preferences.dart';
import '../widgets/units_scope.dart';

class CalendarScreen extends StatefulWidget {
  /// Test seams. Production leaves both null and the state resolves
  /// `.instance` lazily — an eager field initializer would throw
  /// `[core/no-app]` when the widget is *constructed*, before `runApp`.
  @visibleForTesting
  final FirebaseFirestore? firestore;
  @visibleForTesting
  final FirebaseAuth? auth;

  const CalendarScreen({super.key, this.firestore, this.auth});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late final FirebaseFirestore _db =
      widget.firestore ?? FirebaseFirestore.instance;
  late final FirebaseAuth _auth = widget.auth ?? FirebaseAuth.instance;

  /// Fraction of the screen's height each run card takes, matching the route
  /// library's own vertical list — a full-width card in a scrolling column.
  static const double _cardHeightFactor = 0.28;

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  /// Sessions grouped by day, as the typed [RunSession] model rather than raw
  /// Firestore maps — the detail page this screen opens is addressed by
  /// document *id*, which `doc.data()` does not contain. Using the model also
  /// means the path is parsed once, by the same code every other screen uses.
  Map<DateTime, List<RunSession>> _activityDays = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    _loadCalendarSessions();
  }

  Future<void> _loadCalendarSessions() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final querySnapshot = await _db
          .collection('runningSessions')
          .where('userId', isEqualTo: user.uid)
          .get();

      final Map<DateTime, List<RunSession>> loadedDays = {};

      for (var doc in querySnapshot.docs) {
        // Skipped rather than filed under "now": a session whose server
        // timestamp hasn't landed yet has no day to belong to, and the old
        // raw-map version skipped it for the same reason.
        if (doc.data()['createdAt'] == null) continue;


        final session = RunSession.fromDoc(doc);
        final createdAt = session.createdAt;
        final normalizedDay =
            DateTime(createdAt.year, createdAt.month, createdAt.day);

        loadedDays.putIfAbsent(normalizedDay, () => []).add(session);
      }

      if (mounted) {
        setState(() {
          _activityDays = loadedDays;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Errore nel caricamento delle sessioni per il calendario: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<RunSession> _getEventsForDay(DateTime day) {
    final normalizedDay = DateTime(day.year, day.month, day.day);
    return _activityDays[normalizedDay] ?? [];
  }

  /// Opens the shared run detail page — the same screen the Explore map's area
  /// contributions and a profile's Runs row lead to, so a run looks the same
  /// wherever it is reached from.
  ///
  /// Keeps the slide-up transition this list has always used; only the
  /// destination changed (it was `SessionDetailScreen`). The page takes ids
  /// rather than the data this screen already holds, and re-reads the session
  /// itself — one document read in exchange for one page instead of two.
  void _openSession(RunSession session) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            RunSessionDetailPage(
          sessionId: session.id,
          userId: userId,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          const curve = Curves.easeInOutQuart;

          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));

          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedDayActivities = _selectedDay != null ? _getEventsForDay(_selectedDay!) : [];

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "Calendar"
      ),
      body: _isLoading 
        ? Center(
          child: 
            CircularProgressIndicator()
          )
        : NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: ResponsiveSpacing().md),
                    child: TableCalendar(
                      firstDay: DateTime.utc(2020, 1, 1),
                      lastDay: DateTime.utc(2030, 12, 31),
                      focusedDay: _focusedDay,
                      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                      onDaySelected: (selectedDay, focusedDay) {
                        if (!isSameDay(_selectedDay, selectedDay)) {
                          setState(() {
                            _selectedDay = selectedDay;
                            _focusedDay = focusedDay;
                          });
                        }
                      },
                      eventLoader: _getEventsForDay,
                      // Follows the units setting, so the calendar's own
                      // week matches the one weekly stats are grouped by.
                      startingDayOfWeek:
                          Units.of(context).weekStart == WeekStart.sunday
                              ? StartingDayOfWeek.sunday
                              : StartingDayOfWeek.monday,
                      headerStyle: HeaderStyle(
                        formatButtonVisible: false,
                        titleCentered: true,
                        leftChevronIcon: 
                          Icon(
                            Icons.chevron_left, 
                            color: Theme.of(context).colorScheme.secondary
                          ),
                        rightChevronIcon: 
                          Icon(
                            Icons.chevron_right, 
                            color: Theme.of(context).colorScheme.secondary
                          ),
                        titleTextStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
                          color: Theme.of(context).colorScheme.secondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      daysOfWeekStyle: DaysOfWeekStyle(
                        weekdayStyle: Theme.of(context).textTheme.bodyLarge!.copyWith(
                          color: Theme.of(context).colorScheme.secondary,
                          fontWeight: FontWeight.bold,
                        ),
                        weekendStyle: Theme.of(context).textTheme.bodyLarge!.copyWith(
                          color: Theme.of(context).colorScheme.secondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      calendarStyle: CalendarStyle(
                        outsideDaysVisible: true,
                        outsideTextStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        defaultTextStyle: Theme.of(context).textTheme.bodyMedium!,
                        weekendTextStyle: Theme.of(context).textTheme.bodyMedium!,
                        selectedDecoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.tertiary,
                          shape: BoxShape.circle,
                        ),
                        todayDecoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          shape: BoxShape.circle,
                        ),
                        todayTextStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        markerDecoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.tertiary,
                          shape: BoxShape.circle,
                        ),
                        markersMaxCount: 1,
                        markerMargin: EdgeInsets.only(top: ResponsiveSpacing().sm),
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ];
            },
            // Il body è la parte bianca inferiore che sale a coprire lo schermo
            body: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: context.paddingMd,
                    child: Text(
                      'Your activities',
                      style: Theme.of(context).textTheme.titleLarge!.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                        fontWeight: FontWeight.bold
                      ),
                    ),
                  ),
                  Expanded(
                    child: selectedDayActivities.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.directions_run_rounded, 
                                  size: 48, 
                                  color: Theme.of(context).colorScheme.outlineVariant
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'No activities on this day',
                                  style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                                    color: Theme.of(context).colorScheme.outlineVariant
                                  )
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: EdgeInsets.symmetric(horizontal: ResponsiveSpacing().md),
                            itemCount: selectedDayActivities.length,
                            itemBuilder: (context, index) {
                              final session = selectedDayActivities[index];

                              return Padding(
                                padding: EdgeInsets.only(bottom: ResponsiveSpacing().md),
                                // The same card a profile's Runs row uses. Its
                                // own InkWell handles the tap and its map sits
                                // inside an IgnorePointer, so pressing the map
                                // opens the run like pressing anywhere else
                                // does — a FlutterMap swallows pointer events
                                // even with InteractiveFlag.none, which is why
                                // the previous card's outer GestureDetector
                                // never fired there.
                                child: DashRunCard(
                                  heightFactor: _cardHeightFactor,
                                  session: session,
                                  onTap: () => _openSession(session),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
    );
  }
}
