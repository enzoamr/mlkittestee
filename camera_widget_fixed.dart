// Automatic FlutterFlow imports
import '/backend/backend.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart'; // Imports other custom widgets
import '/custom_code/actions/index.dart'; // Imports custom actions
import '/flutter_flow/custom_functions.dart'; // Imports custom functions
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
/// CONFIGURATION SIMPLIFIÉE - Seuils réalistes pour photo d'identité
/// ============================================================================
class FaceDetectionConfig {
  // Taille du visage (ratio par rapport à la hauteur de l'écran)
  static const double minFaceSize = 0.15; // 15% de l'écran (CORRIGÉ: était 35%)
  static const double maxFaceSize = 0.50; // 50% de l'écran (CORRIGÉ: était 70%)

  // Tolérance de centrage (ratio par rapport aux dimensions de l'écran)
  static const double centerTolerance = 0.20; // 20% (CORRIGÉ: était 40% à cause du bug de viewSize)

  // Tolérance d'angle (degrés)
  static const double angleTolerance = 25.0; // 25° (ÉLARGI: était 20°)

  // Seuil d'ouverture des yeux
  static const double eyeOpenThreshold = 0.4; // 40% (ASSOUPLI: était 50%)
}

/// ============================================================================
/// HELPERS - Compression et crop
/// ============================================================================
Future<Uint8List> compressImage(String filePath) async {
  if (kIsWeb) {
    throw UnimplementedError(
        "La compression d'image n'est pas implémentée sur le web.");
  }

  try {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception("Le fichier n'existe pas: $filePath");
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
      debugPrint("⚠️ Compression échouée, utilisation de l'image originale");
      return await file.readAsBytes();
    }

    debugPrint("✅ Image compressée: ${compressedBytes.length} bytes");
    return compressedBytes;
  } catch (e) {
    debugPrint("❌ Erreur compression: $e");
    return await File(filePath).readAsBytes();
  }
}

Future<Uint8List> cropToIdentityFormat(Uint8List imageBytes) async {
  try {
    img.Image? originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) {
      debugPrint("⚠️ Impossible de décoder l'image pour le crop");
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
    debugPrint("✅ Image recadrée: ${cropWidth}x${cropHeight}");

    return Uint8List.fromList(encodedBytes);
  } catch (e) {
    debugPrint("❌ Erreur crop: $e");
    return imageBytes;
  }
}

/// ============================================================================
/// TRANSFORMATION COORDINATOR - Basé sur GraphicOverlay de Google!
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
      // L'image doit être croppée verticalement
      scaleFactor = viewSize.width / imageWidth;
      postScaleHeightOffset =
          (viewSize.width / imageAspectRatio - viewSize.height) / 2;
    } else {
      // L'image doit être croppée horizontalement
      scaleFactor = viewSize.height / imageHeight;
      postScaleWidthOffset =
          (viewSize.height * imageAspectRatio - viewSize.width) / 2;
    }

    debugPrint("🔧 TRANSFORMER:");
    debugPrint("  - Image: ${imageWidth}x${imageHeight}");
    debugPrint(
        "  - View: ${viewSize.width.toStringAsFixed(1)}x${viewSize.height.toStringAsFixed(1)}");
    debugPrint("  - Scale factor: ${scaleFactor.toStringAsFixed(4)}");
    debugPrint("  - Width offset: ${postScaleWidthOffset.toStringAsFixed(1)}");
    debugPrint(
        "  - Height offset: ${postScaleHeightOffset.toStringAsFixed(1)}");
    debugPrint("  - Flipped: $isImageFlipped");
  }

  double scale(double imagePixel) {
    return imagePixel * scaleFactor;
  }

  double translateX(double x) {
    if (isImageFlipped) {
      return viewSize.width - (scale(x) - postScaleWidthOffset);
    } else {
      return scale(x) - postScaleWidthOffset;
    }
  }

  double translateY(double y) {
    return scale(y) - postScaleHeightOffset;
  }
}

