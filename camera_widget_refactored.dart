// Automatic FlutterFlow imports
import '/backend/backend.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart';
import '/custom_code/actions/index.dart';
import '/flutter_flow/custom_functions.dart';
import 'package:flutter/material.dart';
// Begin custom widget code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io' show File, Platform;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'dart:async';

/// ============================================================================
/// CONFIGURATION
/// ============================================================================
class FaceDetectionConfig {
  static const double minFaceSize = 0.15;
  static const double maxFaceSize = 0.50;
  static const double centerTolerance = 0.20;
  static const double angleTolerance = 25.0;
  static const double eyeOpenThreshold = 0.4;

  // ✅ NOUVEAU: Logging conditionnel
  static const bool enableDebugLogs = kDebugMode; // false en production
  static const bool showDebugButton = kDebugMode;

  // ✅ NOUVEAU: Performance
  static const int frameSkipCount = 3; // Traiter 1 frame sur 3
  static const Duration feedbackThrottle = Duration(milliseconds: 200);
  static const Duration faceDetectionTimeout = Duration(milliseconds: 500);
}

/// ============================================================================
/// LOGGER - Logs conditionnels
/// ============================================================================
class CameraLogger {
  static void log(String message) {
    if (FaceDetectionConfig.enableDebugLogs) {
      debugPrint(message);
    }
  }

  static void error(String message) {
    debugPrint("❌ $message"); // Toujours logger les erreurs
  }

  static void info(String message) {
    if (FaceDetectionConfig.enableDebugLogs) {
      debugPrint("ℹ️ $message");
    }
  }
}

/// ============================================================================
/// HELPERS - Compression et crop
/// ============================================================================
class ImageProcessor {
  static Future<Uint8List> compressImage(String filePath) async {
    if (kIsWeb) {
      throw UnimplementedError("Compression non supportée sur web");
    }

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception("Fichier inexistant: $filePath");
      }

      final compressedBytes = await FlutterImageCompress.compressWithFile(
        filePath,
        quality: 85,
        minWidth: 600,
        minHeight: 600,
      ).timeout(
        Duration(seconds: 10),
        onTimeout: () => null,
      );

      if (compressedBytes == null || compressedBytes.isEmpty) {
        CameraLogger.log("⚠️ Compression échouée, utilisation originale");
        return await file.readAsBytes();
      }

      CameraLogger.log("✅ Image compressée: ${compressedBytes.length} bytes");
      return compressedBytes;
    } catch (e) {
      CameraLogger.error("Erreur compression: $e");
      return await File(filePath).readAsBytes();
    }
  }

  static Future<Uint8List> cropToIdentityFormat(Uint8List imageBytes) async {
    try {
      img.Image? originalImage = img.decodeImage(imageBytes);
      if (originalImage == null) {
        CameraLogger.log("⚠️ Impossible de décoder pour crop");
        return imageBytes;
      }

      final int originalWidth = originalImage.width;
      final int originalHeight = originalImage.height;
      const double targetRatio = 7 / 9;

      int cropWidth;
      int cropHeight;
      final double currentRatio = originalWidth / originalHeight;

      if (currentRatio > targetRatio) {
        cropHeight = originalHeight;
        cropWidth = (cropHeight * targetRatio).round();
      } else {
        cropWidth = originalWidth;
        cropHeight = (cropWidth / targetRatio).round();
      }

      cropWidth = cropWidth.clamp(1, originalWidth);
      cropHeight = cropHeight.clamp(1, originalHeight);

      final int offsetX = ((originalWidth - cropWidth) / 2)
          .round()
          .clamp(0, originalWidth - cropWidth);
      final int offsetY = ((originalHeight - cropHeight) / 2)
          .round()
          .clamp(0, originalHeight - cropHeight);

      img.Image croppedImage = img.copyCrop(
        originalImage,
        x: offsetX,
        y: offsetY,
        width: cropWidth,
        height: cropHeight,
      );

      final encodedBytes = img.encodeJpg(croppedImage, quality: 95);
      CameraLogger.log("✅ Image recadrée: ${cropWidth}x${cropHeight}");

      return Uint8List.fromList(encodedBytes);
    } catch (e) {
      CameraLogger.error("Erreur crop: $e");
      return imageBytes;
    }
  }
}

/// ============================================================================
/// YUV CONVERTER
/// ============================================================================
class YUVConverter {
  static Uint8List convertYUV420ToNV21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int imageSize = width * height;
    final int uvSize = width * height ~/ 2;

    final Uint8List nv21 = Uint8List(imageSize + uvSize);

    final yPlane = image.planes[0];
    final yBuffer = yPlane.bytes;
    final int yRowStride = yPlane.bytesPerRow;
    final int yPixelStride = yPlane.bytesPerPixel ?? 1;

    int nv21Index = 0;
    for (int y = 0; y < height; y++) {
      int yBufferIndex = y * yRowStride;
      for (int x = 0; x < width; x++) {
        nv21[nv21Index++] = yBuffer[yBufferIndex];
        yBufferIndex += yPixelStride;
      }
    }

    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uBuffer = uPlane.bytes;
    final vBuffer = vPlane.bytes;

    final int uvWidth = width ~/ 2;
    final int uvHeight = height ~/ 2;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final int uvRowStride = uPlane.bytesPerRow;

