import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class MealPlanScreen extends StatelessWidget {
  const MealPlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBg,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Meal Plan',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: AppTheme.cardBgLight,
                          child: const Icon(Icons.person_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Here\'s your personalized meal plan.',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Filter dropdowns
                    Row(
                      children: [
                        Expanded(
                          child: _DropdownChip(
                            label: 'Goal',
                            value: 'Gain Muscle',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _DropdownChip(
                            label: 'Intensity',
                            value: 'Moderate',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Breakfast card
                    const Text(
                      'Breakfast',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: AppTheme.cardBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.cardBgLight),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 140,
                            color: AppTheme.cardBgLight,
                            child: Center(
                              child: Icon(
                                Icons.restaurant_rounded,
                                size: 64,
                                color: AppTheme.neonGreen.withValues(alpha:0.5),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Scrambled Eggs',
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _MealItem(text: 'Turkey Bacon (92 cal)', checked: true),
                                _MealItem(text: 'Whole Grain Toast 45g (38 cal)', checked: true),
                                _MealItem(text: 'Banana 55g (19 cal)', checked: false),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Grocery list
                    const Text(
                      'Grocery List',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _GroceryItem(name: 'Eggs'),
                    _GroceryItem(name: 'Turkey Bacon'),
                    _GroceryItem(name: 'Whole Grain Bread'),
                    _GroceryItem(name: 'Banana'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DropdownChip extends StatelessWidget {
  final String label;
  final String value;

  const _DropdownChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBgLight),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.textMuted),
        ],
      ),
    );
  }
}

class _MealItem extends StatelessWidget {
  final String text;
  final bool checked;

  const _MealItem({required this.text, required this.checked});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            checked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: checked ? AppTheme.neonGreen : AppTheme.textMuted,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: checked ? AppTheme.textPrimary : AppTheme.textSecondary,
              fontSize: 14,
              decoration: checked ? TextDecoration.lineThrough : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroceryItem extends StatelessWidget {
  final String name;

  const _GroceryItem({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBgLight),
      ),
      child: Row(
        children: [
          Icon(Icons.shopping_basket_rounded, color: AppTheme.neonGreen.withValues(alpha:0.8)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
            ),
          ),
          const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: AppTheme.textMuted),
        ],
      ),
    );
  }
}
