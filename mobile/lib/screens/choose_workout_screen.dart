import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'anatomy_studio_screen.dart';
import 'cable_track_screen.dart';

class ChooseWorkoutScreen extends StatefulWidget {
  const ChooseWorkoutScreen({super.key});

  @override
  State<ChooseWorkoutScreen> createState() => _ChooseWorkoutScreenState();
}

class _ChooseWorkoutScreenState extends State<ChooseWorkoutScreen> {
  // Gympath is cable-machine only — every workout runs on the live
  // gravity-axis tracking graph (CableTrackScreen).
  final List<Map<String, dynamic>> _workouts = [
    {'name': 'Lat Pulldown', 'duration': '12 min', 'icon': Icons.fitness_center_rounded},
    {'name': 'Seated Cable Row', 'duration': '12 min', 'icon': Icons.rowing_rounded},
    {'name': 'Tricep Pushdown', 'duration': '10 min', 'icon': Icons.sports_gymnastics_rounded},
    {'name': 'Cable Bicep Curl', 'duration': '10 min', 'icon': Icons.fitness_center_rounded},
    {'name': 'Cable Chest Fly', 'duration': '12 min', 'icon': Icons.sports_gymnastics_rounded},
    {'name': 'Face Pull', 'duration': '8 min', 'icon': Icons.self_improvement_rounded},
  ];

  String _searchQuery = '';
  int? _selectedIndex;

  @override
  Widget build(BuildContext context) {
    final filtered = _workouts
        .where((w) =>
            w['name'].toString().toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: const Text('Choose Workout'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.all(Responsive.w(context, 20)),
              child: TextField(
                onChanged: (v) => setState(() => _searchQuery = v),
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search category',
                  hintStyle: TextStyle(color: AppTheme.textMuted),
                  prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMuted),
                  filled: true,
                  fillColor: AppTheme.cardBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.symmetric(horizontal: Responsive.w(context, 20)),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final workout = filtered[index];
                  final isSelected = _selectedIndex == _workouts.indexOf(workout);
                  return Padding(
                    padding: EdgeInsets.only(bottom: Responsive.h(context, 12)),
                    child: InkWell(
                      onTap: () => setState(() {
                        _selectedIndex = _selectedIndex == _workouts.indexOf(workout)
                            ? null
                            : _workouts.indexOf(workout);
                      }),
                      borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
                      child: Container(
                        padding: EdgeInsets.all(Responsive.w(context, 16)),
                        decoration: BoxDecoration(
                          color: AppTheme.cardBg,
                          borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.neonGreen
                                : AppTheme.cardBgLight,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: Responsive.r(context, 44),
                              height: Responsive.r(context, 44),
                              decoration: BoxDecoration(
                                color: AppTheme.neonGreen.withValues(alpha:0.2),
                                borderRadius: BorderRadius.circular(Responsive.r(context, 10)),
                              ),
                              child: Icon(
                                workout['icon'],
                                color: AppTheme.neonGreen,
                              ),
                            ),
                            SizedBox(width: Responsive.w(context, 16)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    workout['name'],
                                    style: const TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    workout['duration'],
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '3D muscle guide',
                              icon: const Icon(Icons.accessibility_new_rounded),
                              color: AppTheme.neonGreen,
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => AnatomyStudioScreen(
                                    initialExercise: workout['name'],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Daily goal card
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Responsive.w(context, 20)),
              child: Container(
                padding: EdgeInsets.all(Responsive.w(context, 16)),
                margin: EdgeInsets.only(bottom: Responsive.h(context, 16)),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(Responsive.r(context, 12)),
                  border: Border.all(color: AppTheme.cardBgLight),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Icon(Icons.dark_mode_rounded, color: AppTheme.textMuted),
                    Icon(Icons.lock_rounded, color: AppTheme.neonGreen),
                    const Text('57', style: TextStyle(color: AppTheme.neonGreen, fontSize: 18)),
                    Icon(Icons.light_mode_rounded, color: AppTheme.textMuted),
                  ],
                ),
              ),
            ),
            // Start Workout button
            Padding(
              padding: EdgeInsets.fromLTRB(
                Responsive.w(context, 20),
                0,
                Responsive.w(context, 20),
                Responsive.h(context, 24),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _selectedIndex != null
                      ? () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => CableTrackScreen(
                                workoutName: _workouts[_selectedIndex!]['name'],
                              ),
                            ),
                          );
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.neonGreen,
                    disabledBackgroundColor: AppTheme.cardBgLight,
                    foregroundColor: Colors.black,
                    padding: EdgeInsets.symmetric(vertical: Responsive.h(context, 16)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Responsive.r(context, 14)),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Start Workout', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
