/// Metadata-driven "are there people / pets in this photo?" scoring.
///
/// The duplicate-finder's `people` keep-rule favours the candidate that most
/// looks like it contains people (or pets). Tier 1 reads that signal straight
/// from metadata already present in the file — face regions written by phones
/// and photo managers (Apple Photos, Picasa/Google, Lightroom), IPTC person
/// names, and subject/keyword hints — via the SAME batched exiftool `-json`
/// read the finder already does for dimensions (no extra process spawns).
///
/// Everything here is pure (it scores a decoded exiftool JSON entry / a list of
/// raw tag values), so the whole signal model is unit-testable without I/O.
library;

/// The exiftool tags the batched dimension read also requests so a single
/// `-json` invocation yields the people/pet signal alongside width/height.
///
/// These cover the common face-region and person-name conventions:
/// - `RegionName` / `RegionType` / `RegionInfo`: XMP-mwg-rs face regions
///   (Apple Photos, Lightroom, digiKam) — a "Face" region means a person.
/// - `PersonInImage`: IPTC Extension person names (also Apple).
/// - `Subject` / `Keywords`: free-text tags that may name people or pets.
/// - `FacesDetected`: a numeric face count some cameras/apps write.
const List<String> kPeopleSignalTags = [
  'RegionName',
  'RegionType',
  'RegionInfo',
  'PersonInImage',
  'Subject',
  'Keywords',
  'FacesDetected',
];

/// People score for a *clear winner*: the rule decides only when the top
/// candidate's score beats the runner-up by at least this margin (scores are
/// 0..1). A near-tie falls through to the next rule. Tunable.
const double kPeopleClearWinnerMargin = 0.34;

/// Score when an explicit face region / person name / face count is present —
/// the strongest "there are people here" evidence.
const double _facePresentScore = 1.0;

/// Score when only a subject/keyword *hint* (a person- or pet-word) is found —
/// weaker than an explicit face region but still a positive signal.
const double _keywordHintScore = 0.5;

/// Lower-cased subject/keyword terms that hint at people or pets. Matched as
/// whole words against split subject/keyword values (not substrings, so
/// "cathedral" never counts as "cat").
const Set<String> _peoplePetWords = {
  // People.
  'person', 'people', 'portrait', 'face', 'selfie', 'family', 'friends',
  'baby', 'child', 'children', 'kid', 'kids', 'man', 'woman', 'men', 'women',
  'boy', 'girl', 'group',
  // Pets / animals.
  'pet', 'pets', 'animal', 'animals', 'dog', 'cat', 'puppy', 'kitten',
  'bird', 'horse', 'rabbit', 'fish',
};

/// Scores the people/pet likelihood (0..1) of one decoded exiftool `-json`
/// entry (a `Map` keyed by tag name). Higher means stronger evidence.
///
/// An explicit face region, person name, or positive face count scores
/// [_facePresentScore]; a person/pet *word* in Subject/Keywords scores
/// [_keywordHintScore]; nothing recognised scores 0. Tolerant of the several
/// shapes exiftool emits per tag (string, list, nested `RegionInfo` map, the
/// numeric or string `FacesDetected`).
double peopleScoreFromTags(Map<Object?, Object?> entry) {
  if (_hasFaceRegion(entry) ||
      _hasPersonName(entry) ||
      _hasDetectedFaces(entry)) {
    return _facePresentScore;
  }
  if (_hasPersonOrPetKeyword(entry)) return _keywordHintScore;
  return 0;
}

/// Whether [entry] carries an XMP-mwg-rs *face* region (a named region, an
/// explicit `RegionType` of "Face", or a `RegionInfo` map describing one).
bool _hasFaceRegion(Map<Object?, Object?> entry) {
  if (_anyNonEmpty(entry['RegionName'])) return true;
  if (_containsToken(entry['RegionType'], 'face')) return true;
  final info = entry['RegionInfo'];
  if (info is Map) {
    final regions = info['RegionList'];
    if (regions is List && regions.isNotEmpty) return true;
    // Some writers flatten the names/types directly onto RegionInfo.
    if (_anyNonEmpty(info['Name']) || _containsToken(info['Type'], 'face')) {
      return true;
    }
  }
  return false;
}

/// Whether [entry] names at least one person (IPTC/Apple `PersonInImage`).
bool _hasPersonName(Map<Object?, Object?> entry) =>
    _anyNonEmpty(entry['PersonInImage']);

/// Whether [entry] reports a positive `FacesDetected` count (numeric or a
/// numeric string). Zero / non-numeric is not a signal.
bool _hasDetectedFaces(Map<Object?, Object?> entry) {
  final v = entry['FacesDetected'];
  if (v is num) return v > 0;
  if (v is String) {
    final n = num.tryParse(v.trim());
    return n != null && n > 0;
  }
  return false;
}

/// Whether Subject/Keywords contain a person- or pet-word (whole-word match).
bool _hasPersonOrPetKeyword(Map<Object?, Object?> entry) {
  for (final key in const ['Subject', 'Keywords']) {
    for (final word in _tokens(entry[key])) {
      if (_peoplePetWords.contains(word)) return true;
    }
  }
  return false;
}

/// Whether [value] holds any non-empty string (a bare string, or a list with
/// one). Used for "is this tag present and meaningful?" checks.
bool _anyNonEmpty(Object? value) {
  if (value is String) return value.trim().isNotEmpty;
  if (value is List) return value.any(_anyNonEmpty);
  return false;
}

/// Whether [value] (string or list of strings) contains [token] as a substring,
/// case-insensitively. Used for `RegionType == "Face"` style checks.
bool _containsToken(Object? value, String token) {
  if (value is String) return value.toLowerCase().contains(token);
  if (value is List) return value.any((v) => _containsToken(v, token));
  return false;
}

/// The lower-cased word tokens of [value] (a string, or list of strings),
/// split on whitespace and common separators (`, ; / |`). Empty for non-text.
Iterable<String> _tokens(Object? value) sync* {
  if (value is String) {
    for (final t in value.toLowerCase().split(RegExp(r'[\s,;/|]+'))) {
      if (t.isNotEmpty) yield t;
    }
  } else if (value is List) {
    for (final v in value) {
      yield* _tokens(v);
    }
  }
}
