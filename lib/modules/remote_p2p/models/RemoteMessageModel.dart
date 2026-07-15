enum RemoteMessageType { text, emoji, fileHeader, fileChunk, fileAck }

class RemoteMessageModel {
  final String id;
  final String senderId;
  final String senderName;
  final String senderAvatar;
  final String senderAvatarType; // 'image' or 'emoji'
  final RemoteMessageType type;
  final String content; // text message or emoji character or serialized json
  final int timestamp;
  final double progress;

  RemoteMessageModel({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.senderAvatar,
    required this.senderAvatarType,
    required this.type,
    required this.content,
    required this.timestamp,
    this.progress = 0,
  });

  RemoteMessageModel copyWith({double? progress, String? content}) {
    return RemoteMessageModel(
      id: id,
      senderId: senderId,
      senderName: senderName,
      senderAvatar: senderAvatar,
      senderAvatarType: senderAvatarType,
      type: type,
      content: content ?? this.content,
      timestamp: timestamp,
      progress: progress ?? this.progress,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'senderAvatar': senderAvatar,
      'senderAvatarType': senderAvatarType,
      'type': type.index,
      'content': content,
      'timestamp': timestamp,
      'progress': progress,
    };
  }

  factory RemoteMessageModel.fromMap(Map<String, dynamic> map) {
    return RemoteMessageModel(
      id: map['id'] ?? '',
      senderId: map['senderId'] ?? '',
      senderName: map['senderName'] ?? '',
      senderAvatar: map['senderAvatar'] ?? '',
      senderAvatarType: map['senderAvatarType'] ?? 'emoji',
      type: RemoteMessageType.values[map['type'] ?? 0],
      content: map['content'] ?? '',
      timestamp: map['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
    );
  }
}
