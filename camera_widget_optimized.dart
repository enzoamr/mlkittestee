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

import 'index.dart';
import '/custom_code/widgets/index.dart';
import '/custom_code/actions/index.dart';
import '/flutter_flow/custom_functions.dart';

import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io' show File, Platform;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
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
  static const double minFaceSize = 0.25;
  static const double maxFaceSize = 0.60;
  static const double centerTolerance = 0.20;
  static const double angleTolerance = 20.0;
  static const double eyeOpenThreshold = 0.5;

  static const bool enableDebugLogs = true;
  static const bool showDebugButton = true;

  static const int frameSkipCount = 2;
  static const Duration feedbackThrottle = Duration(milliseconds: 100);
  static const Duration faceDetectionTimeout = Duration(milliseconds: 500);
}

/// ============================================================================
/// LOGGER
/// ============================================================================
class CameraLogger {
  static void log(String message) {
    if (FaceDetectionConfig.enableDebugLogs) {
      debugPrint(message);
    }
  }

  static void error(String message) {
    debugPrint("❌ $message");
  }
}

/// ============================================================================
/// IMAGE PROCESSOR - Simplifié (crop uniquement, qualité max)
/// ============================================================================
class ImageProcessor {
  /// Recadre l'image au format identité 7:9 (qualité maximale)
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

      final int offsetX = ((originalWidth - cropWidth) / 2).round().clamp(0, originalWidth - cropWidth);
      final int offsetY = ((originalHeight - cropHeight) / 2).round().clamp(0, originalHeight - cropHeight);

      img.Image croppedImage = img.copyCrop(
        originalImage,
        x: offsetX,
        y: offsetY,
        width: cropWidth,
        height: cropHeight,
      );

      // ✅ Qualité maximale (95) pour photo d'identité
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
/// YUV CONVERTER - Pour Android
/// ============================================================================
class YUVConverter {
  static Uint8List convertYUV420ToNV21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int imageSize = width * height;
    final int uvSize = width * height ~/ 2;

    final Uint8List nv21 = Uint8List(imageSize + uvSize);

    // Copier le plan Y
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

    // Copier les plans UV en format NV21 (VUVUVU...)
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uBuffer = uPlane.bytes;
    final vBuffer = vPlane.bytes;

    final int uvWidth = width ~/ 2;
    final int uvHeight = height ~/ 2;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final int uvRowStride = uPlane.bytesPerRow;

    int uvIndex = imageSize;

    for (int y = 0; y < uvHeight; y++) {
      int vBufferIndex = y * uvRowStride;
      int uBufferIndex = y * uvRowStride;

      for (int x = 0; x < uvWidth; x++) {
        if (vBufferIndex < vBuffer.length) {
          nv21[uvIndex++] = vBuffer[vBufferIndex];
        } else {
          nv21[uvIndex++] = 128;
        }

        if (uBufferIndex < uBuffer.length) {
          nv21[uvIndex++] = uBuffer[uBufferIndex];
        } else {
          nv21[uvIndex++] = 128;
        }

        vBufferIndex += uvPixelStride;
        uBufferIndex += uvPixelStride;
      }
    }

    return nv21;
  }
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