    bool areUVPlanesNV21 = false;
    if (uvPixelStride == 2) {
      try {
        if (uBuffer.length == vBuffer.length && uBuffer.length >= uvSize) {
          areUVPlanesNV21 = true;
        }
      } catch (e) {
        areUVPlanesNV21 = false;
      }
    }

    if (areUVPlanesNV21) {
      int uvIndex = imageSize;
      if (vBuffer.isNotEmpty) {
        nv21[uvIndex++] = vBuffer[0];
      }

      int uBufferIndex = 0;
      for (int i = 1; i < uvSize; i++) {
        if (uBufferIndex < uBuffer.length) {
          nv21[uvIndex++] = uBuffer[uBufferIndex];
          uBufferIndex++;
        }
      }
    } else {
      int uvIndex = imageSize;

      for (int y = 0; y < uvHeight; y++) {
        int vBufferIndex = y * uvRowStride;
        int uBufferIndex = y * uvRowStride;

        for (int x = 0; x < uvWidth; x++) {
          nv21[uvIndex++] = vBuffer[vBufferIndex];
          nv21[uvIndex++] = uBuffer[uBufferIndex];

          vBufferIndex += uvPixelStride;
          uBufferIndex += uvPixelStride;
        }
      }
    }

    return nv21;
  }
}

/// ============================================================================
/// COORDINATE TRANSFORMER
/// ============================================================================
class CoordinateTransformer {
  final int imageWidth;
  final int imageHeight;
  final Size viewSize;
  final bool isImageFlipped;

  late double scaleFactor;
  late double postScaleWidthOffset;
  late double postScaleHeightOffset;

  CoordinateTransformer({
    required this.imageWidth,
    required this.imageHeight,
    required this.viewSize,
    required this.isImageFlipped,
  }) {
    _calculateTransformation();
  }

  void _calculateTransformation() {
    final double viewAspectRatio = viewSize.width / viewSize.height;
    final double imageAspectRatio = imageWidth / imageHeight;

    postScaleWidthOffset = 0;
    postScaleHeightOffset = 0;

    if (viewAspectRatio > imageAspectRatio) {
      scaleFactor = viewSize.width / imageWidth;
      postScaleHeightOffset =
          (viewSize.width / imageAspectRatio - viewSize.height) / 2;
    } else {
      scaleFactor = viewSize.height / imageHeight;
      postScaleWidthOffset =
          (viewSize.height * imageAspectRatio - viewSize.width) / 2;
    }

    CameraLogger.log("🔧 Transformer: ${imageWidth}x${imageHeight} → ${viewSize.width.toStringAsFixed(1)}x${viewSize.height.toStringAsFixed(1)}, scale=$scaleFactor");
  }

  double scale(double imagePixel) => imagePixel * scaleFactor;

  double translateX(double x) {
    if (isImageFlipped) {
      return viewSize.width - (scale(x) - postScaleWidthOffset);
    } else {
      return scale(x) - postScaleWidthOffset;
    }
  }

  double translateY(double y) => scale(y) - postScaleHeightOffset;
}

/// ============================================================================
/// VALIDATION RESULT
/// ============================================================================
class FaceValidationResult {
  final bool isValid;
  final String message;
  final Color color;
  final IconData icon;
  final String debugInfo;

  FaceValidationResult({
    required this.isValid,
    required this.message,
    required this.color,
    required this.icon,
    this.debugInfo = "",
  });

  factory FaceValidationResult.noFace() {
    return FaceValidationResult(
      isValid: false,
      message: "Positionnez votre visage",
      color: Colors.white,
      icon: Icons.face_outlined,
      debugInfo: "Aucun visage",
    );
  }

  factory FaceValidationResult.multipleFaces(int count) {
    return FaceValidationResult(
      isValid: false,
      message: "Une seule personne",
      color: Colors.orangeAccent,
      icon: Icons.people_outline,
      debugInfo: "$count visages",
    );
  }

  factory FaceValidationResult.success(String debugInfo) {
    return FaceValidationResult(
      isValid: true,
      message: "Parfait !",
      color: Color(0xFF00E676),
      icon: Icons.check_circle_outline,
      debugInfo: debugInfo,
    );
  }

  factory FaceValidationResult.error(
      String message, IconData icon, String debugInfo) {
    return FaceValidationResult(
      isValid: false,
      message: message,
      color: Colors.orangeAccent,
      icon: icon,
      debugInfo: debugInfo,
    );
  }
}

/// ============================================================================
/// FACE VALIDATOR
/// ============================================================================
class FaceValidator {
  final CoordinateTransformer transformer;
  final Size viewSize;

  FaceValidator({
    required this.transformer,
    required this.viewSize,
  });

