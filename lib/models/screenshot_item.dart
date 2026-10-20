class ScreenshotItem {
  const ScreenshotItem({
    this.id,
    required this.filePath,
    required this.fileName,
    required this.createdAt,
    required this.ocrText,
    required this.searchText,
    this.favorite = false,
  });

  final int? id;
  final String filePath;
  final String fileName;
  final DateTime createdAt;
  final String ocrText;
  final String searchText;
  final bool favorite;

  ScreenshotItem copyWith({
    int? id,
    String? filePath,
    String? fileName,
    DateTime? createdAt,
    String? ocrText,
    String? searchText,
    bool? favorite,
  }) {
    return ScreenshotItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      createdAt: createdAt ?? this.createdAt,
      ocrText: ocrText ?? this.ocrText,
      searchText: searchText ?? this.searchText,
      favorite: favorite ?? this.favorite,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'file_path': filePath,
      'file_name': fileName,
      'created_at': createdAt.millisecondsSinceEpoch,
      'ocr_text': ocrText,
      'search_text': searchText,
      'favorite': favorite ? 1 : 0,
    };
  }

  factory ScreenshotItem.fromMap(Map<String, Object?> map) {
    return ScreenshotItem(
      id: map['id'] as int?,
      filePath: map['file_path'] as String,
      fileName: map['file_name'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      ocrText: (map['ocr_text'] as String?) ?? '',
      searchText: (map['search_text'] as String?) ?? '',
      favorite: (map['favorite'] as int? ?? 0) == 1,
    );
  }
}
