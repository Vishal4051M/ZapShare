import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_file/open_file.dart';

enum FileType {
  image,
  video,
  audio,
  pdf,
  document,
  spreadsheet,
  presentation,
  archive,
  apk,
  text,
  other,
}

class ReceivedFileItem {
  final String name;
  final int size;
  final String path;
  final DateTime receivedAt;

  ReceivedFileItem({
    required this.name,
    required this.size,
    required this.path,
    required this.receivedAt,
  });
}

class WebReceivedFilesScreen extends StatefulWidget {
  final List<ReceivedFileItem> files;

  const WebReceivedFilesScreen({super.key, required this.files});

  @override
  State<WebReceivedFilesScreen> createState() => _WebReceivedFilesScreenState();
}

class _WebReceivedFilesScreenState extends State<WebReceivedFilesScreen> {
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child:
                    (MediaQuery.of(context).orientation ==
                                Orientation.landscape ||
                            MediaQuery.of(context).size.width > 900)
                        ? _buildGridView()
                        : SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 8),
                              _buildFileList(),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGridView() {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width > 900 ? 3 : 2;

    if (widget.files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.cloud_download_rounded,
                size: 64,
                color: Colors.grey[700],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No files received yet',
              style: GoogleFonts.outfit(
                color: Colors.grey[500],
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 3.0,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: widget.files.length,
      itemBuilder: (context, index) => _buildFileItem(widget.files[index]),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: 20,
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Received Files',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  '${widget.files.length} files',
                  style: GoogleFonts.outfit(
                    color: Colors.grey[400],
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileList() {
    if (widget.files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 100),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_download_rounded,
                  size: 64,
                  color: Colors.grey[700],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'No files received yet',
                style: GoogleFonts.outfit(
                  color: Colors.grey[500],
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ALL FILES',
          style: GoogleFonts.outfit(
            color: Colors.grey[300],
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 16),
        ...widget.files.map((file) => _buildFileItem(file)),
      ],
    );
  }

  Widget _buildFileItem(ReceivedFileItem file) {
    final fileType = _getFileType(file.name);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: _getFileTypeColor(fileType).withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            _getFileTypeIcon(fileType),
            color: _getFileTypeColor(fileType),
            size: 28,
          ),
        ),
        title: Text(
          file.name,
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _formatBytes(file.size),
            style: GoogleFonts.outfit(
              color: Colors.grey[400],
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        trailing: IconButton(
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFD600).withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.open_in_new_rounded,
              color: Color(0xFFFFD600),
              size: 20,
            ),
          ),
          onPressed: () => _openFile(file),
        ),
      ),
    );
  }

  Future<void> _openFile(ReceivedFileItem file) async {
    try {
      final result = await OpenFile.open(file.path);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not open file: ${result.message}',
              style: GoogleFonts.outfit(color: Colors.white),
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error opening file: $e',
              style: GoogleFonts.outfit(color: Colors.white),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  FileType _getFileType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'].contains(ext))
      return FileType.image;
    if (['mp4', 'mov', 'avi', 'mkv', 'flv', 'wmv', 'webm'].contains(ext))
      return FileType.video;
    if (['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a'].contains(ext))
      return FileType.audio;
    if (ext == 'pdf') return FileType.pdf;
    if (['doc', 'docx', 'txt', 'rtf', 'odt'].contains(ext))
      return FileType.document;
    if (['xls', 'xlsx', 'csv', 'ods'].contains(ext))
      return FileType.spreadsheet;
    if (['ppt', 'pptx', 'odp'].contains(ext)) return FileType.presentation;
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2'].contains(ext))
      return FileType.archive;
    if (ext == 'apk') return FileType.apk;
    if (['txt', 'md', 'json', 'xml', 'html', 'css', 'js'].contains(ext))
      return FileType.text;
    return FileType.other;
  }

  IconData _getFileTypeIcon(FileType type) {
    switch (type) {
      case FileType.image:
        return Icons.image_rounded;
      case FileType.video:
        return Icons.videocam_rounded;
      case FileType.audio:
        return Icons.audiotrack_rounded;
      case FileType.pdf:
        return Icons.picture_as_pdf_rounded;
      case FileType.document:
        return Icons.description_rounded;
      case FileType.spreadsheet:
        return Icons.table_chart_rounded;
      case FileType.presentation:
        return Icons.slideshow_rounded;
      case FileType.archive:
        return Icons.folder_zip_rounded;
      case FileType.apk:
        return Icons.android_rounded;
      case FileType.text:
        return Icons.text_snippet_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color _getFileTypeColor(FileType type) {
    switch (type) {
      case FileType.image:
        return Colors.purple;
      case FileType.video:
        return Colors.red;
      case FileType.audio:
        return Colors.orange;
      case FileType.pdf:
        return Colors.redAccent;
      case FileType.document:
        return Colors.blue;
      case FileType.spreadsheet:
        return Colors.green;
      case FileType.presentation:
        return Colors.deepOrange;
      case FileType.archive:
        return Colors.amber;
      case FileType.apk:
        return Colors.lightGreen;
      case FileType.text:
        return Colors.cyan;
      default:
        return Colors.grey;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024)
      return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }
}