  FaceValidationResult validate(Face face) {
    final rect = face.boundingBox;

    final double faceCenterX =
        transformer.translateX(rect.left + rect.width / 2);
    final double faceCenterY =
        transformer.translateY(rect.top + rect.height / 2);
    final double faceHeight = transformer.scale(rect.height.toDouble());

    // Vérification NaN
    if (faceCenterX.isNaN || faceCenterY.isNaN || faceHeight.isNaN) {
      CameraLogger.error("Coordonnées NaN détectées, skip validation");
      return FaceValidationResult.noFace();
    }

    final double screenCenterX = viewSize.width / 2;
    final double screenCenterY = viewSize.height / 2;

    final double faceRatio = faceHeight / viewSize.height;
    final double offsetX = (faceCenterX - screenCenterX).abs() / viewSize.width;
    final double offsetY = (faceCenterY - screenCenterY).abs() / viewSize.height;

    String debugStr = "Size:${(faceRatio * 100).toStringAsFixed(0)}% ";
    debugStr += "OffX:${(offsetX * 100).toStringAsFixed(0)}% ";
    debugStr += "OffY:${(offsetY * 100).toStringAsFixed(0)}%";

    // Validations
    if (faceRatio < FaceDetectionConfig.minFaceSize) {
      return FaceValidationResult.error(
        "Rapprochez-vous",
        Icons.zoom_in_outlined,
        debugStr + " TROP_LOIN",
      );
    }

    if (faceRatio > FaceDetectionConfig.maxFaceSize) {
      return FaceValidationResult.error(
        "Éloignez-vous",
        Icons.zoom_out_outlined,
        debugStr + " TROP_PRES",
      );
    }

    if (offsetX > FaceDetectionConfig.centerTolerance) {
      return FaceValidationResult.error(
        "Centrez horizontalement",
        Icons.center_focus_weak,
        debugStr + " DECENTRE_H",
      );
    }

    if (offsetY > FaceDetectionConfig.centerTolerance) {
      return FaceValidationResult.error(
        "Centrez verticalement",
        Icons.center_focus_weak,
        debugStr + " DECENTRE_V",
      );
    }

    final double yaw = face.headEulerAngleY ?? 0;
    final double roll = face.headEulerAngleZ ?? 0;

    if (yaw.abs() > FaceDetectionConfig.angleTolerance) {
      return FaceValidationResult.error(
        "Regardez droit devant",
        Icons.crop_rotate,
        debugStr + " YAW",
      );
    }

    if (roll.abs() > FaceDetectionConfig.angleTolerance) {
      return FaceValidationResult.error(
        "Tenez votre tête droite",
        Icons.crop_rotate,
        debugStr + " ROLL",
      );
    }

    if (face.leftEyeOpenProbability != null &&
        face.rightEyeOpenProbability != null) {
      final double leftEye = face.leftEyeOpenProbability!;
      final double rightEye = face.rightEyeOpenProbability!;

      if (leftEye < FaceDetectionConfig.eyeOpenThreshold ||
          rightEye < FaceDetectionConfig.eyeOpenThreshold) {
        return FaceValidationResult.error(
          "Ouvrez les yeux",
          Icons.remove_red_eye_outlined,
          debugStr + " YEUX_FERMES",
        );
      }
    }

    return FaceValidationResult.success(debugStr + " ✅");
  }
}

/// ============================================================================
/// CAMERA STATE - État centralisé
/// ============================================================================
enum CameraLifecycleState {
  uninitialized,
  initializing,
  ready,
  paused,
  disposed,
}

class CameraState {
  CameraLifecycleState lifecycle = CameraLifecycleState.uninitialized;
  bool isStreamingImages = false;
  bool isProcessingFrame = false;
  bool isProcessing = false;
  bool isFlashOn = false;
  bool isSwitchingCamera = false;
  bool isRearCamera = false;

  bool get canStartStream =>
    lifecycle == CameraLifecycleState.ready &&
    !isStreamingImages &&
    !isProcessing;

  bool get shouldProcessFrames =>
    lifecycle == CameraLifecycleState.ready &&
    isStreamingImages;
}

/// ============================================================================
/// WIDGET PRINCIPAL - CameraWidget Refactoré
/// ============================================================================
class CameraWidget extends StatefulWidget {
  const CameraWidget({
    Key? key,
    this.width,
    this.height,
    required this.uploadPhotosAction,
  }) : super(key: key);

  final double? width;
  final double? height;
  final Future Function(List<FFUploadedFile>? photos) uploadPhotosAction;

  @override
  State<CameraWidget> createState() => _CameraWidgetState();
}

class _CameraWidgetState extends State<CameraWidget>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {

  // ✅ État centralisé
  final CameraState _state = CameraState();

  // Caméra
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  FaceDetector? _faceDetector;

  // Feedback
  FaceValidationResult _currentResult = FaceValidationResult.noFace();
  CoordinateTransformer? _transformer;

  // Galerie
  List<AssetEntity> _galleryAssets = [];
  Uint8List? _galleryThumbnail;

  // Debug
  bool _showDebugInfo = false;

  // Animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Throttling
  DateTime? _lastFeedbackUpdate;
  int _frameCounter = 0;

  // Preview size
  double? _previewWidth;
  double? _previewHeight;

