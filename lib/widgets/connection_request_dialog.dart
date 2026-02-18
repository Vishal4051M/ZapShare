import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../services/device_discovery_service.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

// Modern Color Constants
const Color kZapPrimary = Color(0xFFFFD600); 
const Color kZapSurface = Color(0xFF1C1C1E); 
const Color kZapBackground = Color(0xFF000000); 

class ConnectionRequestDialog extends StatefulWidget {
  final ConnectionRequest request;
  final Function(List<String> selectedFiles, String? savePath) onAccept;
  final VoidCallback onDecline;

  const ConnectionRequestDialog({
    super.key,
    required this.request,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  State<ConnectionRequestDialog> createState() => _ConnectionRequestDialogState();
}

class _ConnectionRequestDialogState extends State<ConnectionRequestDialog> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  
  // Selection State
  late Set<String> _selectedFiles;
  String? _savePath;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
       vsync: this,
       duration: const Duration(milliseconds: 400),
    );
    _scaleAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    
    // Select all by default
    _selectedFiles = Set.from(widget.request.fileNames);
    
    _controller.forward();
    _setDefaultSavePath();
  }

  Future<void> _setDefaultSavePath() async {
     try {
       final docDir = await getApplicationDocumentsDirectory();
       if (mounted) {
         setState(() {
           _savePath = '${docDir.path}/ZapShare_Received';
         });
       }
     } catch (_) {}
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickSavePath() async {
     try {
       String? result = await FilePicker.platform.getDirectoryPath();
       if (result != null) {
          setState(() => _savePath = result);
       }
     } catch (e) {
       print("Error picking directory: $e");
     }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }

  IconData _getPlatformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android': return Icons.android_rounded;
      case 'ios': return Icons.apple_rounded;
      case 'windows': return Icons.desktop_windows_rounded;
      case 'macos': return Icons.laptop_mac_rounded;
      default: return Icons.devices_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
            decoration: BoxDecoration(
              color: kZapSurface.withOpacity(0.95), // Slightly transparent for glass feel
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
                width: 1,
              ),
              boxShadow: [
                 BoxShadow(
                   color: kZapPrimary.withOpacity(0.15),
                   blurRadius: 40,
                   spreadRadius: 0,
                   offset: const Offset(0, 10),
                 ),
                 BoxShadow(
                   color: Colors.black.withOpacity(0.5),
                   blurRadius: 20,
                   offset: const Offset(0, 10),
                 ),
              ],
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header: Icon + Name
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                     Container(
                      width: 50, height: 50,
                      margin: const EdgeInsets.only(right: 16),
                      decoration: BoxDecoration(
                        color: kZapPrimary.withOpacity(0.2),
                        shape: BoxShape.circle,
                        border: Border.all(color: kZapPrimary.withOpacity(0.5), width: 2),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Image.asset(
                          'assets/images/logo.png', 
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                            Text(
                              widget.request.deviceName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              'wants to share files',
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 12,
                              ),
                            ),
                         ],
                      ),
                    )
                  ],
                ),
                
                const SizedBox(height: 24),
                
                // File List Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Selected (${_selectedFiles.length})", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    GestureDetector(
                      onTap: () {
                         setState(() {
                            if (_selectedFiles.length == widget.request.fileNames.length) {
                               _selectedFiles.clear();
                            } else {
                               _selectedFiles = Set.from(widget.request.fileNames);
                            }
                         });
                      },
                      child: Text(
                         _selectedFiles.length == widget.request.fileNames.length ? "Clear All" : "Select All",
                         style: const TextStyle(color: kZapPrimary, fontSize: 12),
                      ),
                    )
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Row(
                    children: [
                      Icon(Icons.touch_app_rounded, size: 12, color: Colors.white.withOpacity(0.4)),
                      const SizedBox(width: 4),
                      Text(
                        "Tap to select • Long press to preview",
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 10,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Scrollable File List
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: widget.request.fileNames.length,
                        separatorBuilder: (_,__) => Divider(height: 1, color: Colors.white.withOpacity(0.05)),
                        itemBuilder: (context, index) {
                           final fileName = widget.request.fileNames[index];
                           final isSelected = _selectedFiles.contains(fileName);
                           
                           return Material(
                             color: Colors.transparent,
                             child: InkWell(
                               onTap: () {
                                  setState(() {
                                     if (isSelected) {
                                       _selectedFiles.remove(fileName);
                                     } else {
                                       _selectedFiles.add(fileName);
                                     }
                                  });
                               },
                               onLongPress: () {
                                 HapticFeedback.mediumImpact();
                                 _showFilePreview(context, index);
                               },
                               child: Padding(
                                 padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                                 child: Row(
                                   children: [
                                     Icon(_getFileIcon(fileName), color: isSelected ? kZapPrimary : Colors.grey, size: 20),
                                     const SizedBox(width: 12),
                                     Expanded(
                                       child: Text(
                                         fileName,
                                         style: TextStyle(
                                           color: isSelected ? Colors.white : Colors.grey[500],
                                           fontSize: 14,
                                           fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal
                                         ),
                                         maxLines: 1,
                                         overflow: TextOverflow.ellipsis,
                                       ),
                                     ),
                                     Container(
                                       width: 20, height: 20,
                                       decoration: BoxDecoration(
                                         color: isSelected ? kZapPrimary : Colors.transparent,
                                         borderRadius: BorderRadius.circular(6),
                                         border: Border.all(color: isSelected ? kZapPrimary : Colors.grey[600]!),
                                       ),
                                       child: isSelected ? const Icon(Icons.check, size: 14, color: Colors.black) : null,
                                     )
                                   ],
                                 ),
                               ),
                             ),
                           );
                        },
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                
                // Save Path Picker
                GestureDetector(
                   onTap: _pickSavePath,
                   child: Container(
                     padding: const EdgeInsets.all(12),
                     decoration: BoxDecoration(
                       color: Colors.white.withOpacity(0.05),
                       borderRadius: BorderRadius.circular(12),
                       border: Border.all(color: Colors.white.withOpacity(0.1)),
                     ),
                     child: Row(
                        children: [
                           const Icon(Icons.folder_open_rounded, color: Colors.grey, size: 20),
                           const SizedBox(width: 12),
                           Expanded(
                              child: Column(
                                 crossAxisAlignment: CrossAxisAlignment.start,
                                 children: [
                                    const Text("Save to", style: TextStyle(color: Colors.grey, fontSize: 10)),
                                    Text(
                                      _savePath != null ? ".../${_savePath!.split('/').last}" : "Select Folder",
                                      style: const TextStyle(color: Colors.white, fontSize: 13),
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                    ),
                                 ],
                              )
                           ),
                           const Icon(Icons.edit_rounded, color: kZapPrimary, size: 16),
                        ],
                     ),
                   ),
                ),

                const SizedBox(height: 24),
                
                // Action Buttons
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () {
                           HapticFeedback.lightImpact();
                           widget.onDecline();
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: Colors.white.withOpacity(0.05),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('Decline', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _selectedFiles.isEmpty ? null : () {
                           HapticFeedback.heavyImpact();
                           widget.onAccept(_selectedFiles.toList(), _savePath);
                        },
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: kZapPrimary,
                          foregroundColor: Colors.black,
                          disabledBackgroundColor: kZapPrimary.withOpacity(0.2),
                          elevation: 0,
                          shadowColor: kZapPrimary.withOpacity(0.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: Text(
                           _selectedFiles.length == widget.request.fileNames.length ? 'Accept All' : 'Accept Selected', 
                           style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'heic':
        return Icons.image_rounded;
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
        return Icons.movie_rounded;
      case 'mp3':
      case 'wav':
      case 'aac':
      case 'flac':
        return Icons.audiotrack_rounded;
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'doc':
      case 'docx':
      case 'txt':
        return Icons.description_rounded;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  void _showFilePreview(BuildContext context, int initialIndex) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black.withOpacity(0.9),
        pageBuilder: (BuildContext context, _, __) {
          return Scaffold(
            backgroundColor: Colors.black.withOpacity(0.95),
            body: SafeArea(
              child: Stack(
                children: [
                  // Gallery
                  PageView.builder(
                    controller: PageController(initialPage: initialIndex),
                    itemCount: widget.request.fileNames.length,
                    itemBuilder: (context, index) {
                      final fileName = widget.request.fileNames[index];
                      // Construct preview URL
                      String? previewUrl;
                      if (widget.request.previewPort > 0) {
                        previewUrl = 'http://${widget.request.ipAddress}:${widget.request.previewPort}/${Uri.encodeComponent(fileName)}';
                      }
                      
                      return Hero(
                        tag: 'preview_$fileName',
                        child: _buildPreviewContent(fileName, previewUrl, isFullScreen: true),
                      );
                    },
                  ),
                  
                  // Top Bar (Overlay)
                  Positioned(
                    top: 10,
                    left: 20,
                    right: 10,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // We can't easily show the current filename here without state, 
                        // but for simplicity we can just show a close button or 
                        // make this a stateful widget to track current index.
                        // For now, let's just show a Close button.
                        const Spacer(),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  bool _canPreview(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'pdf', 'mp4', 'mov', 'avi', 'mkv', 'mp3', 'wav', 'm4a'].contains(ext);
  }

  bool _isImage(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'].contains(ext);
  }

  bool _isVideo(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
  }

  bool _isAudio(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ['mp3', 'wav', 'm4a'].contains(ext);
  }

  Widget _buildPreviewContent(String fileName, String? url, {bool isFullScreen = false}) {
     print('🔍 Building Preview for: $fileName');
     print('🔍 URL: $url');
     print('🔍 Port: ${widget.request.previewPort}');
     
     if (url != null) {
        if (fileName.toLowerCase().endsWith('.pdf')) {
          print('📄 Loading PDF Preview...');
          return SfPdfViewer.network(
            url,
            canShowScrollHead: false,
            canShowScrollStatus: false,
            enableDoubleTapZooming: true,
          );
        }

        if (_isVideo(fileName)) {
           print('🎥 Loading Video Preview...');
           return VideoPreviewWidget(url: url);
        }

        if (_isAudio(fileName)) {
           print('🎵 Loading Audio Preview...');
           return VideoPreviewWidget(url: url, isAudio: true);
        }

        if (_isImage(fileName)) {
          print('🖼️ Loading Image Preview...');
          final image = Image.network(
             url, 
             fit: isFullScreen ? BoxFit.contain : BoxFit.cover,
             loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return Center(child: CircularProgressIndicator(value: progress.expectedTotalBytes != null ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes! : null));
             },
             errorBuilder: (ctx, err, stack) {
               print('❌ Image Load Error: $err');
               return Column(
                 mainAxisAlignment: MainAxisAlignment.center,
                 children: [
                   Icon(Icons.broken_image_rounded, size: isFullScreen ? 80 : 40, color: Colors.grey[600]),
                   const SizedBox(height: 8),
                   Text("Preview Failed: $err", style: TextStyle(color: Colors.grey[600], fontSize: 10), textAlign: TextAlign.center,)
                 ],
               );
             },
          );

          if (isFullScreen) {
             return InteractiveViewer(
               minScale: 1.0,
               maxScale: 4.0,
               child: image,
             );
          }
          return image;
        } else {
           print('⚠️ Filename does not look like an image: $fileName');
        }
     } else {
        print('⚠️ Preview URL is null (Port: ${widget.request.previewPort})');
     }

     // Fallback for non-previewable files
     return Center(
       child: Icon(_getFileIcon(fileName), size: isFullScreen ? 120 : 60, color: kZapPrimary),
     );
  }
}

class VideoPreviewWidget extends StatefulWidget {
  final String url;
  final bool isAudio;
  
  const VideoPreviewWidget({super.key, required this.url, this.isAudio = false});

  @override
  State<VideoPreviewWidget> createState() => _VideoPreviewWidgetState();
}

class _VideoPreviewWidgetState extends State<VideoPreviewWidget> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    try {
      _videoController = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await _videoController!.initialize();
      
      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: true,
        aspectRatio: widget.isAudio ? 16/9 : _videoController!.value.aspectRatio,
        allowFullScreen: !widget.isAudio,
        showControls: true,
        customControls: widget.isAudio ? const CupertinoControls(backgroundColor: Colors.white10, iconColor: Colors.white) : null,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              errorMessage,
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      );
      setState(() {});
    } catch (e) {
      print("Video initialization error: $e");
      setState(() {
        _error = true;
      });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 50),
            const SizedBox(height: 8),
            Text("Could not play ${widget.isAudio ? 'audio' : 'video'}", style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    if (_chewieController != null && _videoController!.value.isInitialized) {
      return Stack(
        alignment: Alignment.center,
        children: [
          // Background/Visualizer for Audio
          if (widget.isAudio)
             Container(
               color: Colors.transparent,
               alignment: Alignment.center,
               child: Column(
                 mainAxisSize: MainAxisSize.min,
                 children: [
                   Container(
                     padding: const EdgeInsets.all(30),
                     decoration: BoxDecoration(
                       color: Colors.white.withOpacity(0.1),
                       shape: BoxShape.circle
                     ),
                     child: const Icon(Icons.music_note_rounded, size: 80, color: kZapPrimary),
                   ),
                   const SizedBox(height: 20),
                   const Text("Audio Preview", style: TextStyle(color: Colors.white54))
                 ],
               ),
             ),

          // Player
          AspectRatio(
            aspectRatio: widget.isAudio ? 16/9 : _videoController!.value.aspectRatio,
            child: Chewie(controller: _chewieController!),
          ),
        ],
      );
    }

    return const Center(child: CircularProgressIndicator());
  }
}
