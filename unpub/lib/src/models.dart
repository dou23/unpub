import 'package:json_annotation/json_annotation.dart';

part 'models.g.dart';

// 在 UnpubVersion 类中添加以下静态方法
DateTime _dateTimeFromJson(String dateTime) => DateTime.parse(dateTime);
String _dateTimeToJson(DateTime dateTime) => dateTime.toIso8601String();

@JsonSerializable(includeIfNull: false)
class UnpubVersion {
  final String version;
  final Map<String, dynamic> pubspec;
  final String? pubspecYaml;
  final String? uploader; // TODO: not sure why null. keep it nullable
  final String? readme;
  final String? changelog;

  @JsonKey(fromJson: _dateTimeFromJson, toJson: _dateTimeToJson)
  final DateTime createdAt;

  UnpubVersion(
    this.version,
    this.pubspec,
    this.pubspecYaml,
    this.uploader,
    this.readme,
    this.changelog,
    this.createdAt,
  );

  factory UnpubVersion.fromJson(Map<String, dynamic> map) =>
      _$UnpubVersionFromJson(map);

  Map<String, dynamic> toJson() => _$UnpubVersionToJson(this);
}

@JsonSerializable()
class UnpubPackage {
  final String name;
  final List<UnpubVersion> versions;
  final bool private;
  final List<String>? uploaders;

  @JsonKey(fromJson: _dateTimeFromJson, toJson: _dateTimeToJson)
  final DateTime createdAt;

  @JsonKey(fromJson: _dateTimeFromJson, toJson: _dateTimeToJson)
  final DateTime updatedAt;

  final int? download;

  UnpubPackage(
    this.name,
    this.versions,
    this.private,
    this.uploaders,
    this.createdAt,
    this.updatedAt,
    this.download,
  );

  factory UnpubPackage.fromJson(Map<String, dynamic> map) =>
      _$UnpubPackageFromJson(map);
}

@JsonSerializable()
class UnpubQueryResult {
  int count;
  List<UnpubPackage> packages;

  UnpubQueryResult(this.count, this.packages);

  factory UnpubQueryResult.fromJson(Map<String, dynamic> map) =>
      _$UnpubQueryResultFromJson(map);
}