  factory FaceValidationResult.error(String message, IconData icon, String debugInfo) {
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
/// FACE VALIDATOR - ✅ SIMPLIFIÉ : Validation dans l'espace image
/// ============================================================================
class FaceValidator {
  final int imageWidth;
  final int imageHeight;

  FaceValidator({
    required this.imageWidth,
    required this.imageHeight,
  });

  FaceValidationResult validate(Face face) {
    final rect = face.boundingBox;

    // ✅ Calcul dans l'espace IMAGE (pas d'écran)
    final double faceCenterX = rect.left + rect.width / 2;
    final double faceCenterY = rect.top + rect.height / 2;
    final double faceHeight = rect.height;

    final double imageCenterX = imageWidth / 2;
    final double imageCenterY = imageHeight / 2;

    // ✅ Offsets normalisés (0 à 1) dans l'espace image
    final double offsetX = (faceCenterX - imageCenterX).abs() / imageWidth;
    final double offsetY = (faceCenterY - imageCenterY).abs() / imageHeight;
    final double faceRatio = faceHeight / imageHeight;

    // ✅ Validation des valeurs (évite les aberrations)
    if (offsetX.isNaN || offsetY.isNaN || faceRatio.isNaN ||
        offsetX > 1.0 || offsetY > 1.0 || faceRatio > 1.0) {
      CameraLogger.error(
        "⚠️ Valeurs invalides: offsetX=$offsetX, offsetY=$offsetY, faceRatio=$faceRatio"
      );
      return FaceValidationResult.noFace();
    }

    String debugStr = "Size:${(faceRatio * 100).toStringAsFixed(0)}% ";
    debugStr += "X:${(offsetX * 100).toStringAsFixed(0)}% ";
    debugStr += "Y:${(offsetY * 100).toStringAsFixed(0)}% ";
    debugStr += "[${imageWidth}x${imageHeight}]";

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
        debugStr + " YAW:${yaw.toStringAsFixed(1)}°",
      );
    }

    if (roll.abs() > FaceDetectionConfig.angleTolerance) {
      return FaceValidationResult.error(
        "Tenez votre tête droite",
        Icons.crop_rotate,
        debugStr + " ROLL:${roll.toStringAsFixed(1)}°",
      );
    }

    if (face.leftEyeOpenProbability != null && face.rightEyeOpenProbability != null) {
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
/// CAMERA STATE - ✅ SIMPLIFIÉ
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
  bool isProcessing = false; // ✅ Un seul flag suffit
  bool isFlashOn = false;
  bool isSwitchingCamera = false;
  bool isRearCamera = false;

  bool get canStartStream =>
      lifecycle == CameraLifecycleState.ready &&
      !isStreamingImages &&
      !isProcessing;

  bool get shouldProcessFrames =>
      lifecycle == CameraLifecycleState.ready && isStreamingImages && !isProcessing;
}

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

  final CameraState _state = CameraState();

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  FaceDetector? _faceDetector;

  FaceValidationResult _currentResult = FaceValidationResult.noFace();

  bool _showDebugInfo = false;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  DateTime? _lastFeedbackUpdate;
  int _frameCounter = 0;
  bool _isProcessingFrame = false; // ✅ Lock pour éviter traitement parallèle

  double? _previewWidth;
  double? _previewHeight;

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
    } catch (e) {
      CameraLogger.error('Erreur initialisation app: $e');
      if (mounted) {
        _showError("Erreur d'initialisation");
      }
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
        if (mounted) {
          _showError("Aucune caméra disponible");
        }
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
      if (mounted) {
        _showError("Erreur caméra");
      }
      _state.lifecycle = CameraLifecycleState.uninitialized;
    }
  }

  Future<void> _setupCameraController(CameraDescription camera) async {
    if (_state.lifecycle == CameraLifecycleState.disposed) return;

    final ImageFormatGroup imageFormat;
    if (kIsWeb) {
      imageFormat = ImageFormatGroup.jpeg;
    } else if (Platform.isAndroid) {
      imageFormat = ImageFormatGroup.yuv420;
    } else {
      imageFormat = ImageFormatGroup.bgra8888;
    }

    _cameraController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: imageFormat,
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
      if (mounted) {
        _showError("Impossible d'initialiser la caméra");
      }
      _state.lifecycle = CameraLifecycleState.uninitialized;
    }
  }

  void _startFaceDetection() {
    if (!_state.canStartStream || _cameraController == null) {
      CameraLogger.log("⚠️ Cannot start stream: lifecycle=${_state.lifecycle}");
      return;
    }

    _state.isStreamingImages = true;
    _frameCounter = 0;

    try {
      _cameraController!.startImageStream((CameraImage image) async {
        if (!_state.shouldProcessFrames) return;

        _frameCounter++;

        _lastStreamImageWidth = image.width;
        _lastStreamImageHeight = image.height;
        _lastStreamRotation = _getImageRotation();

        if (_frameCounter % FaceDetectionConfig.frameSkipCount != 0) return;

        // ✅ LOCK: Éviter traitement parallèle de frames
        if (_isProcessingFrame) return;
        _isProcessingFrame = true;

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
          // ✅ UNLOCK: Toujours libérer le lock (même si erreur)
          _isProcessingFrame = false;
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

      if (kIsWeb) {
        return [];
      } else if (Platform.isAndroid) {
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

    if (kIsWeb) {
      return InputImageRotation.rotation0deg;
    } else if (Platform.isIOS) {
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
        return;
      }

      if (faces.length > 1) {
        _currentResult = FaceValidationResult.multipleFaces(faces.length);
        return;
      }

      final face = faces.first;

      final rawW = _lastStreamImageWidth;
      final rawH = _lastStreamImageHeight;

      if (rawW == null || rawH == null) {
        CameraLogger.log("⚠️ Dimensions image non disponibles");
        return;
      }

      // ✅ ML Kit retourne boundingBox dans l'espace image BRUTE (non-rotée)
      // Donc on utilise les dimensions RAW, pas swappées
      final validator = FaceValidator(
        imageWidth: rawW,
        imageHeight: rawH,
      );

      _currentResult = validator.validate(face);
    });
  }

  Future<void> _stopImageStream() async {
    if (_state.isStreamingImages && _cameraController != null) {
      try {
        await _cameraController!.stopImageStream();
        _state.isStreamingImages = false;
        _isProcessingFrame = false; // ✅ Reset lock
        CameraLogger.log("⏹️ Stream arrêté");
      } catch (e) {
        CameraLogger.error('Erreur arrêt stream: $e');
        _state.isStreamingImages = false;
        _isProcessingFrame = false; // ✅ Reset lock même en cas d'erreur
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
      if (mounted) {
        _showError("Flash non disponible");
      }
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
        });
      }

      await _cameraController?.dispose();
      _cameraController = null;

      _state.isRearCamera = newCamera.lensDirection == CameraLensDirection.back;

      await Future.delayed(Duration(milliseconds: 100));

      if (!mounted) return;

      await _setupCameraController(newCamera);

      CameraLogger.log("🔄 Caméra changée: ${_state.isRearCamera ? 'Arrière' : 'Avant'}");
    } catch (e) {
      CameraLogger.error('Erreur changement caméra: $e');
      if (mounted) {
        _showError("Erreur changement caméra");
      }
    } finally {
      _state.isSwitchingCamera = false;
    }
  }

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
      if (!mounted) return;

      setState(() {
        _state.isProcessing = true;
        _state.lifecycle = CameraLifecycleState.paused;
      });

      await _stopImageStream();
      await Future.delayed(Duration(milliseconds: 100));

      if (!mounted) return;

      final XFile image = await _cameraController!.takePicture().timeout(Duration(seconds: 5));

      // ✅ Pas de compression, juste crop au ratio 7/9
      Uint8List imageBytes = await image.readAsBytes();

      if (!mounted) return;

      imageBytes = await ImageProcessor.cropToIdentityFormat(imageBytes);

      if (!mounted) return;

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

      if (!mounted) return;

      await widget.uploadPhotosAction([uploadedFile]);

      CameraLogger.log("✅ Navigation déclenchée");
    } catch (e) {
      CameraLogger.error('Erreur prise de photo: $e');
      if (mounted) {
        _showError("Erreur lors de la capture");
      }

      if (mounted && _state.lifecycle == CameraLifecycleState.paused) {
        setState(() {
          _state.lifecycle = CameraLifecycleState.ready;
          _state.isProcessing = false;
          _currentResult = FaceValidationResult.noFace();
        });

        await Future.delayed(Duration(milliseconds: 200));

        if (mounted && _state.lifecycle == CameraLifecycleState.ready) {
          _startFaceDetection();
        }
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

    _state.lifecycle = CameraLifecycleState.paused;
    await _stopImageStream();

    final ImagePicker picker = ImagePicker();

    try {
      if (!mounted) return;

      setState(() {
        _state.isProcessing = true;
      });

      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 95, // ✅ Qualité max
      ).timeout(
        Duration(seconds: 30),
        onTimeout: () => null,
      );

      if (!mounted) return;

      if (image == null) {
        CameraLogger.log("📷 Sélection galerie annulée");

        if (mounted) {
          setState(() {
            _state.lifecycle = CameraLifecycleState.ready;
            _state.isProcessing = false;
          });

          await Future.delayed(Duration(milliseconds: 200));

          if (mounted && _state.lifecycle == CameraLifecycleState.ready) {
            _startFaceDetection();
          }
        }
        return;
      }

      Uint8List imageBytes = await image.readAsBytes();

      if (!mounted) return;

      imageBytes = await ImageProcessor.cropToIdentityFormat(imageBytes);

      if (!mounted) return;

      final uploadedFile = FFUploadedFile(
        name: path.basename(image.path),
        bytes: imageBytes,
        height: 0,
        width: 0,
        blurHash: '',
      );

      await widget.uploadPhotosAction([uploadedFile]);

      CameraLogger.log("✅ Navigation galerie déclenchée");
    } catch (e) {
      CameraLogger.error('Erreur galerie: $e');
      if (mounted) {
        _showError("Erreur import photo");
      }
    } finally {
      if (mounted) {
        setState(() {
          _state.isProcessing = false;
        });
      }
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

    if (_state.lifecycle == CameraLifecycleState.paused && mounted) {
      setState(() {
        _state.lifecycle = CameraLifecycleState.ready;
      });

      await Future.delayed(Duration(milliseconds: 200));

      if (mounted && _state.lifecycle == CameraLifecycleState.ready) {
        _startFaceDetection();
      }
    }
  }

  Future<void> _cleanupCamera() async {
    CameraLogger.log("🧹 Nettoyage caméra");
    await _stopImageStream();
    await _turnOffFlash();
  }

  @override
  void dispose() {
    CameraLogger.log("🗑️ Disposing CameraWidget");
    _state.lifecycle = CameraLifecycleState.disposed;

    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();

    if (_state.isStreamingImages && _cameraController != null) {
      try {
        _cameraController!.stopImageStream();
        _state.isStreamingImages = false;
        _isProcessingFrame = false; // ✅ Reset lock
      } catch (e) {
        CameraLogger.error("Erreur arrêt stream dans dispose: $e");
      }
    }

    _cameraController?.dispose();
    _faceDetector?.close();

    super.dispose();
  }

  Widget _buildModernIconButton({
    required VoidCallback onPressed,
    required IconData icon,
    String? semanticLabel,
    Color? backgroundColor,
    bool isActive = false,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      enabled: true,
      child: Material(
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
            child: Icon(icon, color: Colors.white, size: 22),
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
            Semantics(
              liveRegion: true,
              label: _currentResult.message,
              child: Container(
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
                    Icon(_currentResult.icon, color: _currentResult.color, size: 20),
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
        return Semantics(
          button: true,
          label: canCapture ? 'Prendre une photo' : 'Positionnez votre visage pour activer',
          enabled: canCapture,
          child: GestureDetector(
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
                          ? (_currentResult.isValid ? Color(0xFF00E676) : Colors.orange)
                          : Colors.white.withOpacity(0.3),
                      border: Border.all(color: Colors.white, width: 4),
                      boxShadow: canCapture
                          ? [
                              BoxShadow(
                                color: (_currentResult.isValid ? Color(0xFF00E676) : Colors.orange)
                                    .withOpacity(0.5),
                                blurRadius: 20,
                                spreadRadius: 2,
                              ),
                            ]
                          : [],
                    ),
                    child: Icon(Icons.camera_alt, color: Colors.white, size: 28),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGalleryButton() {
    return Semantics(
      button: true,
      label: 'Ouvrir la galerie',
      enabled: true,
      child: GestureDetector(
        onTap: _openGallery,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Icon(Icons.photo_library, color: Colors.white, size: 20),
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

  Widget _buildCameraWidget(BuildContext context, double previewWidth, double previewHeight) {
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
          if ((_state.lifecycle == CameraLifecycleState.ready ||
                  _state.lifecycle == CameraLifecycleState.paused) &&
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
          if (_state.lifecycle == CameraLifecycleState.ready && _cameraController != null)
            Center(
              child: SizedBox(
                width: previewWidth,
                height: previewHeight,
                child: _buildIdentityOverlay(previewWidth, previewHeight),
              ),
            ),
          if (_state.lifecycle == CameraLifecycleState.ready && !_state.isProcessing)
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
                            if (mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          icon: Icons.close,
                          semanticLabel: 'Fermer la caméra',
                        ),
                        Row(
                          children: [
                            if (FaceDetectionConfig.showDebugButton)
                              _buildModernIconButton(
                                onPressed: _toggleDebugMode,
                                icon: Icons.bug_report,
                                semanticLabel:
                                    _showDebugInfo ? 'Désactiver le mode debug' : 'Activer le mode debug',
                                backgroundColor: _showDebugInfo ? Colors.yellow : null,
                                isActive: _showDebugInfo,
                              ),
                            if (FaceDetectionConfig.showDebugButton) SizedBox(width: 12),
                            if (_state.isRearCamera)
                              _buildModernIconButton(
                                onPressed: _toggleFlash,
                                icon: _state.isFlashOn ? Icons.flash_on : Icons.flash_off,
                                semanticLabel: _state.isFlashOn ? 'Éteindre le flash' : 'Allumer le flash',
                                backgroundColor: _state.isFlashOn ? Colors.amber : null,
                                isActive: _state.isFlashOn,
                              ),
                            if (_state.isRearCamera) SizedBox(width: 12),
                            if (_cameras.length > 1)
                              _buildModernIconButton(
                                onPressed: _switchCamera,
                                icon: Icons.flip_camera_ios,
                                semanticLabel: 'Changer de caméra',
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

    _drawCorner(canvas, cornerPaint, ovalRect.left, ovalRect.top, cornerLength, cornerOffset,
        isTopLeft: true);
    _drawCorner(canvas, cornerPaint, ovalRect.right, ovalRect.top, cornerLength, cornerOffset,
        isTopRight: true);
    _drawCorner(canvas, cornerPaint, ovalRect.left, ovalRect.bottom, cornerLength, cornerOffset,
        isBottomLeft: true);
    _drawCorner(canvas, cornerPaint, ovalRect.right, ovalRect.bottom, cornerLength, cornerOffset,
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

  void _drawCorner(Canvas canvas, Paint paint, double x, double y, double length, double offset,
      {bool isTopLeft = false,
      bool isTopRight = false,
      bool isBottomLeft = false,
      bool isBottomRight = false}) {
    if (isTopLeft) {
      canvas.drawLine(Offset(x - offset, y + length), Offset(x - offset, y - offset), paint);
      canvas.drawLine(Offset(x - offset, y - offset), Offset(x + length, y - offset), paint);
    } else if (isTopRight) {
      canvas.drawLine(Offset(x + offset, y + length), Offset(x + offset, y - offset), paint);
      canvas.drawLine(Offset(x + offset, y - offset), Offset(x - length, y - offset), paint);
    } else if (isBottomLeft) {
      canvas.drawLine(Offset(x - offset, y - length), Offset(x - offset, y + offset), paint);
      canvas.drawLine(Offset(x - offset, y + offset), Offset(x + length, y + offset), paint);
    } else if (isBottomRight) {
      canvas.drawLine(Offset(x + offset, y - length), Offset(x + offset, y + offset), paint);
      canvas.drawLine(Offset(x + offset, y + offset), Offset(x - length, y + offset), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
