"""Muscle groups each cable exercise works, mirrored from the app
(mobile/lib/models/cable_exercise.dart: primary / secondary). Keep the two
in step when exercises are added."""

EXERCISES: dict[str, tuple[list[str], list[str]]] = {
    "Lat Pulldown": (["lats"], ["biceps", "rhomboids", "rear_delts", "traps", "forearms"]),
    "Seated Cable Row": (["lats", "rhomboids", "traps"], ["rear_delts", "biceps", "erectors", "forearms"]),
    "Tricep Pushdown": (["triceps"], ["forearms", "abs"]),
    "Cable Bicep Curl": (["biceps"], ["forearms", "front_delts"]),
    "Cable Chest Fly": (["pecs"], ["front_delts", "serratus", "biceps", "abs"]),
    "Face Pull": (["rear_delts", "traps", "rhomboids"], ["rotator_cuff", "biceps"]),
}

# The groups the exercises can train: 100% means every one of them.
TRAINABLE: list[str] = sorted({g for p, s in EXERCISES.values() for g in p + s})


def muscle_coverage(workout_names) -> tuple[int, int]:
    """(groups worked, groups trainable) for a list of sets (one exercise
    name per set). A group counts as worked with one set as prime mover or
    two as assisting muscle, like the app's muscle map."""
    sets: dict[str, float] = {}
    for name in workout_names:
        prime, assist = EXERCISES.get(name, ([], []))
        for g in prime:
            sets[g] = sets.get(g, 0) + 1
        for g in assist:
            sets[g] = sets.get(g, 0) + 0.5
    active = sum(1 for g in TRAINABLE if sets.get(g, 0) >= 1)
    return active, len(TRAINABLE)
