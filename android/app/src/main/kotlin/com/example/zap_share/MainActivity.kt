package com.example.zap_share
import android.net.Uri
import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import android.app.Activity
import android.content.Intent
import android.os.Build
import android.provider.DocumentsContract
import org.json.JSONArray
import org.json.JSONObject
import android.database.Cursor
import android.provider.OpenableColumns

class MainActivity : FlutterActivity() {
    private val CHANNEL = "zapshare.saf"
    private val inputStreams = mutableMapOf<String, InputStream>()
    private var initialSharedUris: List<String>? = null
    private var methodChannel: MethodChannel? = null

    // --- SAF Folder Picker additions ---
    private var folderResult: MethodChannel.Result? = null
    private val FOLDER_PICKER_REQUEST = 9999
    private var pickedFolderUri: Uri? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openReadStream" -> {
                    val uriStr = call.argument<String>("uri")
                    try {
                        val uri = Uri.parse(uriStr)
                        val stream = contentResolver.openInputStream(uri)
                        if (stream != null) {
                            inputStreams[uriStr!!] = stream
                            result.success(true)
                        } else {
                            result.error("STREAM_FAIL", "Could not open input stream", null)
                        }
                    } catch (e: Exception) {
                        result.error("EXCEPTION", e.message, null)
                    }
                }

               "getFileSize" -> {
    val uriStr = call.argument<String>("uri")
    try {
        val uri = Uri.parse(uriStr)
        val size = contentResolver.openAssetFileDescriptor(uri, "r")?.length ?: -1L
        if (size >= 0L) {
            result.success(size) // Send as Long (Dart will get it as double)
        } else {
            result.error("SIZE_FAIL", "Unable to determine size", null)
        }
    } catch (e: Exception) {
        result.error("SIZE_EXCEPTION", e.message, null)
    }
}



                "readChunk" -> {
                    val uriStr = call.argument<String>("uri")
                    val size = call.argument<Int>("size") ?: 65536
                    val stream = inputStreams[uriStr]
                    if (stream == null) {
                        result.error("NO_STREAM", "Stream not opened for URI", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val buffer = ByteArray(size)
                        val bytesRead = stream.read(buffer)
                        if (bytesRead == -1) {
                            result.success(null) // End of file
                        } else {
                            result.success(buffer.copyOf(bytesRead)) // Only return valid portion
                        }
                    } catch (e: Exception) {
                        result.error("READ_ERROR", e.message, null)
                    }
                }

                "closeStream" -> {
                    val uriStr = call.argument<String>("uri")
                    val stream = inputStreams.remove(uriStr)
                    try {
                        stream?.close()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CLOSE_ERROR", e.message, null)
                    }
                }

                "pickFolder" -> {
                    folderResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    startActivityForResult(intent, FOLDER_PICKER_REQUEST)
                }

                "listFilesInFolder" -> {
                    val folderUriStr = call.argument<String>("folderUri")
                    if (folderUriStr == null) {
                        result.error("NO_URI", "No folder URI provided", null)
                        return@setMethodCallHandler
                    }
                    val folderUri = Uri.parse(folderUriStr)
                    val files = JSONArray()
                    listFilesRecursively(folderUri, files)
                    result.success(files.toString())
                }

                "readWholeFile" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("NO_URI", "No file URI provided", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = Uri.parse(uriStr)
                        val inputStream = contentResolver.openInputStream(uri)
                        if (inputStream != null) {
                            val bytes = inputStream.readBytes()
                            inputStream.close()
                            result.success(bytes)
                        } else {
                            result.error("READ_FAIL", "Could not open input stream", null)
                        }
                    } catch (e: Exception) {
                        result.error("EXCEPTION", e.message, null)
                    }
                }

                "zipFilesToCache" -> {
                    val uris = call.argument<List<String>>("uris")
                    val names = call.argument<List<String>>("names")
                    val zipName = call.argument<String>("zipName") ?: "shared.zip"
                    if (uris == null || names == null || uris.size != names.size) {
                        result.error("INVALID_ARGS", "Invalid file list", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val cacheDir = cacheDir
                        val zipFile = java.io.File(cacheDir, zipName)
                        val zos = java.util.zip.ZipOutputStream(zipFile.outputStream())
                        for (i in uris.indices) {
                            val uri = Uri.parse(uris[i])
                            val entry = java.util.zip.ZipEntry(names[i])
                            zos.putNextEntry(entry)
                            val input = contentResolver.openInputStream(uri)
                            if (input != null) {
                                val buffer = ByteArray(64 * 1024)
                                var len: Int
                                while (input.read(buffer).also { len = it } > 0) {
                                    zos.write(buffer, 0, len)
                                }
                                input.close()
                            }
                            zos.closeEntry()
                        }
                        zos.close()
                        result.success(zipFile.absolutePath)
                    } catch (e: Exception) {
                        result.error("ZIP_ERROR", e.message, null)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        val type = intent.type
        if (Intent.ACTION_SEND == action && type != null) {
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (uri != null) {
                val name = getFileNameFromUri(uri)
                val files = listOf(mapOf("uri" to uri.toString(), "name" to name))
                methodChannel?.invokeMethod("sharedFiles", files)
            }
        } else if (Intent.ACTION_SEND_MULTIPLE == action && type != null) {
            val uriList = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (uriList != null && uriList.isNotEmpty()) {
                val files = uriList.map { uri ->
                    mapOf("uri" to uri.toString(), "name" to getFileNameFromUri(uri))
                }
                methodChannel?.invokeMethod("sharedFiles", files)
            }
        }
    }

    private fun getFileNameFromUri(uri: Uri): String {
        var name = uri.lastPathSegment ?: "file"
        try {
            val cursor: Cursor? = contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (it.moveToFirst() && nameIndex != -1) {
                    name = it.getString(nameIndex)
                }
            }
        } catch (_: Exception) {}
        return name
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FOLDER_PICKER_REQUEST) {
            if (resultCode == Activity.RESULT_OK) {
                val uri = data?.data
                pickedFolderUri = uri
                folderResult?.success(uri?.toString())
            } else {
                folderResult?.success(null)
            }
            folderResult = null
        }
    }

    // Helper function to recursively list files in a folder
    private fun listFilesRecursively(folderUri: Uri, files: JSONArray) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            folderUri,
            DocumentsContract.getTreeDocumentId(folderUri)
        )
        val cursor = contentResolver.query(childrenUri, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        ), null, null, null)
        cursor?.use {
            while (it.moveToNext()) {
                val docId = it.getString(0)
                val name = it.getString(1)
                val mime = it.getString(2)
                val docUri = DocumentsContract.buildDocumentUriUsingTree(folderUri, docId)
                if (DocumentsContract.Document.MIME_TYPE_DIR == mime) {
                    listFilesRecursively(docUri, files)
                } else {
                    val fileObj = JSONObject()
                    fileObj.put("uri", docUri.toString())
                    fileObj.put("name", name)
                    files.put(fileObj)
                }
            }
        }
    }
}