/// ============================================================================
/// RÉSULTAT DE VALIDATION
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
/// VALIDATEUR DE VISAGE
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

    // ========== LOGS DÉTAILLÉS - PARTIE 1: COORDONNÉES BRUTES ==========
    debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    debugPrint("📊 VALIDATION DE VISAGE - DÉBUT");
    debugPrint("🔹 Bounding Box (coordonnées image brutes):");
    debugPrint("   - Left: ${rect.left.toStringAsFixed(1)}");
    debugPrint("   - Top: ${rect.top.toStringAsFixed(1)}");
    debugPrint("   - Width: ${rect.width.toStringAsFixed(1)}");
    debugPrint("   - Height: ${rect.height.toStringAsFixed(1)}");
    debugPrint("   - Center X (image): ${(rect.left + rect.width / 2).toStringAsFixed(1)}");
    debugPrint("   - Center Y (image): ${(rect.top + rect.height / 2).toStringAsFixed(1)}");

    // Transformer les coordonnées - comme FaceGraphic.kt ligne 65-73
    final double faceCenterX =
        transformer.translateX(rect.left + rect.width / 2);
    final double faceCenterY =
        transformer.translateY(rect.top + rect.height / 2);
    final double faceHeight = transformer.scale(rect.height.toDouble());
    final double faceWidth = transformer.scale(rect.width.toDouble());

    // ========== LOGS DÉTAILLÉS - PARTIE 2: COORDONNÉES TRANSFORMÉES ==========
    debugPrint("🔹 Coordonnées transformées (écran):");
    debugPrint("   - Face Center X (écran): ${faceCenterX.toStringAsFixed(1)} px");
    debugPrint("   - Face Center Y (écran): ${faceCenterY.toStringAsFixed(1)} px");
    debugPrint("   - Face Width (écran): ${faceWidth.toStringAsFixed(1)} px");
    debugPrint("   - Face Height (écran): ${faceHeight.toStringAsFixed(1)} px");

    // 🐛 DEBUG NaN: Vérifier si les valeurs transformées sont valides
    if (faceCenterX.isNaN || faceCenterY.isNaN || faceHeight.isNaN || faceWidth.isNaN) {
      debugPrint("❌ ERROR: Coordonnées transformées contiennent NaN!");
      debugPrint("   - faceCenterX: $faceCenterX");
      debugPrint("   - faceCenterY: $faceCenterY");
      debugPrint("   - faceHeight: $faceHeight");
      debugPrint("   - faceWidth: $faceWidth");
      debugPrint("   - Transformer scaleFactor: ${transformer.scaleFactor}");
      debugPrint("   - Transformer postScaleWidthOffset: ${transformer.postScaleWidthOffset}");
      debugPrint("   - Transformer postScaleHeightOffset: ${transformer.postScaleHeightOffset}");
    }

    // Calculer les métriques
    final double screenCenterX = viewSize.width / 2;
    final double screenCenterY = viewSize.height / 2;

    final double faceRatio = faceHeight / viewSize.height;
    final double offsetX = (faceCenterX - screenCenterX).abs() / viewSize.width;
    final double offsetY =
        (faceCenterY - screenCenterY).abs() / viewSize.height;

    // ========== LOGS DÉTAILLÉS - PARTIE 3: MÉTRIQUES CALCULÉES ==========
    debugPrint("🔹 Centres d'écran:");
    debugPrint("   - Screen Center X: ${screenCenterX.toStringAsFixed(1)} px");
    debugPrint("   - Screen Center Y: ${screenCenterY.toStringAsFixed(1)} px");
    debugPrint("   - Screen Size: ${viewSize.width.toStringAsFixed(1)} x ${viewSize.height.toStringAsFixed(1)}");

    debugPrint("🔹 Ratios et Offsets calculés:");
    debugPrint("   - Face Ratio (height/screen): ${(faceRatio * 100).toStringAsFixed(2)}%");
    debugPrint("   - Offset X (distance horizontale): ${(offsetX * 100).toStringAsFixed(2)}%");
    debugPrint("   - Offset Y (distance verticale): ${(offsetY * 100).toStringAsFixed(2)}%");

    debugPrint("🔹 Seuils de validation:");
    debugPrint("   - Min Face Size: ${(FaceDetectionConfig.minFaceSize * 100).toStringAsFixed(0)}%");
    debugPrint("   - Max Face Size: ${(FaceDetectionConfig.maxFaceSize * 100).toStringAsFixed(0)}%");
    debugPrint("   - Center Tolerance: ${(FaceDetectionConfig.centerTolerance * 100).toStringAsFixed(0)}%");
    debugPrint("   - Angle Tolerance: ${FaceDetectionConfig.angleTolerance}°");

    String debugStr = "Size:${(faceRatio * 100).toStringAsFixed(0)}% ";
    debugStr += "X:${(offsetX * 100).toStringAsFixed(0)}% ";
    debugStr += "Y:${(offsetY * 100).toStringAsFixed(0)}% ";

    // ========== VÉRIFICATIONS AVEC LOGS ==========

    // Taille du visage
    debugPrint("🔍 CHECK 1: Taille du visage");
    debugPrint("   - Face ratio: ${(faceRatio * 100).toStringAsFixed(2)}%");
    debugPrint("   - Min requis: ${(FaceDetectionConfig.minFaceSize * 100).toStringAsFixed(0)}%");
    debugPrint("   - Max requis: ${(FaceDetectionConfig.maxFaceSize * 100).toStringAsFixed(0)}%");

    if (faceRatio < FaceDetectionConfig.minFaceSize) {
      debugPrint("   ❌ ÉCHEC: Visage trop petit (${(faceRatio * 100).toStringAsFixed(2)}% < ${(FaceDetectionConfig.minFaceSize * 100).toStringAsFixed(0)}%)");
      debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      return FaceValidationResult.error(
        "Rapprochez-vous",
        Icons.zoom_in_outlined,
        debugStr + "TROP_LOIN",
      );
    }
    debugPrint("   ✅ OK: Taille minimale respectée");

    if (faceRatio > FaceDetectionConfig.maxFaceSize) {
      debugPrint("   ❌ ÉCHEC: Visage trop grand (${(faceRatio * 100).toStringAsFixed(2)}% > ${(FaceDetectionConfig.maxFaceSize * 100).toStringAsFixed(0)}%)");
      debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      return FaceValidationResult.error(
        "Éloignez-vous",
        Icons.zoom_out_outlined,
        debugStr + "TROP_PRES",
      );
    }
    debugPrint("   ✅ OK: Taille maximale respectée");

    // Centrage horizontal
    debugPrint("🔍 CHECK 2: Centrage horizontal");
    debugPrint("   - Offset X: ${(offsetX * 100).toStringAsFixed(2)}%");
    debugPrint("   - Tolérance: ${(FaceDetectionConfig.centerTolerance * 100).toStringAsFixed(0)}%");

    if (offsetX > FaceDetectionConfig.centerTolerance) {
      debugPrint("   ❌ ÉCHEC: Décentré horizontalement (${(offsetX * 100).toStringAsFixed(2)}% > ${(FaceDetectionConfig.centerTolerance * 100).toStringAsFixed(0)}%)");
      debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      return FaceValidationResult.error(
        "Centrez horizontalement",
        Icons.center_focus_weak,
        debugStr + "DECENTRE_H",
      );
    }
    debugPrint("   ✅ OK: Centrage horizontal respecté");

    // Centrage vertical
    debugPrint("🔍 CHECK 3: Centrage vertical");
    debugPrint("   - Offset Y: ${(offsetY * 100).toStringAsFixed(2)}%");
    debugPrint("   - Tolérance: ${(FaceDetectionConfig.centerTolerance * 100).toStringAsFixed(0)}%");

    if (offsetY > FaceDetectionConfig.centerTolerance) {
      debugPrint("   ❌ ÉCHEC: Décentré verticalement (${(offsetY * 100).toStringAsFixed(2)}% > ${(FaceDetectionConfig.centerTolerance * 100).toStringAsFixed(0)}%)");
      debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      return FaceValidationResult.error(
        "Centrez verticalement",
        Icons.center_focus_weak,
        debugStr + "DECENTRE_V",
      );
    }
    debugPrint("   ✅ OK: Centrage vertical respecté");

    // Orientation
    final double yaw = face.headEulerAngleY ?? 0;
    final double roll = face.headEulerAngleZ ?? 0;

    debugStr += "Yaw:${yaw.toInt()}° Roll:${roll.toInt()}° ";

    debugPrint("🔍 CHECK 4: Orientation (Yaw)");
    debugPrint("   - Yaw: ${yaw.toStringAsFixed(1)}°");
    debugPrint("   - Tolérance: ±${FaceDetectionConfig.angleTolerance}°");

    if (yaw.abs() > FaceDetectionConfig.angleTolerance) {
      debugPrint("   ❌ ÉCHEC: Rotation horizontale trop grande (${yaw.toStringAsFixed(1)}° > ${FaceDetectionConfig.angleTolerance}°)");
      debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      return FaceValidationResult.error(
        "Regardez droit devant",
        Icons.crop_rotate,
        debugStr + "YAW",
      );
    }
    debugPrint("   ✅ OK: Yaw respecté");

    debugPrint("🔍 CHECK 5: Orientation (Roll)");
    debugPrint("   - Roll: ${roll.toStringAsFixed(1)}°");
    debugPrint("   - Tolérance: ±${FaceDetectionConfig.angleTolerance}°");

    if (roll.abs() > FaceDetectionConfig.angleTolerance) {
      debugPrint("   ❌ ÉCHEC: Inclinaison trop grande (${roll.toStringAsFixed(1)}° > ${FaceDetectionConfig.angleTolerance}°)");
      debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      return FaceValidationResult.error(
        "Tenez votre tête droite",
        Icons.crop_rotate,
        debugStr + "ROLL",
      );
    }
    debugPrint("   ✅ OK: Roll respecté");

    // Yeux ouverts
    debugPrint("🔍 CHECK 6: Yeux ouverts");
    if (face.leftEyeOpenProbability != null &&
        face.rightEyeOpenProbability != null) {
      final double leftEye = face.leftEyeOpenProbability!;
      final double rightEye = face.rightEyeOpenProbability!;

      debugPrint("   - Left Eye: ${(leftEye * 100).toStringAsFixed(1)}%");
      debugPrint("   - Right Eye: ${(rightEye * 100).toStringAsFixed(1)}%");
      debugPrint("   - Seuil: ${(FaceDetectionConfig.eyeOpenThreshold * 100).toStringAsFixed(0)}%");

      if (leftEye < FaceDetectionConfig.eyeOpenThreshold ||
          rightEye < FaceDetectionConfig.eyeOpenThreshold) {
        debugPrint("   ❌ ÉCHEC: Yeux fermés");
        debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        return FaceValidationResult.error(
          "Ouvrez les yeux",
          Icons.remove_red_eye_outlined,
          debugStr + "YEUX_FERMES",
        );
      }
      debugPrint("   ✅ OK: Yeux ouverts");
    } else {
      debugPrint("   ⚠️  SKIP: Données yeux non disponibles");
    }

    // Tout est bon!
    debugPrint("✅✅✅ TOUS LES CHECKS PASSÉS - PHOTO OK!");
    debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    return FaceValidationResult.success(debugStr + "✅");
  }
}

