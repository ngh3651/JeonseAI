import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

// ===== 백엔드 주소 =====
// 나중에 바꾸기 쉽도록 상수로 분리합니다.
//
// 이 프로젝트는 안드로이드 실기기 전용입니다. (웹/에뮬레이터 기준 아님)
// 실기기는 PC의 Wi-Fi LAN IP로 접근해야 하며, 휴대폰과 PC가 같은 Wi-Fi에 있어야 합니다.
//
// !! 주의: PC가 다른 네트워크로 바뀌면 LAN IP가 달라집니다.
//          그때는 PC에서 `ipconfig`로 IPv4 주소를 재확인한 뒤 아래 baseUrl을 갱신하세요.
const String baseUrl = 'http://172.30.1.39:8000'; // 실기기용 (PC의 LAN IP)
// const String baseUrl = "http://10.0.2.2:8000";   // 안드로이드 에뮬레이터용 (주석 보관)

void main() {
  runApp(const JeonseAiApp());
}

class JeonseAiApp extends StatelessWidget {
  const JeonseAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '전세AI프',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const UploadScreen(),
    );
  }
}

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  final ImagePicker _picker = ImagePicker();

  File? _selectedImage; // 선택한 이미지 파일
  bool _isUploading = false; // 업로드 중 여부
  String? _errorMessage; // 에러 메시지 (한국어)
  Map<String, dynamic>? _result; // 백엔드 응답 결과

  /// 카메라 또는 갤러리에서 이미지를 선택합니다.
  ///
  /// 갤럭시 기본 카메라는 사진을 HEIC/HEIF로 저장할 수 있는데, 백엔드는 JPEG/PNG/WEBP만
  /// 받습니다. 그래서 어떤 형식이 들어오든 여기서 **항상 JPEG로 변환**한 뒤에 보관·업로드합니다.
  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? picked = await _picker.pickImage(source: source);
      if (picked == null) return; // 사용자가 취소함

      // 업로드 전에 JPEG로 변환합니다. (HEIC 등 어떤 형식이든 통일)
      final File? jpeg = await _convertToJpeg(picked.path);
      if (jpeg == null) {
        setState(() {
          _selectedImage = null;
          _result = null;
          _errorMessage = '이미지를 변환하지 못했습니다. 다른 사진으로 다시 시도해 주세요.';
        });
        return;
      }

      setState(() {
        _selectedImage = jpeg;
        _result = null;
        _errorMessage = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '이미지를 불러오지 못했습니다. 다시 시도해 주세요.';
      });
    }
  }

  /// 입력 이미지를 JPEG로 변환합니다.
  ///
  /// 안드로이드 네이티브 코덱을 사용하므로 HEIC/HEIF도 디코딩할 수 있습니다.
  /// (순수 Dart 이미지 라이브러리는 HEIC 디코딩을 지원하지 않아 flutter_image_compress를 사용)
  /// 실패 시 null을 반환하고, 호출부에서 한국어 안내 메시지를 표시합니다.
  Future<File?> _convertToJpeg(String sourcePath) async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String targetPath =
          '${tempDir.path}/upload_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final XFile? converted = await FlutterImageCompress.compressAndGetFile(
        sourcePath,
        targetPath,
        format: CompressFormat.jpeg,
        quality: 90, // OCR 가독성을 위해 화질을 비교적 높게 유지
      );

      if (converted == null) return null;
      return File(converted.path);
    } catch (e) {
      return null; // 호출부에서 사용자 안내 처리
    }
  }

  /// 선택한 이미지를 백엔드(POST /api/upload)로 업로드합니다.
  Future<void> _uploadImage() async {
    final File? image = _selectedImage;
    if (image == null) return;

    setState(() {
      _isUploading = true;
      _errorMessage = null;
      _result = null;
    });

    try {
      final uri = Uri.parse('$baseUrl/api/upload');
      // 항상 JPEG로 변환된 파일이므로 Content-Type을 image/jpeg로 명시합니다.
      // (명시하지 않으면 application/octet-stream으로 전송되어 백엔드가 거부할 수 있음)
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath(
          'file',
          image.path,
          filename: 'upload.jpg',
          contentType: MediaType('image', 'jpeg'),
        ));

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      final body = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200) {
        setState(() {
          _result = body as Map<String, dynamic>;
        });
      } else {
        // 백엔드가 보낸 한국어 에러 메시지(detail)를 우선 표시합니다.
        final detail = (body is Map && body['detail'] != null)
            ? body['detail'].toString()
            : '업로드에 실패했습니다. (상태 코드: ${response.statusCode})';
        setState(() {
          _errorMessage = detail;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '서버에 연결하지 못했습니다. 백엔드 주소와 네트워크를 확인해 주세요.';
      });
    } finally {
      setState(() {
        _isUploading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('전세AI프'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 이미지 선택 버튼 2개
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _isUploading ? null : () => _pickImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('사진 촬영'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _isUploading
                        ? null
                        : () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('갤러리에서 선택'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 이미지 미리보기
            _buildPreview(),
            const SizedBox(height: 16),

            // 분석하기(업로드) 버튼
            FilledButton.icon(
              onPressed: (_selectedImage == null || _isUploading)
                  ? null
                  : _uploadImage,
              icon: const Icon(Icons.cloud_upload),
              label: const Text('분석하기'),
            ),
            const SizedBox(height: 16),

            // 로딩 인디케이터
            if (_isUploading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),

            // 에러 메시지
            if (_errorMessage != null) _buildError(_errorMessage!),

            // 백엔드 응답 결과
            if (_result != null) _buildResult(_result!),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (_selectedImage == null) {
      return Container(
        height: 240,
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: const Center(
          child: Text(
            '등기부등본 이미지를 선택해 주세요',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        _selectedImage!,
        height: 240,
        width: double.infinity,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _buildError(String message) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade400),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Colors.red.shade700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult(Map<String, dynamic> result) {
    final filename = result['filename']?.toString() ?? '-';
    final sizeBytes = result['size_bytes'];
    final message = result['message']?.toString() ?? '';
    final sizeText = (sizeBytes is num)
        ? '${(sizeBytes / 1024).toStringAsFixed(1)} KB ($sizeBytes bytes)'
        : '$sizeBytes';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.green.shade500),
              const SizedBox(width: 8),
              Text(
                '업로드 결과',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.green.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _resultRow('파일명', filename),
          _resultRow('크기', sizeText),
          _resultRow('메시지', message),
        ],
      ),
    );
  }

  Widget _resultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
