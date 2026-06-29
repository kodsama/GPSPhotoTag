/// COCO class-id mapping for the Tier-2 people/pet detector.
///
/// The bundled SSD-MobileNet model emits COCO category ids. Only two buckets
/// matter to the `people` keep-rule: a *person* and a handful of common
/// *animals* (the same pets/animals the Tier-1 keyword list cares about). This
/// file is pure data + a pure predicate so the mapping is unit-testable without
/// any model or native runtime.
library;

/// The COCO category id for a person (the model's `detection_classes` uses the
/// 1-based COCO ids: person == 1).
const int kCocoPersonId = 1;

/// COCO category ids treated as "an animal" for the people/pet rule: bird, cat,
/// dog, horse, sheep, cow, elephant, bear, zebra, giraffe. These mirror the
/// pet/animal words the Tier-1 metadata scorer already recognises.
const Set<int> kCocoAnimalIds = {16, 17, 18, 19, 20, 21, 22, 23, 24, 25};

/// Whether COCO category [id] counts as a person or an animal for the rule.
bool isPersonOrAnimal(int id) =>
    id == kCocoPersonId || kCocoAnimalIds.contains(id);