/// ============================================================================
/// CONVERSION YUV_420_888 vers NV21 - CORRECTE! Basée sur Google ML Kit
/// ============================================================================
/// Convertit YUV_420_888 (format caméra Android) vers NV21 (requis par ML Kit)
/// Basé sur BitmapUtils.java de Google ML Kit Vision Quickstart
Uint8List convertYUV420ToNV21(CameraImage image) {
  final int width = image.width;
  final int height = image.height;
  final int imageSize = width * height;
  final int uvSize = width * height ~/ 2;

  final Uint8List nv21 = Uint8List(imageSize + uvSize);

  // Plan Y (luminance) - Toujours non-entrelacé
  final yPlane = image.planes[0];
  final yBuffer = yPlane.bytes;
  final int yRowStride = yPlane.bytesPerRow;
  final int yPixelStride = yPlane.bytesPerPixel ?? 1;

  // Copier le plan Y
  int nv21Index = 0;
  for (int y = 0; y < height; y++) {
    int yBufferIndex = y * yRowStride;
    for (int x = 0; x < width; x++) {
      nv21[nv21Index++] = yBuffer[yBufferIndex];
      yBufferIndex += yPixelStride;
    }
  }

  // Plans U et V (chrominance)
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];
  final uBuffer = uPlane.bytes;
  final vBuffer = vPlane.bytes;

  final int uvWidth = width ~/ 2;
  final int uvHeight = height ~/ 2;
  final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
  final int uvRowStride = uPlane.bytesPerRow;

  // Vérifier si les plans UV sont déjà au format NV21
  // (même buffer, V avant U, pixelStride de 2)
  bool areUVPlanesNV21 = false;
  if (uvPixelStride == 2) {
    // Vérifier si les buffers partagent les mêmes données
    try {
      // Simple heuristique: si les tailles sont similaires et pixelStride = 2,
      // c'est probablement déjà entrelacé
      if (uBuffer.length == vBuffer.length && uBuffer.length >= uvSize) {
        areUVPlanesNV21 = true;
      }
    } catch (e) {
      areUVPlanesNV21 = false;
    }
  }

  if (areUVPlanesNV21) {
    // Optimisation: copie directe si déjà au format NV21
    // Format NV21 = V puis U entrelacés: VUVUVU...
    int uvIndex = imageSize;

    // Copier le premier V
    if (vBuffer.isNotEmpty) {
      nv21[uvIndex++] = vBuffer[0];
    }

    // Copier le reste depuis le buffer U (qui contient déjà U et V entrelacés)
    int uBufferIndex = 0;
    for (int i = 1; i < uvSize; i++) {
      if (uBufferIndex < uBuffer.length) {
        nv21[uvIndex++] = uBuffer[uBufferIndex];
        uBufferIndex++;
      }
    }
  } else {
    // Méthode standard: copier pixel par pixel
    // Format NV21 = V puis U alternés: VUVUVU...
    int uvIndex = imageSize;

    for (int y = 0; y < uvHeight; y++) {
      int vBufferIndex = y * uvRowStride;
      int uBufferIndex = y * uvRowStride;

      for (int x = 0; x < uvWidth; x++) {
        // NV21 = VU VU VU... (V en premier!)
        nv21[uvIndex++] = vBuffer[vBufferIndex];
        nv21[uvIndex++] = uBuffer[uBufferIndex];

        vBufferIndex += uvPixelStride;
        uBufferIndex += uvPixelStride;
      }
    }
  }

  return nv21;
}

