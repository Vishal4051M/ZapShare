import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'TransferResumeStore.dart';

class WebRTCP2PService {
  RTCPeerConnection? peerConnection;
  RTCDataChannel? dataChannel;
  MediaStream? localStream;
  MediaStream? remoteStream;

  bool get isDataChannelOpen =>
      dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  Function(String text)? onMessageReceived;
  Function(String emoji)? onEmojiReceived;
  Function(String name, int size)? onFileIncoming;
  Function(double progress)? onFileProgress;
  Function(Uint8List data)? onFileCompleted;
  Function(String filePath)? onFileReceivedPath;
  Function(MediaStream stream)? onRemoteStreamAdded;
  Function(RTCPeerConnectionState state)? onConnectionStateChanged;
  Function(Map<String, dynamic> candidate)? onIceCandidateGenerated;
  Function(Map<String, dynamic> sdp)? _onSdpGenerated;
  Future<String> Function(String fileName)? getSavePath;

  // File sending variables
  Completer<void>? _bufferLowCompleter;
  Completer<int>? _resumeOfferCompleter;
  Completer<void>? _fileCompleteCompleter;

  // Receiver-side persistent state fields
  IOSink? _fileSink;
  File? _tempFile;
  String _incomingFileName = '';
  int _incomingFileSize = 0;
  int _receivedBytes = 0;
  String? _incomingTransferId;
  int _activeConnectionGeneration = 0;
  int? _fileSinkGeneration;
  bool _isCheckpointing = false;
  // Keep the native WebRTC queue deliberately small.  Large queues look fast
  // locally but are a common cause of mobile memory pressure and SCTP channel
  // resets during long transfers.
  // A 2 MiB window keeps a 200 Mbps path full at ordinary WAN latency while
  // staying well below platform SCTP queue limits.
  static const int _highWaterMark = 2 * 1024 * 1024;
  static const int _lowWaterMark = 512 * 1024;
  static const int _dataChunkSize = 16 * 1024;
  static const Duration _progressInterval = Duration(milliseconds: 400);
  DateTime _lastIncomingProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastOutgoingProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];
  bool _hasRemoteDescription = false;

  final Map<String, dynamic> _stunConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
      {'urls': 'stun:stun.services.mozilla.com'},
      {'urls': 'stun:stun.stunprotocol.org:3478'},
    ],
    'iceCandidatePoolSize': 10,
  };

  final Map<String, dynamic> _connectionConstraints = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ],
  };

  Future<void> initializeConnection(
    bool isHost,
    Function(Map<String, dynamic> sdp) onSdpGenerated,
    int connectionGeneration,
  ) async {
    try {
      _activeConnectionGeneration = connectionGeneration;
      // Clean up previous peer connection and data channel to avoid resource leaks and conflicts
      try {
        if (dataChannel != null) {
          dataChannel!.onMessage = null;
          try {
            dataChannel!.onDataChannelState = null;
          } catch (_) {}
          try {
            dataChannel!.onBufferedAmountLow = null;
          } catch (_) {}
          await dataChannel!.close();
        }
      } catch (_) {}
      dataChannel = null;

      try {
        await peerConnection?.close();
      } catch (_) {}
      peerConnection = null;

      _pendingRemoteCandidates.clear();
      _hasRemoteDescription = false;
      _onSdpGenerated = onSdpGenerated;
      peerConnection = await createPeerConnection(
        _stunConfiguration,
        _connectionConstraints,
      );

      peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          onIceCandidateGenerated?.call({
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        }
      };

      peerConnection!.onConnectionState = (RTCPeerConnectionState state) async {
        if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          if (_fileSink != null) {
            try {
              await _fileSink!.flush();
              print("💾 [WebRTC] Disconnected: Flushed _fileSink.");
            } catch (e) {
              print("⚠️ Error flushing _fileSink on disconnect: $e");
            }
          }
          if (_incomingTransferId != null && _tempFile != null) {
            await TransferResumeStore.persist(
              transferId: _incomingTransferId!,
              name: _incomingFileName,
              size: _incomingFileSize,
              receivedBytes: _receivedBytes,
              partialFilePath: _tempFile!.path,
            );
            print(
              "💾 [WebRTC] Saved partial transfer checkpoint at $_receivedBytes bytes.",
            );
          }
          if (_bufferLowCompleter != null &&
              !_bufferLowCompleter!.isCompleted) {
            _bufferLowCompleter!.completeError(
              Exception("Connection state changed to $state"),
            );
          }
        }
        onConnectionStateChanged?.call(state);
      };

      peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          remoteStream = event.streams[0];
          onRemoteStreamAdded?.call(remoteStream!);
        }
      };

      if (isHost) {
        // Host creates the data channel
        RTCDataChannelInit init = RTCDataChannelInit()..ordered = true;
        dataChannel = await peerConnection!.createDataChannel(
          'zapshare-data',
          init,
        );
        _setupDataChannelListeners(_activeConnectionGeneration);
      } else {
        // Peer listens for the data channel
        final currentGen = _activeConnectionGeneration;
        peerConnection!.onDataChannel = (RTCDataChannel channel) {
          if (currentGen != _activeConnectionGeneration) {
            print("🗑️ Ignoring onDataChannel for stale generation $currentGen");
            return;
          }
          dataChannel = channel;
          _setupDataChannelListeners(currentGen);
        };
      }
    } catch (e) {
      print("Error initializing WebRTC: $e");
      rethrow;
    }
  }

  void _setupDataChannelListeners(int generation) {
    if (dataChannel == null) return;

    try {
      dataChannel!.bufferedAmountLowThreshold = _lowWaterMark;
      dataChannel!.onBufferedAmountLow = (int currentAmount) {
        if (generation != _activeConnectionGeneration) return;
        if (_bufferLowCompleter != null && !_bufferLowCompleter!.isCompleted) {
          _bufferLowCompleter!.complete();
        }
      };
    } catch (e) {
      print("Error setting bufferedAmount settings on dataChannel: $e");
    }

    dataChannel!.onMessage = (RTCDataChannelMessage message) async {
      if (generation != _activeConnectionGeneration) {
        return;
      }
      try {
        if (message.isBinary) {
          if (_fileSinkGeneration != generation) {
            return;
          }
          final bytes = message.binary;
          _fileSink?.add(bytes);

          final previousMB = _receivedBytes ~/ (2 * 1024 * 1024);
          _receivedBytes += bytes.length;
          final currentMB = _receivedBytes ~/ (2 * 1024 * 1024);

          if (_incomingFileSize > 0 && _shouldReportIncomingProgress()) {
            onFileProgress?.call(_receivedBytes / _incomingFileSize);
          }

          if (currentMB > previousMB &&
              _incomingTransferId != null &&
              _tempFile != null &&
              !_isCheckpointing) {
            _isCheckpointing = true;
            final transferId = _incomingTransferId!;
            final name = _incomingFileName;
            final size = _incomingFileSize;
            final received = _receivedBytes;
            final path = _tempFile!.path;
            final sink = _fileSink;

            unawaited(() async {
              try {
                await sink?.flush();
                await TransferResumeStore.persist(
                  transferId: transferId,
                  name: name,
                  size: size,
                  receivedBytes: received,
                  partialFilePath: path,
                );
              } catch (e) {
                print("⚠️ Error during async checkpoint: $e");
              } finally {
                _isCheckpointing = false;
              }
            }());
          }
          return;
        }

        final text = message.text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        final type = json['type'] as String?;

        switch (type) {
          case 'text':
            onMessageReceived?.call(json['content'] ?? '');
            break;
          case 'emoji':
            onEmojiReceived?.call(json['content'] ?? '');
            break;
          case 'file_header':
            _incomingFileName = json['name'] ?? 'file';
            _incomingFileSize = json['size'] ?? 0;
            _incomingTransferId = json['transferId'] as String?;
            _receivedBytes = 0;
            _fileSinkGeneration = generation;

            try {
              if (_fileSink != null) {
                try {
                  await _fileSink!.close();
                } catch (_) {}
                _fileSink = null;
              }

              String? targetPath;
              if (getSavePath != null) {
                try {
                  targetPath = await getSavePath!(_incomingFileName);
                } catch (e) {
                  print("Error getting target save path: $e");
                }
              }

              if (targetPath == null) {
                final tempDir = Directory.systemTemp;
                targetPath = '${tempDir.path}/$_incomingFileName';
              }

              _tempFile = File(targetPath);

              Map<String, dynamic>? record;
              if (_incomingTransferId != null) {
                record = await TransferResumeStore.get(_incomingTransferId!);
              }
              if (record == null) {
                record = await TransferResumeStore.findByMatch(
                  _incomingFileName,
                  _incomingFileSize,
                  transferId: _incomingTransferId,
                );
              }

              bool isResuming = false;
              if (record != null) {
                final recordedPath = record['partialFilePath'] as String?;
                final recordedReceived = record['receivedBytes'] as int? ?? 0;

                if (recordedPath != null &&
                    recordedReceived < _incomingFileSize) {
                  final partialFile = File(recordedPath);
                  if (await partialFile.exists()) {
                    final actualLength = await partialFile.length();
                    if (actualLength == recordedReceived) {
                      _tempFile = partialFile;
                      _receivedBytes = recordedReceived;
                      isResuming = true;
                      print("🔄 Resuming P2P transfer at offset $_receivedBytes");
                    } else {
                      print(
                        "⚠️ Offset mismatch: actualLength ($actualLength) != recordedReceived ($recordedReceived)",
                      );
                    }
                  }
                }
              }

              if (!isResuming) {
                try {
                  final parentDir = _tempFile!.parent;
                  if (!await parentDir.exists()) {
                    await parentDir.create(recursive: true);
                  }
                  if (_tempFile!.existsSync()) {
                    _tempFile!.deleteSync();
                  }
                } catch (e) {
                  print("Error creating fresh file: $e");
                }
                _fileSink = _tempFile!.openWrite();
              } else {
                _fileSink = _tempFile!.openWrite(mode: FileMode.append);
              }
            } catch (e) {
              print("⚠️ Error closing or opening file sink (recoverable): $e");
            }

            onFileIncoming?.call(_incomingFileName, _incomingFileSize);
            if (_incomingFileSize > 0) {
              onFileProgress?.call(_receivedBytes / _incomingFileSize);
            }

            sendControlMessage({
              'type': 'resume_offer',
              'transferId': _incomingTransferId ?? '',
              'receivedBytes': _receivedBytes,
            });

            if (_incomingTransferId != null) {
              await TransferResumeStore.persist(
                transferId: _incomingTransferId!,
                name: _incomingFileName,
                size: _incomingFileSize,
                receivedBytes: _receivedBytes,
                partialFilePath: _tempFile!.path,
              );
            }
            break;
          case 'file_end':
            try {
              await _fileSink?.flush();
            } catch (e) {
              print("Error flushing sink in file_end: $e");
            }
            if (_receivedBytes != _incomingFileSize) {
              // Keep the partial file and its exact durable offset.  The
              // sender will time out waiting for completion and reconnect,
              // then resume from this checkpoint rather than accepting a
              // truncated file as complete.
              if (_incomingTransferId != null && _tempFile != null) {
                await TransferResumeStore.persist(
                  transferId: _incomingTransferId!,
                  name: _incomingFileName,
                  size: _incomingFileSize,
                  receivedBytes: _receivedBytes,
                  partialFilePath: _tempFile!.path,
                );
              }
              print(
                '⚠️ Incomplete file_end: $_receivedBytes / $_incomingFileSize bytes',
              );
              break;
            }
            if (_fileSink != null) {
              try {
                await _fileSink!.close();
              } catch (_) {}
              _fileSink = null;
            }
            if (_incomingTransferId != null) {
              await TransferResumeStore.clear(_incomingTransferId!);
            }
            if (_tempFile != null) {
              onFileReceivedPath?.call(_tempFile!.path);
            }
            sendControlMessage({'type': 'file_complete'});
            break;
          case 'resume_offer':
            final rBytes = json['receivedBytes'] as int? ?? 0;
            if (_resumeOfferCompleter != null &&
                !_resumeOfferCompleter!.isCompleted) {
              _resumeOfferCompleter!.complete(rBytes);
            }
            break;
          case 'file_complete':
            if (_fileCompleteCompleter != null &&
                !_fileCompleteCompleter!.isCompleted) {
              _fileCompleteCompleter!.complete();
            }
            break;
        }
      } catch (e) {
        print("DataChannel message parsing error: $e");
      }
    };
  }

  // SDP Handshaking

  Future<Map<String, dynamic>> createOffer({bool iceRestart = false}) async {
    try {
      final constraints = {
        'mandatory': {},
        'optional': [],
        if (iceRestart) 'iceRestart': true,
      };
      final description = await peerConnection!.createOffer(constraints);
      await peerConnection!.setLocalDescription(description);
      return {'type': description.type, 'sdp': description.sdp};
    } catch (e) {
      print("Error creating WebRTC offer: $e");
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createAnswer(Map<String, dynamic> offer) async {
    try {
      await peerConnection!.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );
      _hasRemoteDescription = true;
      await _applyPendingRemoteCandidates();
      final description = await peerConnection!.createAnswer();
      await peerConnection!.setLocalDescription(description);
      return {'type': description.type, 'sdp': description.sdp};
    } catch (e) {
      print("Error creating WebRTC answer: $e");
      rethrow;
    }
  }

  Future<void> setAnswer(Map<String, dynamic> answer) async {
    try {
      await peerConnection!.setRemoteDescription(
        RTCSessionDescription(answer['sdp'], answer['type']),
      );
      _hasRemoteDescription = true;
      await _applyPendingRemoteCandidates();
    } catch (e) {
      print("Error setting WebRTC answer: $e");
      rethrow;
    }
  }

  Future<void> addCandidate(Map<String, dynamic> candidateData) async {
    if (!_hasRemoteDescription) {
      _pendingRemoteCandidates.add(Map<String, dynamic>.from(candidateData));
      return;
    }
    await _addCandidate(candidateData);
  }

  Future<void> _applyPendingRemoteCandidates() async {
    while (_pendingRemoteCandidates.isNotEmpty) {
      await _addCandidate(_pendingRemoteCandidates.removeAt(0));
    }
  }

  Future<void> _addCandidate(Map<String, dynamic> candidateData) async {
    try {
      final candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );
      await peerConnection!.addCandidate(candidate);
    } catch (e) {
      print("Error applying ICE candidate: $e");
    }
  }

  // Media Capture Sharing (Audio, Video, Screen)

  Future<void> startAudioSharing() async {
    try {
      final mediaConstraints = {'audio': true, 'video': false};
      localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      for (var track in localStream!.getAudioTracks()) {
        await peerConnection!.addTrack(track, localStream!);
      }
      await _renegotiate();
    } catch (e) {
      print("Audio sharing capture error: $e");
      rethrow;
    }
  }

  Future<void> startScreenSharing() async {
    try {
      final mediaConstraints = {'audio': true, 'video': true};
      localStream = await navigator.mediaDevices.getDisplayMedia(
        mediaConstraints,
      );
      for (var track in localStream!.getTracks()) {
        await peerConnection!.addTrack(track, localStream!);
      }
      await _renegotiate();
    } catch (e) {
      print("Screen sharing capture error: $e");
      rethrow;
    }
  }

  Future<void> stopSharing() async {
    try {
      if (localStream != null) {
        for (var track in localStream!.getTracks()) {
          await track.stop();
        }
        await localStream!.dispose();
        localStream = null;
      }
    } catch (e) {
      print("Error stopping capture stream: $e");
    }
  }

  Future<void> _renegotiate() async {
    if (peerConnection == null || _onSdpGenerated == null) return;
    final offer = await createOffer();
    await _onSdpGenerated!(offer);
  }

  // Communication API

  void sendControlMessage(Map<String, dynamic> messageMap) {
    try {
      if (dataChannel != null &&
          dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
        dataChannel!.send(RTCDataChannelMessage(jsonEncode(messageMap)));
      }
    } catch (e) {
      print("Error sending control message: $e");
    }
  }

  Future<void> waitForDataChannelOpen({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    int waitAttempts = 0;
    final maxAttempts = timeout.inMilliseconds ~/ 100;
    while ((dataChannel == null ||
            dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) &&
        waitAttempts < maxAttempts) {
      await Future.delayed(const Duration(milliseconds: 100));
      waitAttempts++;
    }
    if (dataChannel == null ||
        dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception(
        "Data channel not open (timed out waiting for open state)",
      );
    }
  }

  Future<void> _ensureDataChannelOpen() => waitForDataChannelOpen();

  Future<void> _waitIfBufferFull() async {
    if (dataChannel == null) return;
    int buffered = 0;
    try {
      buffered = dataChannel!.bufferedAmount ?? 0;
    } catch (_) {}
    if (buffered > _highWaterMark) {
      _bufferLowCompleter = Completer<void>();

      // Hybrid fallback polling: check every 50ms in case native onBufferedAmountLow doesn't fire
      Timer? fallbackTimer;
      fallbackTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
        int currentBuffer = 0;
        try {
          currentBuffer = dataChannel!.bufferedAmount ?? 0;
        } catch (_) {}
        if (currentBuffer <= _lowWaterMark) {
          timer.cancel();
          if (_bufferLowCompleter != null &&
              !_bufferLowCompleter!.isCompleted) {
            _bufferLowCompleter!.complete();
          }
        }
      });

      try {
        await _bufferLowCompleter!.future.timeout(const Duration(seconds: 45));
      } on TimeoutException {
        throw Exception("P2P transfer stalled — buffer never drained");
      } finally {
        fallbackTimer.cancel();
      }
    }
  }

  bool _shouldReportIncomingProgress() {
    final now = DateTime.now();
    if (_receivedBytes < _incomingFileSize &&
        now.difference(_lastIncomingProgressAt) < _progressInterval) {
      return false;
    }
    _lastIncomingProgressAt = now;
    return true;
  }

  void _reportOutgoingProgress(
    int sentBytes,
    int totalBytes,
    Function(double progress) onProgress,
  ) {
    final now = DateTime.now();
    if (sentBytes < totalBytes &&
        now.difference(_lastOutgoingProgressAt) < _progressInterval) {
      return;
    }
    _lastOutgoingProgressAt = now;
    onProgress(sentBytes / totalBytes);
  }

  Future<void> _finishTransfer() async {
    _fileCompleteCompleter = Completer<void>();
    sendControlMessage({'type': 'file_end'});
    try {
      await _fileCompleteCompleter!.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw Exception('Receiver did not confirm durable file completion');
    } finally {
      _fileCompleteCompleter = null;
    }
  }

  Future<void> sendFile(
    Uint8List fileBytes,
    String name,
    Function(double progress) onProgress,
  ) async {
    try {
      await _ensureDataChannelOpen();

      final sampleBytes =
          fileBytes.length > 65536 ? fileBytes.sublist(0, 65536) : fileBytes;
      final hash = Object.hashAll(sampleBytes);
      final transferId =
          "${name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}_${fileBytes.length}_$hash";
      _resumeOfferCompleter = Completer<int>();

      // Send header
      sendControlMessage({
        'type': 'file_header',
        'name': name,
        'size': fileBytes.length,
        'transferId': transferId,
      });

      int startOffset = 0;
      try {
        startOffset = await _resumeOfferCompleter!.future.timeout(
          const Duration(seconds: 15),
        );
      } catch (_) {
        print("Timeout or error waiting for resume_offer, starting from 0");
      } finally {
        _resumeOfferCompleter = null;
      }

      const int chunkSize = _dataChunkSize;
      int offset = startOffset;
      _lastOutgoingProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
      _reportOutgoingProgress(offset, fileBytes.length, onProgress);

      while (offset < fileBytes.length) {
        if (dataChannel == null ||
            dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
          throw Exception("Data channel closed during transfer");
        }

        int end = offset + chunkSize;
        if (end > fileBytes.length) end = fileBytes.length;

        final chunk = fileBytes.sublist(offset, end);

        dataChannel!.send(RTCDataChannelMessage.fromBinary(chunk));
        offset = end;
        _reportOutgoingProgress(offset, fileBytes.length, onProgress);

        // Native flow control using bufferedAmount
        await _waitIfBufferFull();
      }

      await _finishTransfer();
    } catch (e) {
      print("Error sending file: $e");
      rethrow;
    }
  }

  Future<void> sendFileStream(
    String filePath,
    String name,
    Function(double progress) onProgress,
  ) async {
    try {
      await _ensureDataChannelOpen();

      final file = File(filePath);
      final totalSize = await file.length();
      final lastModified = await file.lastModified();
      final transferId =
          "${name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}_${totalSize}_${lastModified.millisecondsSinceEpoch}";

      _resumeOfferCompleter = Completer<int>();

      // Send header
      sendControlMessage({
        'type': 'file_header',
        'name': name,
        'size': totalSize,
        'transferId': transferId,
      });

      int startOffset = 0;
      try {
        startOffset = await _resumeOfferCompleter!.future.timeout(
          const Duration(seconds: 15),
        );
      } catch (_) {
        print("Timeout or error waiting for resume_offer, starting from 0");
      } finally {
        _resumeOfferCompleter = null;
      }

      // Stream file using openRead to get automatic double-buffering (read-ahead)
      final stream = file.openRead(startOffset);
      int sentBytes = startOffset;
      _lastOutgoingProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
      _reportOutgoingProgress(sentBytes, totalSize, onProgress);

      await for (final chunk in stream) {
        if (dataChannel == null ||
            dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
          throw Exception("Data channel closed during transfer");
        }

        // Slice chunk if it exceeds 16KB
        int chunkOffset = 0;
        final uint8ListChunk = Uint8List.fromList(chunk);

        while (chunkOffset < uint8ListChunk.length) {
          if (dataChannel == null ||
              dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
            throw Exception("Data channel closed during transfer");
          }

          final end =
              (chunkOffset + _dataChunkSize > uint8ListChunk.length)
                  ? uint8ListChunk.length
                  : chunkOffset + _dataChunkSize;

          final slice = uint8ListChunk.sublist(chunkOffset, end);

          dataChannel!.send(RTCDataChannelMessage.fromBinary(slice));
          sentBytes += slice.length;
          chunkOffset += slice.length;
          _reportOutgoingProgress(sentBytes, totalSize, onProgress);

          // Flow control
          await _waitIfBufferFull();
        }
      }

      await _finishTransfer();
    } catch (e) {
      print("Error sending file stream: $e");
      rethrow;
    }
  }

  Future<void> sendFileStreamFromUri(
    String uri,
    String name,
    int size,
    Function(double progress) onProgress,
  ) async {
    try {
      await _ensureDataChannelOpen();

      final sanitizedUri = uri.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
      final transferId =
          "${name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}_${size}_$sanitizedUri";
      _resumeOfferCompleter = Completer<int>();

      // Send header
      sendControlMessage({
        'type': 'file_header',
        'name': name,
        'size': size,
        'transferId': transferId,
      });

      int startOffset = 0;
      try {
        startOffset = await _resumeOfferCompleter!.future.timeout(
          const Duration(seconds: 15),
        );
      } catch (_) {
        print("Timeout or error waiting for resume_offer, starting from 0");
      } finally {
        _resumeOfferCompleter = null;
      }

      const channel = MethodChannel('zapshare.saf');
      final result = await channel.invokeMethod('openReadStream', {'uri': uri});
      if (result == null) {
        throw Exception('Failed to open stream for URI: $uri');
      }
      final streamId = result.toString();

      if (startOffset > 0) {
        try {
          final seekRes = await channel.invokeMethod<bool>('seekStream', {
            'uri': uri,
            'streamId': streamId,
            'position': startOffset,
          });
          if (seekRes != true) {
            throw Exception(
              'Failed to seek native SAF stream to position $startOffset',
            );
          }
        } catch (seekErr) {
          print('⚠️ Native seekStream failed: $seekErr');
          throw Exception('SAF Seek failed: $seekErr');
        }
      }

      // Larger SAF reads reduce expensive platform-channel calls without
      // growing the WebRTC queue, which is controlled separately above.
      const int nativeReadSize = 512 * 1024;
      const int chunkSize = _dataChunkSize;
      int sentBytes = startOffset;
      _lastOutgoingProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
      _reportOutgoingProgress(sentBytes, size, onProgress);

      try {
        while (sentBytes < size) {
          if (dataChannel == null ||
              dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
            throw Exception("Data channel closed during transfer");
          }

          final bytesToRead =
              (size - sentBytes) > nativeReadSize
                  ? nativeReadSize
                  : (size - sentBytes);
          final block = await channel.invokeMethod<Uint8List>('readChunk', {
            'uri': uri,
            'streamId': streamId,
            'size': bytesToRead,
          });

          if (block == null || block.isEmpty) {
            break;
          }

          int blockOffset = 0;
          while (blockOffset < block.length) {
            if (dataChannel == null ||
                dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
              throw Exception("Data channel closed during transfer");
            }

            final end =
                (blockOffset + chunkSize > block.length)
                    ? block.length
                    : blockOffset + chunkSize;

            final chunk = block.sublist(blockOffset, end);

            dataChannel!.send(RTCDataChannelMessage.fromBinary(chunk));
            sentBytes += chunk.length;
            blockOffset += chunk.length;
            _reportOutgoingProgress(sentBytes, size, onProgress);

            // Flow control
            await _waitIfBufferFull();
          }
        }
      } finally {
        try {
          await channel.invokeMethod('closeStream', {
            'uri': uri,
            'streamId': streamId,
          });
        } catch (e) {
          print("Error closing stream: $e");
        }
      }

      await _finishTransfer();
    } catch (e) {
      print("Error sending file stream from URI: $e");
      rethrow;
    }
  }

  Future<void> dispose() async {
    try {
      if (_bufferLowCompleter != null && !_bufferLowCompleter!.isCompleted) {
        _bufferLowCompleter!.completeError(Exception("Disposed"));
      }
      if (_fileSink != null) {
        try {
          await _fileSink!.close();
        } catch (_) {}
        _fileSink = null;
      }
      _tempFile = null;
      _incomingTransferId = null;
      await stopSharing();
      await dataChannel?.close();
      await peerConnection?.close();
      peerConnection = null;
      dataChannel = null;
      _pendingRemoteCandidates.clear();
      _hasRemoteDescription = false;
      _onSdpGenerated = null;
    } catch (e) {
      print("Error disposing WebRTC service: $e");
    }
  }
}