  // Stream dimensions
  int? _lastStreamImageWidth;
  int? _lastStreamImageHeight;
  InputImageRotation? _lastStreamRotation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializePulseAnimation();
    _initializeApp();
  }

  void _initializePulseAnimation() {
    _pulseController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _initializeApp() async {
    try {
      await _initializeFaceDetector();
      await _initializeCamera();
      await _fetchGalleryAssets();
    } catch (e) {
      CameraLogger.error('Erreur initialisation app: $e');
      _showError("Erreur d'initialisation");
    }
  }

  Future<void> _initializeFaceDetector() async {
    try {
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableContours: false,
          enableClassification: true,
          enableTracking: false,
          minFaceSize: 0.1,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );
      CameraLogger.log("✅ Face detector initialisé");
    } catch (e) {
      CameraLogger.error("Erreur init face detector: $e");
    }
  }

  Future<void> _initializeCamera() async {
    if (_state.lifecycle == CameraLifecycleState.disposed) return;

    _state.lifecycle = CameraLifecycleState.initializing;

    try {
      _cameras = await availableCameras();

      if (_cameras.isEmpty) {
        _showError("Aucune caméra disponible");
        return;
      }

      CameraDescription initialCamera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );

      _state.isRearCamera = initialCamera.lensDirection == CameraLensDirection.back;

      await _setupCameraController(initialCamera);
    } catch (e) {
      CameraLogger.error('Erreur initialisation caméra: $e');
      _showError("Erreur caméra");
      _state.lifecycle = CameraLifecycleState.uninitialized;
    }
  }

  Future<void> _setupCameraController(CameraDescription camera) async {
    if (_state.lifecycle == CameraLifecycleState.disposed) return;

    _cameraController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize().timeout(
        Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException("Timeout initialisation caméra");
        },
      );

      if (!mounted || _state.lifecycle == CameraLifecycleState.disposed) {
        await _cameraController?.dispose();
        return;
      }

      setState(() {
        _state.lifecycle = CameraLifecycleState.ready;
      });

      CameraLogger.log("✅ Caméra initialisée: ${camera.name}");
      _startFaceDetection();
    } catch (e) {
      CameraLogger.error('Erreur setup caméra: $e');
      _showError("Impossible d'initialiser la caméra");
      _state.lifecycle = CameraLifecycleState.uninitialized;
    }
  }

  void _startFaceDetection() {
    if (!_state.canStartStream || _cameraController == null) {
      CameraLogger.log("⚠️ Cannot start stream: lifecycle=${_state.lifecycle}, canStart=${_state.canStartStream}");
      return;
    }

    _state.isStreamingImages = true;
    _frameCounter = 0;

    try {
      _cameraController!.startImageStream((CameraImage image) async {
        if (_state.lifecycle != CameraLifecycleState.ready ||
            !_state.shouldProcessFrames) {
          return;
        }

        _frameCounter++;

        _lastStreamImageWidth = image.width;
        _lastStreamImageHeight = image.height;
        _lastStreamRotation = _getImageRotation();

        if (_frameCounter % FaceDetectionConfig.frameSkipCount != 0) return;

        if (_state.isProcessingFrame) return;
        _state.isProcessingFrame = true;

        try {
          if (_faceDetector != null) {
            final faces = await _detectFacesFromCameraImage(image)
                .timeout(FaceDetectionConfig.faceDetectionTimeout);

            if (_state.shouldProcessFrames && mounted) {
              _updateFeedback(faces);
            }
          }
        } catch (e) {
          if (_frameCounter % 30 == 0) {
            CameraLogger.log('⚠️ Erreur détection frame: $e');
          }
        } finally {
          _state.isProcessingFrame = false;
        }
      });

      CameraLogger.log("▶️ Détection démarrée");
    } catch (e) {
      CameraLogger.error('Erreur démarrage stream: $e');
      _state.isStreamingImages = false;
    }
  }

  Future<List<Face>> _detectFacesFromCameraImage(CameraImage image) async {
    try {
      if (image.planes.isEmpty) return [];

      final InputImageRotation rotation = _getImageRotation();

      final Uint8List bytes;
      final InputImageFormat format;
      final int bytesPerRow;

      if (Platform.isAndroid) {
        if (image.planes.length >= 3) {
          bytes = YUVConverter.convertYUV420ToNV21(image);
          format = InputImageFormat.nv21;
          bytesPerRow = image.width;
        } else {
          bytes = image.planes[0].bytes;
          format = InputImageFormat.yuv420;
          bytesPerRow = image.planes[0].bytesPerRow;
        }
      } else {
        bytes = image.planes[0].bytes;
        format = InputImageFormat.bgra8888;
        bytesPerRow = image.planes[0].bytesPerRow;
      }

      final metadata = InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: bytesPerRow,
      );

      final inputImage = InputImage.fromBytes(bytes: bytes, metadata: metadata);
      return await _faceDetector!.processImage(inputImage);
    } catch (e) {
      CameraLogger.error('Erreur ML Kit: $e');
      return [];
    }
  }

  InputImageRotation _getImageRotation() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return InputImageRotation.rotation0deg;
    }

    final camera = _cameraController!.description;
    final sensorOrientation = camera.sensorOrientation;

    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation) ??
          InputImageRotation.rotation0deg;
    }

    final deviceOrientation = _cameraController!.value.deviceOrientation;

    final rotationCompensation = <DeviceOrientation, int>{
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    }[deviceOrientation];

    if (rotationCompensation == null) return InputImageRotation.rotation0deg;

    int rotationDegrees;
    if (camera.lensDirection == CameraLensDirection.front) {
      rotationDegrees = (sensorOrientation + rotationCompensation) % 360;
    } else {
      rotationDegrees = (sensorOrientation - rotationCompensation + 360) % 360;
    }

    return InputImageRotationValue.fromRawValue(rotationDegrees) ??
        InputImageRotation.rotation0deg;
  }

  void _updateFeedback(List<Face> faces) {
    if (!mounted || _state.lifecycle != CameraLifecycleState.ready) return;

    final now = DateTime.now();
    if (_lastFeedbackUpdate != null &&
        now.difference(_lastFeedbackUpdate!) < FaceDetectionConfig.feedbackThrottle) {
      return;
    }
    _lastFeedbackUpdate = now;

    setState(() {
      if (faces.isEmpty) {
        _currentResult = FaceValidationResult.noFace();
        _transformer = null;
        return;
      }

      if (faces.length > 1) {
        _currentResult = FaceValidationResult.multipleFaces(faces.length);
        return;
      }

      final face = faces.first;

      if (_cameraController != null &&
          _previewWidth != null &&
          _previewHeight != null &&
          _previewWidth! > 0 &&
          _previewHeight! > 0) {

        final viewSize = Size(_previewWidth!, _previewHeight!);

        final rot = _lastStreamRotation ?? _getImageRotation();
        final rawW = _lastStreamImageWidth;
        final rawH = _lastStreamImageHeight;

        if (rawW == null || rawH == null) return;

        final bool swapped = (rot == InputImageRotation.rotation90deg ||
            rot == InputImageRotation.rotation270deg);

        final int imageWidth = swapped ? rawH : rawW;
        final int imageHeight = swapped ? rawW : rawH;

        _transformer = CoordinateTransformer(
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          viewSize: viewSize,
          isImageFlipped: !_state.isRearCamera,
        );

        final validator = FaceValidator(
          transformer: _transformer!,
          viewSize: viewSize,
        );

        _currentResult = validator.validate(face);
      }
    });
  }

  // ✅ FIX CRITIQUE: Stopper proprement le stream
  Future<void> _stopImageStream() async {
    if (_state.isStreamingImages && _cameraController != null) {
      try {
        await _cameraController!.stopImageStream();
        _state.isStreamingImages = false;
        CameraLogger.log("⏹️ Stream arrêté");
      } catch (e) {
        CameraLogger.error('Erreur arrêt stream: $e');
        _state.isStreamingImages = false;
      }
    }
  }

  Future<void> _turnOffFlash() async {
    if (_state.isFlashOn && _cameraController != null && _state.isRearCamera) {
      try {
        await _cameraController!.setFlashMode(FlashMode.off);
        if (mounted) {
          setState(() {
            _state.isFlashOn = false;
          });
        }
        CameraLogger.log("💡 Flash éteint");
      } catch (e) {
        CameraLogger.error('Erreur extinction flash: $e');
      }
    }
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null || !_state.isRearCamera) return;

    try {
      if (_state.isFlashOn) {
        await _cameraController!.setFlashMode(FlashMode.off);
      } else {
        await _cameraController!.setFlashMode(FlashMode.torch);
      }

      if (mounted) {
        setState(() {
          _state.isFlashOn = !_state.isFlashOn;
        });
      }

      CameraLogger.log("💡 Flash: ${_state.isFlashOn ? 'ON' : 'OFF'}");
    } catch (e) {
      CameraLogger.error('Erreur toggle flash: $e');
      _showError("Flash non disponible");
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _state.isSwitchingCamera) return;

    _state.isSwitchingCamera = true;

    try {
      await _stopImageStream();
      await _turnOffFlash();

      CameraDescription newCamera;
      if (_state.isRearCamera) {
        newCamera = _cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
          orElse: () => _cameras.first,
        );
      } else {
        newCamera = _cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => _cameras.first,
        );
      }

      if (mounted) {
        setState(() {
          _state.lifecycle = CameraLifecycleState.initializing;
          _currentResult = FaceValidationResult.noFace();
          _transformer = null;
        });
      }

      await _cameraController?.dispose();
      _cameraController = null;

      _state.isRearCamera = newCamera.lensDirection == CameraLensDirection.back;

      await Future.delayed(Duration(milliseconds: 100));
      await _setupCameraController(newCamera);

      CameraLogger.log("🔄 Caméra changée: ${_state.isRearCamera ? 'Arrière' : 'Avant'}");
    } catch (e) {
      CameraLogger.error('Erreur changement caméra: $e');
      _showError("Erreur changement caméra");
    } finally {
      _state.isSwitchingCamera = false;
    }
  }

  // ✅ FIX CRITIQUE: Gérer proprement la prise de photo
  Future<void> _takePhoto() async {
    if (!_currentResult.isValid && !_showDebugInfo) {
      _showError("Positionnez votre visage correctement");
      return;
    }

    if (_state.isProcessing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    try {
      setState(() {
        _state.isProcessing = true;
        _state.lifecycle = CameraLifecycleState.paused; // ✅ PAUSE la caméra
      });

      // ✅ Stopper le stream AVANT de prendre la photo
      await _stopImageStream();
      await Future.delayed(Duration(milliseconds: 100));

      final XFile image = await _cameraController!.takePicture()
          .timeout(Duration(seconds: 5));

      Uint8List imageBytes;
      if (kIsWeb) {
        imageBytes = await image.readAsBytes();
      } else {
        imageBytes = await ImageProcessor.compressImage(image.path);
      }

      imageBytes = await ImageProcessor.cropToIdentityFormat(imageBytes);

      final uploadedFile = FFUploadedFile(
        name: path.basename(image.path),
        bytes: imageBytes,
        height: 0,
        width: 0,
        blurHash: '',
      );

      if (!kIsWeb) {
        try {
          await File(image.path).delete();
        } catch (e) {
          CameraLogger.log('⚠️ Impossible de supprimer temp: $e');
        }
      }

      CameraLogger.log("📸 Photo prise, navigation vers preview...");

      // ✅ Navigation - la caméra reste en pause
      await widget.uploadPhotosAction([uploadedFile]);

      // ✅ Quand on revient ici, réactiver la caméra
      CameraLogger.log("🔙 Retour détecté, réactivation caméra");

      if (mounted && _state.lifecycle == CameraLifecycleState.paused) {
        setState(() {
          _state.lifecycle = CameraLifecycleState.ready;
          _currentResult = FaceValidationResult.noFace();
        });

        // Attendre un peu pour laisser l'UI se stabiliser
        await Future.delayed(Duration(milliseconds: 300));

        if (mounted && _state.lifecycle == CameraLifecycleState.ready) {
          _startFaceDetection();
        }
      }

    } catch (e) {
      CameraLogger.error('Erreur prise de photo: $e');
      _showError("Erreur lors de la capture");

      // En cas d'erreur, remettre en ready
      if (mounted) {
        setState(() {
          _state.lifecycle = CameraLifecycleState.ready;
          _currentResult = FaceValidationResult.noFace();
        });
        _startFaceDetection();
      }
    } finally {
      if (mounted) {
        setState(() {
          _state.isProcessing = false;
        });
      }
    }
  }

  Future<void> _openGallery() async {
    if (_state.isProcessing) return;

    // ✅ PAUSE la caméra pendant la sélection galerie
    _state.lifecycle = CameraLifecycleState.paused;
    await _stopImageStream();

    final ImagePicker picker = ImagePicker();

    try {
      setState(() {
        _state.isProcessing = true;
      });

      final XFile? image = await picker
          .pickImage(
            source: ImageSource.gallery,
            maxWidth: 1920,
            maxHeight: 1920,
            imageQuality: 90,
          )
          .timeout(
            Duration(seconds: 30),
            onTimeout: () => null,
          );

      if (image == null) {
        CameraLogger.log("📷 Sélection galerie annulée");

        // ✅ Réactiver la caméra si annulé
        if (mounted) {
          setState(() {
            _state.lifecycle = CameraLifecycleState.ready;
          });
          _startFaceDetection();
        }
        return;
      }

      Uint8List imageBytes;
      if (kIsWeb) {
        imageBytes = await image.readAsBytes();
      } else {
        imageBytes = await ImageProcessor.compressImage(image.path);
      }

      imageBytes = await ImageProcessor.cropToIdentityFormat(imageBytes);

      final uploadedFile = FFUploadedFile(
        name: path.basename(image.path),
        bytes: imageBytes,
        height: 0,
        width: 0,
        blurHash: '',
      );

      await widget.uploadPhotosAction([uploadedFile]);

      // ✅ Réactiver au retour
      if (mounted) {
        setState(() {
          _state.lifecycle = CameraLifecycleState.ready;
        });
        await Future.delayed(Duration(milliseconds: 300));
        _startFaceDetection();
      }

    } catch (e) {
      CameraLogger.error('Erreur galerie: $e');
      _showError("Erreur import photo");

      // ✅ Réactiver en cas d'erreur
      if (mounted) {
        setState(() {
          _state.lifecycle = CameraLifecycleState.ready;
        });
        _startFaceDetection();
      }
    } finally {
      if (mounted) {
        setState(() {
          _state.isProcessing = false;
        });
      }
    }
  }

  Future<void> _fetchGalleryAssets() async {
    try {
      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth) {
        CameraLogger.log("⚠️ Permission galerie refusée");
        return;
      }

      List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
      );

      if (albums.isNotEmpty) {
        final List<AssetEntity> recentAssets =
            await albums[0].getAssetListPaged(
          page: 0,
          size: 1,
        );

        Uint8List? thumbnail;
        if (recentAssets.isNotEmpty) {
          thumbnail = await recentAssets.first.thumbnailDataWithSize(
            ThumbnailSize(100, 100),
          );
        }

        if (mounted && _state.lifecycle != CameraLifecycleState.disposed) {
          setState(() {
            _galleryAssets = recentAssets;
            _galleryThumbnail = thumbnail;
          });
        }
      }
    } catch (e) {
      CameraLogger.log('⚠️ Erreur fetch galerie: $e');
    }
  }

  void _toggleDebugMode() {
    if (mounted) {
      setState(() {
        _showDebugInfo = !_showDebugInfo;
      });
      CameraLogger.log("🐛 Mode debug: ${_showDebugInfo ? 'ON' : 'OFF'}");
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline, color: Colors.white),
              SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: Colors.red[600],
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.all(20),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (_state.lifecycle == CameraLifecycleState.disposed ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    CameraLogger.log("📱 App lifecycle changed: $state");

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _pauseCamera();
        break;
      case AppLifecycleState.resumed:
        _resumeCamera();
        break;
      case AppLifecycleState.detached:
        _cleanupCamera();
        break;
    }
  }

  Future<void> _pauseCamera() async {
    CameraLogger.log("⏸️ Pause caméra (app lifecycle)");
    if (_state.lifecycle == CameraLifecycleState.ready) {
      _state.lifecycle = CameraLifecycleState.paused;
    }
    await _stopImageStream();
    await _turnOffFlash();
  }

  Future<void> _resumeCamera() async {
    CameraLogger.log("▶️ Reprise caméra (app lifecycle)");

    // ✅ Ne redémarrer QUE si on était en pause (pas si on est sur la preview)
    if (_state.lifecycle == CameraLifecycleState.paused && mounted) {
      setState(() {
        _state.lifecycle = CameraLifecycleState.ready;
      });
      await Future.delayed(Duration(milliseconds: 200));
      _startFaceDetection();
    }
  }

  Future<void> _cleanupCamera() async {
    CameraLogger.log("🧹 Nettoyage caméra");
    await _stopImageStream();
    await _turnOffFlash();
  }

  // ✅ FIX: Dispose propre sans async
  @override
  void dispose() {
    CameraLogger.log("🗑️ Disposing CameraWidget");
    _state.lifecycle = CameraLifecycleState.disposed;

    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();

    // ✅ Cleanup synchrone des ressources
    _stopImageStream().then((_) {
      _turnOffFlash().then((_) {
        _cameraController?.dispose();
        _faceDetector?.close();
      });
    }).catchError((e) {
      CameraLogger.error("Erreur dispose: $e");
    });

    super.dispose();
  }

  Widget _buildModernIconButton({
    required VoidCallback onPressed,
    required IconData icon,
    Color? backgroundColor,
    bool isActive = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        customBorder: CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isActive
                ? (backgroundColor ?? Colors.amber).withOpacity(0.9)
                : (backgroundColor ?? Colors.black).withOpacity(0.3),
            shape: BoxShape.circle,
            border: Border.all(
              color: isActive
                  ? Colors.white.withOpacity(0.8)
                  : Colors.white.withOpacity(0.2),
              width: isActive ? 2 : 1,
            ),
          ),
          child: Icon(
            icon,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _buildIdentityOverlay(double previewWidth, double previewHeight) {
    final bool isPortrait = previewHeight > previewWidth;
    final double ovalWidth = previewWidth * (isPortrait ? 0.70 : 0.50);
    final double ovalHeight = previewHeight * (isPortrait ? 0.50 : 0.70);

    return CustomPaint(
      size: Size(previewWidth, previewHeight),
      painter: MinimalGuidePainter(
        ovalWidth: ovalWidth,
        ovalHeight: ovalHeight,
      ),
    );
  }

  Widget _buildStatusIndicator() {
    return AnimatedPositioned(
      duration: Duration(milliseconds: 300),
      top: 100,
      left: 0,
      right: 0,
      child: Center(
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: _currentResult.color.withOpacity(0.5),
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_currentResult.icon,
                      color: _currentResult.color, size: 20),
                  SizedBox(width: 10),
                  Text(
                    _currentResult.message,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            if (_showDebugInfo && _currentResult.debugInfo.isNotEmpty) ...[
              SizedBox(height: 8),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Text(
                  _currentResult.debugInfo,
                  style: TextStyle(
                    color: Colors.yellow,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureButton() {
    final bool canCapture = _currentResult.isValid || _showDebugInfo;

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return GestureDetector(
          onTap: canCapture ? _takePhoto : null,
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.transparent,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_currentResult.isValid)
                  Transform.scale(
                    scale: _pulseAnimation.value,
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Color(0xFF00E676).withOpacity(0.5),
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: canCapture
                        ? (_currentResult.isValid
                            ? Color(0xFF00E676)
                            : Colors.orange)
                        : Colors.white.withOpacity(0.3),
                    border: Border.all(
                      color: Colors.white,
                      width: 4,
                    ),
                    boxShadow: canCapture
                        ? [
                            BoxShadow(
                              color: (_currentResult.isValid
                                      ? Color(0xFF00E676)
                                      : Colors.orange)
                                  .withOpacity(0.5),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ]
                        : [],
                  ),
                  child: Icon(
                    Icons.camera_alt,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGalleryButton() {
    return GestureDetector(
      onTap: _openGallery,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: _galleryThumbnail != null
              ? Image.memory(
                  _galleryThumbnail!,
                  fit: BoxFit.cover,
                )
              : Container(
                  color: Colors.grey[800],
                  child:
                      Icon(Icons.photo_library, color: Colors.white, size: 20),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double w = widget.width ?? constraints.maxWidth;
        double h = widget.height ?? constraints.maxHeight;

        if (!w.isFinite || w <= 0) w = constraints.maxWidth;
        if (!h.isFinite || h <= 0) h = constraints.maxHeight;

        if (!w.isFinite || w <= 0) w = MediaQuery.of(context).size.width;
        if (!h.isFinite || h <= 0) h = MediaQuery.of(context).size.height;

        _previewWidth = w;
        _previewHeight = h;

        return _buildCameraWidget(context, w, h);
      },
    );
  }

  Widget _buildCameraWidget(
      BuildContext context, double previewWidth, double previewHeight) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) {
          CameraLogger.log("🔙 PopScope invoked");
          await _stopImageStream();
          await _turnOffFlash();
        }
      },
      child: Stack(
        children: [
          if (_state.lifecycle == CameraLifecycleState.ready &&
              _cameraController != null)
            Center(
              child: ClipRect(
                child: SizedBox(
                  width: previewWidth,
                  height: previewHeight,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _cameraController!.value.previewSize!.height,
                      height: _cameraController!.value.previewSize!.width,
                      child: CameraPreview(_cameraController!),
                    ),
                  ),
                ),
              ),
            )
          else
            Container(
              width: previewWidth,
              height: previewHeight,
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                    SizedBox(height: 20),
                    Text(
                      "Initialisation...",
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
          if (_state.lifecycle == CameraLifecycleState.ready &&
              _cameraController != null)
            Center(
              child: SizedBox(
                width: previewWidth,
                height: previewHeight,
                child: _buildIdentityOverlay(previewWidth, previewHeight),
              ),
            ),
          if (_state.lifecycle == CameraLifecycleState.ready &&
              !_state.isProcessing)
            _buildStatusIndicator(),
          if (_state.isProcessing)
            Container(
              color: Colors.black.withOpacity(0.8),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 50,
                      height: 50,
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        strokeWidth: 3,
                      ),
                    ),
                    SizedBox(height: 20),
                    Text(
                      "Traitement...",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildModernIconButton(
                          onPressed: () async {
                            await _stopImageStream();
                            await _turnOffFlash();
                            Navigator.of(context).pop();
                          },
                          icon: Icons.close,
                        ),
                        Row(
                          children: [
                            if (FaceDetectionConfig.showDebugButton)
                              _buildModernIconButton(
                                onPressed: _toggleDebugMode,
                                icon: Icons.bug_report,
                                backgroundColor:
                                    _showDebugInfo ? Colors.yellow : null,
                                isActive: _showDebugInfo,
                              ),
                            if (FaceDetectionConfig.showDebugButton)
                              SizedBox(width: 12),
                            if (_state.isRearCamera)
                              _buildModernIconButton(
                                onPressed: _toggleFlash,
                                icon: _state.isFlashOn
                                    ? Icons.flash_on
                                    : Icons.flash_off,
                                backgroundColor:
                                    _state.isFlashOn ? Colors.amber : null,
                                isActive: _state.isFlashOn,
                              ),
                            if (_state.isRearCamera) SizedBox(width: 12),
                            if (_cameras.length > 1)
                              _buildModernIconButton(
                                onPressed: _switchCamera,
                                icon: Icons.flip_camera_ios,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Spacer(),
                  Padding(
                    padding: EdgeInsets.only(bottom: 40, left: 20, right: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildGalleryButton(),
                        _buildCaptureButton(),
                        SizedBox(width: 44),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// ============================================================================
/// PAINTER - Guide visuel
/// ============================================================================
class MinimalGuidePainter extends CustomPainter {
  final double ovalWidth;
  final double ovalHeight;

  MinimalGuidePainter({
    required this.ovalWidth,
    required this.ovalHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint darkPaint = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..style = PaintingStyle.fill;

    final Paint borderPaint = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final Paint cornerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    final double centerX = size.width / 2;
    final double centerY = size.height / 2;

    final Rect ovalRect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: ovalWidth,
      height: ovalHeight,
    );

    final Path path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, darkPaint);
    canvas.drawOval(ovalRect, borderPaint);

    final double cornerLength = 30;
    final double cornerOffset = 10;

    _drawCorner(canvas, cornerPaint, ovalRect.left, ovalRect.top, cornerLength,
        cornerOffset,
        isTopLeft: true);
    _drawCorner(canvas, cornerPaint, ovalRect.right, ovalRect.top, cornerLength,
        cornerOffset,
        isTopRight: true);
    _drawCorner(canvas, cornerPaint, ovalRect.left, ovalRect.bottom,
        cornerLength, cornerOffset,
        isBottomLeft: true);
    _drawCorner(canvas, cornerPaint, ovalRect.right, ovalRect.bottom,
        cornerLength, cornerOffset,
        isBottomRight: true);

    final Paint centerLinePaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final double eyeLineY = ovalRect.top + (ovalHeight * 0.42);
    canvas.drawLine(
      Offset(ovalRect.left + 20, eyeLineY),
      Offset(ovalRect.right - 20, eyeLineY),
      centerLinePaint,
    );
  }

  void _drawCorner(Canvas canvas, Paint paint, double x, double y,
      double length, double offset,
      {bool isTopLeft = false,
      bool isTopRight = false,
      bool isBottomLeft = false,
      bool isBottomRight = false}) {
    if (isTopLeft) {
      canvas.drawLine(Offset(x - offset, y + length),
          Offset(x - offset, y - offset), paint);
      canvas.drawLine(Offset(x - offset, y - offset),
          Offset(x + length, y - offset), paint);
    } else if (isTopRight) {
      canvas.drawLine(Offset(x + offset, y + length),
          Offset(x + offset, y - offset), paint);
      canvas.drawLine(Offset(x + offset, y - offset),
          Offset(x - length, y - offset), paint);
    } else if (isBottomLeft) {
      canvas.drawLine(Offset(x - offset, y - length),
          Offset(x - offset, y + offset), paint);
      canvas.drawLine(Offset(x - offset, y + offset),
          Offset(x + length, y + offset), paint);
    } else if (isBottomRight) {
      canvas.drawLine(Offset(x + offset, y - length),
          Offset(x + offset, y + offset), paint);
      canvas.drawLine(Offset(x + offset, y + offset),
          Offset(x - length, y + offset), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
