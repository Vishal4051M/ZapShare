enum P2PConnectionMode { local, anywhere }

enum P2PConnectionState { disconnected, connecting, connected, reconnecting }

class P2PSessionModel {
  final String roomId;
  final P2PConnectionMode mode;
  final P2PConnectionState connectionState;
  final String peerId;
  final String peerName;
  final String peerAvatar;
  final String peerAvatarType;
  final String? localIp;

  P2PSessionModel({
    required this.roomId,
    required this.mode,
    required this.connectionState,
    required this.peerId,
    required this.peerName,
    required this.peerAvatar,
    required this.peerAvatarType,
    this.localIp,
  });

  P2PSessionModel copyWith({
    String? roomId,
    P2PConnectionMode? mode,
    P2PConnectionState? connectionState,
    String? peerId,
    String? peerName,
    String? peerAvatar,
    String? peerAvatarType,
    String? localIp,
  }) {
    return P2PSessionModel(
      roomId: roomId ?? this.roomId,
      mode: mode ?? this.mode,
      connectionState: connectionState ?? this.connectionState,
      peerId: peerId ?? this.peerId,
      peerName: peerName ?? this.peerName,
      peerAvatar: peerAvatar ?? this.peerAvatar,
      peerAvatarType: peerAvatarType ?? this.peerAvatarType,
      localIp: localIp ?? this.localIp,
    );
  }
}
