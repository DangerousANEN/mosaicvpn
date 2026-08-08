/// Route profile — a named bundle of routing rules.
/// Matches Go: proto.RouteProfile
class RouteProfile {
  final String id;
  final String name;
  final String description;
  final List<String> ruleIDs;
  final DateTime createdAt;
  final DateTime updatedAt;

  RouteProfile({
    this.id = '',
    this.name = '',
    this.description = '',
    this.ruleIDs = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        updatedAt = updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory RouteProfile.fromJson(Map<String, dynamic> j) => RouteProfile(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        description: j['description'] ?? '',
        ruleIDs: (j['rule_ids'] as List?)?.cast<String>() ?? [],
        createdAt:
            j['created_at'] != null ? DateTime.tryParse(j['created_at']) : null,
        updatedAt:
            j['updated_at'] != null ? DateTime.tryParse(j['updated_at']) : null,
      );
}