/// ============================================================================
/// WIDGET PRINCIPAL - CameraWidget
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
  // Caméra
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isRearCamera = false;

  // Détection de visage
  FaceDetector? _faceDetector;
  bool _isStreamingImages = false;
  bool _isProcessingFrame = false;

  // État
  bool _isProcessing = false;
  bool _isDisposed = false;
  bool _isFlashOn = false;
  bool _isSwitchingCamera = false;

  // Feedback
  FaceValidationResult _currentResult = FaceValidationResult.noFace();

  // Galerie
  List<AssetEntity> _galleryAssets = [];
  Uint8List? _galleryThumbnail;

  // Debug
  static const bool _kShowDebugButton = true;
  bool _showDebugInfo = false;

  // Animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Transformation
  CoordinateTransformer? _transformer;

  // Throttling
  DateTime? _lastFeedbackUpdate;
  int _frameCounter = 0;

  // Preview size (pour coordinate transformation)
  double? _previewWidth;
  double? _previewHeight;

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
      debugPrint('❌ Erreur initialisation app: $e');
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
      debugPrint("✅ Face detector initialisé (Mode: ACCURATE)");
    } catch (e) {
      debugPrint("❌ Erreur init face detector: $e");
    }
  }

  Future<void> _initializeCamera() async {
    if (_isDisposed) return;

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

      _isRearCamera = initialCamera.lensDirection == CameraLensDirection.back;

      await _setupCameraController(initialCamera);
    } catch (e) {
      debugPrint('❌ Erreur initialisation caméra: $e');
      _showError("Erreur caméra");
    }
  }

  Future<void> _setupCameraController(CameraDescription camera) async {
    if (_isDisposed) return;

    _cameraController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize().timeout(
        Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException("Timeout initialisation caméra");
        },
      );

      final previewSize = _cameraController!.value.previewSize!;

      debugPrint("📷 Caméra initialisée:");
      debugPrint("  - Camera: ${camera.name}");
      debugPrint("  - Preview size: $previewSize");
      debugPrint("  - Direction: ${camera.lensDirection}");
      debugPrint("  - Sensor: ${camera.sensorOrientation}°");

      if (mounted && !_isDisposed) {
        setState(() {
          _isCameraInitialized = true;
        });
        _startFaceDetection();
      }
    } catch (e) {
      debugPrint('❌ Erreur setup caméra: $e');
      _showError("Impossible d'initialiser la caméra");
    }
  }

  void _startFaceDetection() {
    if (_isDisposed ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isStreamingImages) {
      return;
    }

    _isStreamingImages = true;
    _frameCounter = 0;

    try {
      _cameraController!.startImageStream((CameraImage image) async {
        if (_isDisposed || !_isStreamingImages) return;

        _frameCounter++;

        // Traiter seulement 1 frame sur 3
        if (_frameCounter % 3 != 0) return;

        if (_isProcessingFrame) return;
        _isProcessingFrame = true;

        try {
          if (_faceDetector != null) {
            final faces = await _detectFacesFromCameraImage(image)
                .timeout(Duration(milliseconds: 500));

            if (!_isDisposed && _isStreamingImages) {
              _updateFeedback(faces);
            }
          }
        } catch (e) {
          if (_frameCounter % 30 == 0) {
            debugPrint('⚠️ Erreur détection frame #$_frameCounter: $e');
          }
        } finally {
          _isProcessingFrame = false;
        }
      });

      debugPrint("▶️ Détection de visage démarrée");
    } catch (e) {
      debugPrint('❌ Erreur démarrage stream: $e');
      _isStreamingImages = false;
    }
  }

  Future<List<Face>> _detectFacesFromCameraImage(CameraImage image) async {
    try {
      final InputImageRotation rotation = _getImageRotation();

      // Convertir l'image selon la plateforme
      final Uint8List bytes;
      final InputImageFormat format;
      final int bytesPerRow;

      if (Platform.isAndroid) {
        // Sur Android: convertir YUV_420_888 vers NV21
        bytes = convertYUV420ToNV21(image);
        format = InputImageFormat.nv21;
        bytesPerRow = image.width;
      } else {
        // iOS - Format BGRA8888
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
      debugPrint('❌ Erreur ML Kit: $e');
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
      final rotation =
          InputImageRotationValue.fromRawValue(sensorOrientation) ??
              InputImageRotation.rotation0deg;
      return rotation;
    }

    // Android
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

    final rotation = InputImageRotationValue.fromRawValue(rotationDegrees) ??
        InputImageRotation.rotation0deg;

    return rotation;
  }

  void _updateFeedback(List<Face> faces) {
    if (!mounted || _isDisposed) return;

    // Throttling: mettre à jour max toutes les 200ms
    final now = DateTime.now();
    if (_lastFeedbackUpdate != null &&
        now.difference(_lastFeedbackUpdate!) < Duration(milliseconds: 200)) {
      return;
    }
    _lastFeedbackUpdate = now;

    setState(() {
      // Pas de visage
      if (faces.isEmpty) {
        _currentResult = FaceValidationResult.noFace();
        _transformer = null;
        return;
      }

      // Plusieurs visages
      if (faces.length > 1) {
        _currentResult = FaceValidationResult.multipleFaces(faces.length);
        return;
      }

      // Un seul visage - Valider!
      final face = faces.first;

      // ✅ RECRÉER le transformer à chaque fois avec les bonnes dimensions
      // (Important: utiliser la taille du preview, pas la taille de l'écran!)
      if (_cameraController != null && _previewWidth != null && _previewHeight != null) {
        // ⚠️ Sécurité: vérifier que les dimensions sont valides
        if (_previewWidth! <= 0 || _previewHeight! <= 0) {
          debugPrint("⚠️ Preview size invalide pour transformer: ${_previewWidth}x${_previewHeight}");
          _transformer = null;
          return;
        }

        final previewSize = _cameraController!.value.previewSize!;
        final rotation = _getImageRotation();

        // ✅ FIX: Utiliser la VRAIE taille de la vue du preview, pas la taille de l'écran!
        final viewSize = Size(_previewWidth!, _previewHeight!);

        // Déterminer les dimensions de l'image selon la rotation
        int imageWidth;
        int imageHeight;

        if (rotation == InputImageRotation.rotation90deg ||
            rotation == InputImageRotation.rotation270deg) {
          imageWidth = previewSize.height.toInt();
          imageHeight = previewSize.width.toInt();
        } else {
          imageWidth = previewSize.width.toInt();
          imageHeight = previewSize.height.toInt();
        }

        _transformer = CoordinateTransformer(
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          viewSize: viewSize,
          isImageFlipped: !_isRearCamera,
        );

        // Log de debug pour vérifier les dimensions (une fois toutes les 30 frames)
        if (_frameCounter % 30 == 0) {
          debugPrint("🔧 CoordinateTransformer créé:");
          debugPrint("   - Image size: ${imageWidth}x${imageHeight}");
          debugPrint("   - View size: ${viewSize.width.toStringAsFixed(1)}x${viewSize.height.toStringAsFixed(1)}");
          debugPrint("   - Rotation: $rotation");
          debugPrint("   - Flipped: ${!_isRearCamera}");
        }
      }

      // Valider le visage
      if (_transformer != null && _previewWidth != null && _previewHeight != null) {
        // ⚠️ Sécurité: vérifier que les dimensions sont valides (pas 0)
        if (_previewWidth! <= 0 || _previewHeight! <= 0) {
          debugPrint("⚠️ Preview size invalide: ${_previewWidth}x${_previewHeight}");
          return; // Ignorer cette frame
        }

        final validator = FaceValidator(
          transformer: _transformer!,
          viewSize: Size(_previewWidth!, _previewHeight!),
        );

        _currentResult = validator.validate(face);

        // Debug log tous les 30 frames
        if (_frameCounter % 30 == 0) {
          debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
          debugPrint("📊 VALIDATION FRAME #$_frameCounter");
          debugPrint("  - Message: ${_currentResult.message}");
          debugPrint("  - Valid: ${_currentResult.isValid}");
          debugPrint("  - Debug: ${_currentResult.debugInfo}");
          debugPrint("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        }
      }
    });
  }

  Future<void> _stopImageStream() async {
    if (_isStreamingImages && _cameraController != null) {
      try {
        await _cameraController!.stopImageStream();
        _isStreamingImages = false;
        debugPrint("⏹️ Stream arrêté");
      } catch (e) {
        debugPrint('⚠️ Erreur arrêt stream: $e');
        _isStreamingImages = false;
      }
    }
  }

  Future<void> _turnOffFlash() async {
    if (_isFlashOn && _cameraController != null && _isRearCamera) {
      try {
        await _cameraController!.setFlashMode(FlashMode.off);
        if (mounted && !_isDisposed) {
          setState(() {
            _isFlashOn = false;
          });
        }
        debugPrint("💡 Flash éteint");
      } catch (e) {
        debugPrint('⚠️ Erreur extinction flash: $e');
      }
    }
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null || !_isRearCamera) return;

    try {
      if (_isFlashOn) {
        await _cameraController!.setFlashMode(FlashMode.off);
      } else {
        await _cameraController!.setFlashMode(FlashMode.torch);
      }

      if (mounted && !_isDisposed) {
        setState(() {
          _isFlashOn = !_isFlashOn;
        });
      }

      debugPrint("💡 Flash: ${_isFlashOn ? 'ON' : 'OFF'}");
    } catch (e) {
      debugPrint('❌ Erreur toggle flash: $e');
      _showError("Flash non disponible");
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _isSwitchingCamera) return;

    _isSwitchingCamera = true;

    try {
      await _stopImageStream();
      await _turnOffFlash();

      CameraDescription newCamera;
      if (_isRearCamera) {
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

      if (mounted && !_isDisposed) {
        setState(() {
          _isCameraInitialized = false;
          _currentResult = FaceValidationResult.noFace();
          _transformer = null;
        });
      }

      await _cameraController?.dispose();
      _cameraController = null;

      _isRearCamera = newCamera.lensDirection == CameraLensDirection.back;

      await Future.delayed(Duration(milliseconds: 100));
      await _setupCameraController(newCamera);

      debugPrint("🔄 Caméra changée: ${_isRearCamera ? 'Arrière' : 'Avant'}");
    } catch (e) {
      debugPrint('❌ Erreur changement caméra: $e');
      _showError("Erreur changement caméra");
    } finally {
      _isSwitchingCamera = false;
    }
  }

  Future<void> _takePhoto() async {
    if (!_currentResult.isValid && !_showDebugInfo) {
      _showError("Positionnez votre visage correctement");
      return;
    }

    if (_isProcessing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    try {
      setState(() {
        _isProcessing = true;
      });

      await _stopImageStream();
      await Future.delayed(Duration(milliseconds: 100));

      final XFile image =
          await _cameraController!.takePicture().timeout(Duration(seconds: 5));

      Uint8List imageBytes;
      if (kIsWeb) {
        imageBytes = await image.readAsBytes();
      } else {
        imageBytes = await compressImage(image.path);
      }

      imageBytes = await cropToIdentityFormat(imageBytes);

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
          debugPrint('⚠️ Impossible de supprimer le fichier temp: $e');
        }
      }

      setState(() {
        _currentResult = FaceValidationResult.noFace();
      });

      await widget.uploadPhotosAction([uploadedFile]);

      if (mounted && !_isDisposed && _isCameraInitialized) {
        _startFaceDetection();
      }
    } catch (e) {
      debugPrint('❌ Erreur prise de photo: $e');
      _showError("Erreur lors de la capture");

      if (mounted && !_isDisposed && _isCameraInitialized) {
        setState(() {
          _currentResult = FaceValidationResult.noFace();
        });
        _startFaceDetection();
      }
    } finally {
      if (mounted && !_isDisposed) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _openGallery() async {
    if (_isProcessing) return;

    await _stopImageStream();

    final ImagePicker picker = ImagePicker();

    try {
      setState(() {
        _isProcessing = true;
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
        debugPrint("📷 Sélection galerie annulée");
        return;
      }

      Uint8List imageBytes;
      if (kIsWeb) {
        imageBytes = await image.readAsBytes();
      } else {
        imageBytes = await compressImage(image.path);
      }

      imageBytes = await cropToIdentityFormat(imageBytes);

      final uploadedFile = FFUploadedFile(
        name: path.basename(image.path),
        bytes: imageBytes,
        height: 0,
        width: 0,
        blurHash: '',
      );

      await widget.uploadPhotosAction([uploadedFile]);
    } catch (e) {
      debugPrint('❌ Erreur galerie: $e');
      _showError("Erreur import photo");
    } finally {
      if (mounted && !_isDisposed) {
        setState(() {
          _isProcessing = false;
        });

        if (_isCameraInitialized) {
          await Future.delayed(Duration(milliseconds: 500));
          _startFaceDetection();
        }
      }
    }
  }

  Future<void> _fetchGalleryAssets() async {
    try {
      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth) {
        debugPrint("⚠️ Permission galerie refusée");
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

        if (mounted && !_isDisposed) {
          setState(() {
            _galleryAssets = recentAssets;
            _galleryThumbnail = thumbnail;
          });
        }
      }
    } catch (e) {
      debugPrint('⚠️ Erreur fetch galerie: $e');
    }
  }

  void _toggleDebugMode() {
    if (mounted && !_isDisposed) {
      setState(() {
        _showDebugInfo = !_showDebugInfo;
      });
      debugPrint("🐛 Mode debug: ${_showDebugInfo ? 'ON' : 'OFF'}");
    }
  }

  void _showError(String message) {
    if (mounted && !_isDisposed) {
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

    if (_isDisposed ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        _pauseCamera();
        break;
      case AppLifecycleState.resumed:
        _resumeCamera();
        break;
      case AppLifecycleState.detached:
        _cleanupCamera();
        break;
      case AppLifecycleState.hidden:
        _pauseCamera();
        break;
    }
  }

  Future<void> _pauseCamera() async {
    debugPrint("⏸️ Pause caméra");
    await _stopImageStream();
    await _turnOffFlash();
  }

  Future<void> _resumeCamera() async {
    debugPrint("▶️ Reprise caméra");
    if (_isCameraInitialized && !_isDisposed) {
      _startFaceDetection();
    }
  }

  Future<void> _cleanupCamera() async {
    debugPrint("🧹 Nettoyage caméra");
    await _stopImageStream();
    await _turnOffFlash();
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);

    _stopImageStream().then((_) {
      _turnOffFlash().then((_) {
        _cameraController?.dispose();
        _faceDetector?.close();
        _pulseController.dispose();
      });
    });

    super.dispose();
  }

  /// ========================================================================
  /// UI BUILDERS
  /// ========================================================================

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
                ? (backgroundColor ?? Colors.amber).withValues(alpha: 0.9)
                : (backgroundColor ?? Colors.black).withValues(alpha: 0.3),
            shape: BoxShape.circle,
            border: Border.all(
              color: isActive
                  ? Colors.white.withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.2),
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

  Widget _buildIdentityOverlay(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double screenHeight = MediaQuery.of(context).size.height;

    final bool isPortrait = screenHeight > screenWidth;
    final double ovalWidth = screenWidth * (isPortrait ? 0.70 : 0.50);
    final double ovalHeight = screenHeight * (isPortrait ? 0.50 : 0.70);

    return CustomPaint(
      size: Size(screenWidth, screenHeight),
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
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: _currentResult.color.withValues(alpha: 0.5),
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
                  color: Colors.black.withValues(alpha: 0.7),
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
                          color: Color(0xFF00E676).withValues(alpha: 0.5),
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
                        : Colors.white.withValues(alpha: 0.3),
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
                                  .withValues(alpha: 0.5),
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
    final double previewWidth =
        widget.width ?? MediaQuery.of(context).size.width;
    final double previewHeight =
        widget.height ?? MediaQuery.of(context).size.height;

    // Stocker la taille du preview pour la transformation de coordonnées
    if (previewWidth > 0 && previewHeight > 0) {
      _previewWidth = previewWidth;
      _previewHeight = previewHeight;
    } else {
      debugPrint("⚠️ build() - Preview size invalide: ${previewWidth}x${previewHeight}");
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) {
          await _stopImageStream();
          await _turnOffFlash();
        }
      },
      child: Stack(
        children: [
          // Prévisualisation caméra
          if (_isCameraInitialized && _cameraController != null)
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

          // Overlay guide
          if (_isCameraInitialized && _cameraController != null)
            _buildIdentityOverlay(context),

          // Status indicator
          if (_isCameraInitialized && !_isProcessing) _buildStatusIndicator(),

          // Processing overlay
          if (_isProcessing)
            Container(
              color: Colors.black.withValues(alpha: 0.8),
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
                  // Barre du haut
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
                            if (_kShowDebugButton)
                              _buildModernIconButton(
                                onPressed: _toggleDebugMode,
                                icon: Icons.bug_report,
                                backgroundColor:
                                    _showDebugInfo ? Colors.yellow : null,
                                isActive: _showDebugInfo,
                              ),
                            if (_kShowDebugButton) SizedBox(width: 12),
                            if (_isRearCamera)
                              _buildModernIconButton(
                                onPressed: _toggleFlash,
                                icon: _isFlashOn
                                    ? Icons.flash_on
                                    : Icons.flash_off,
                                backgroundColor:
                                    _isFlashOn ? Colors.amber : null,
                                isActive: _isFlashOn,
                              ),
                            if (_isRearCamera) SizedBox(width: 12),
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
                  // Barre du bas
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
/// PAINTER - Guide visuel minimaliste
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
      ..color = Colors.black.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;

    final Paint borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
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
      ..color = Colors.white.withValues(alpha: 0.3)
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

/// ============================================================================
/// EXTENSION - InputImageRotation
/// ============================================================================
extension InputImageRotationValue on InputImageRotation {
  static InputImageRotation? fromRawValue(int value) {
    switch (value) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return null;
    }
  }
}
