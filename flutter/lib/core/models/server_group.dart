/// A user-defined group of servers (e.g. "Work", "Gaming").
/// The reserved group with id == `ungroupedId` is the implicit "Ungrouped"
/// bucket — every server with no explicit groupId belongs to it.
class ServerGroup {
  final String id;
  final String name;
  final int sortOrder; // ordering inside the servers list
  final bool isDefault; // true for "Ungrouped"

  const ServerGroup({
    required this.id,
    required this.name,
    this.sortOrder = 0,
    this.isDefault = false,
  });

  static const String ungroupedId = '__ungrouped__';

  factory ServerGroup.ungrouped() => const ServerGroup(
        id: ungroupedId,
        name: 'Ungrouped',
        sortOrder: -1,
        isDefault: true,
      );

  factory ServerGroup.fromJson(Map<String, dynamic> j) => ServerGroup(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        sortOrder: j['sort_order'] ?? 0,
        isDefault: j['is_default'] ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sort_order': sortOrder,
        'is_default': isDefault,
      };

  ServerGroup copyWith({
    String? id,
    String? name,
    int? sortOrder,
    bool? isDefault,
  }) =>
      ServerGroup(
        id: id ?? this.id,
        name: name ?? this.name,
        sortOrder: sortOrder ?? this.sortOrder,
        isDefault: isDefault ?? this.isDefault,
      );
}
