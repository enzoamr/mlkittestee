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

import 'index.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io' show File, Platform;
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'dart:async';

/// ============================================================================
/// CONFIGURATION
/// ============================================================================
class CameraConfig {
  static const bool enableDebugLogs = true;
}

/// ============================================================================
/// LOGGER
/// ============================================================================
class CameraLogger {
  static void log(String message) {
    if (CameraConfig.enableDebugLogs) {
      debugPrint(message);
    }
  }

  static void error(String message) {
    debugPrint("❌ $message");
  }
}

/// ============================================================================
/// IMAGE PROCESSOR - Crop au format identité 7:9
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

      // Qualité maximale (95) pour photo d'identité
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
/// CAMERA STATE
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
  bool isProcessing = false;
  bool isFlashOn = false;
  bool isSwitchingCamera = false;
  bool isRearCamera = false;
}

class CameraWidget extends StatefulWidget {
  const CameraWidget({
    Key? key,
    this.width,
    this.height,
    required this.uploadPhotoAction,
  }) : super(key: key);

  final double? width;
  final double? height;
  final Future Function(FFUploadedFile photo) uploadPhotoAction;

  @override
  State<CameraWidget> createState() => _CameraWidgetState();
}

class _CameraWidgetState extends State<CameraWidget>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final CameraState _state = CameraState();

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializePulseAnimation();
    _initializeCamera();
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

      _state.isRearCamera =
          initialCamera.lensDirection == CameraLensDirection.back;

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
    } catch (e) {
      CameraLogger.error('Erreur setup caméra: $e');
      if (mounted) {
        _showError("Impossible d'initialiser la caméra");
      }
      _state.lifecycle = CameraLifecycleState.uninitialized;
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
        });
      }

      await _cameraController?.dispose();
      _cameraController = null;

      _state.isRearCamera = newCamera.lensDirection == CameraLensDirection.back;

      await Future.delayed(Duration(milliseconds: 100));

      if (!mounted) return;

      await _setupCameraController(newCamera);

      CameraLogger.log(
          "🔄 Caméra changée: ${_state.isRearCamera ? 'Arrière' : 'Avant'}");
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

      await Future.delayed(Duration(milliseconds: 100));

      if (!mounted) return;

      final XFile image =
          await _cameraController!.takePicture().timeout(Duration(seconds: 5));

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

      await widget.uploadPhotoAction(uploadedFile);

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
        });
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

    final ImagePicker picker = ImagePicker();

    try {
      if (!mounted) return;

      setState(() {
        _state.isProcessing = true;
      });

      final XFile? image = await picker
          .pickImage(
            source: ImageSource.gallery,
            maxWidth: 1920,
            maxHeight: 1920,
            imageQuality: 95,
          )
          .timeout(
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

      await widget.uploadPhotoAction(uploadedFile);

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
    await _turnOffFlash();
  }

  Future<void> _resumeCamera() async {
    CameraLogger.log("▶️ Reprise caméra (app lifecycle)");

    if (_state.lifecycle == CameraLifecycleState.paused && mounted) {
      setState(() {
        _state.lifecycle = CameraLifecycleState.ready;
      });
    }
  }

  Future<void> _cleanupCamera() async {
    CameraLogger.log("🧹 Nettoyage caméra");
    await _turnOffFlash();
  }

  @override
  void dispose() {
    CameraLogger.log("🗑️ Disposing CameraWidget");
    _state.lifecycle = CameraLifecycleState.disposed;

    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();

    _cameraController?.dispose();

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
      painter: IdentityGuidePainter(
        ovalWidth: ovalWidth,
        ovalHeight: ovalHeight,
      ),
    );
  }

  Widget _buildCaptureButton() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Semantics(
          button: true,
          label: 'Prendre une photo',
          enabled: true,
          child: GestureDetector(
            onTap: _takePhoto,
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
                  Transform.scale(
                    scale: _pulseAnimation.value,
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withOpacity(0.5),
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
                      color: Colors.white,
                      border: Border.all(color: Colors.white, width: 4),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withOpacity(0.5),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(Icons.camera_alt, color: Colors.black, size: 28),
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
          await _turnOffFlash();
        }
      },
      child: Stack(
        children: [
          // Prévisualisation caméra
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

          // Overlay du guide
          if (_state.lifecycle == CameraLifecycleState.ready &&
              _cameraController != null)
            Center(
              child: SizedBox(
                width: previewWidth,
                height: previewHeight,
                child: _buildIdentityOverlay(previewWidth, previewHeight),
              ),
            ),

          // Écran de traitement
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
            // Contrôles UI
            SafeArea(
              child: Column(
                children: [
                  // Barre supérieure
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildModernIconButton(
                          onPressed: () async {
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
                            if (_state.isRearCamera)
                              _buildModernIconButton(
                                onPressed: _toggleFlash,
                                icon: _state.isFlashOn
                                    ? Icons.flash_on
                                    : Icons.flash_off,
                                semanticLabel: _state.isFlashOn
                                    ? 'Éteindre le flash'
                                    : 'Allumer le flash',
                                backgroundColor:
                                    _state.isFlashOn ? Colors.amber : null,
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
                  // Barre inférieure
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
/// PAINTER - Guide visuel format identité
/// ============================================================================
class IdentityGuidePainter extends CustomPainter {
  final double ovalWidth;
  final double ovalHeight;

  IdentityGuidePainter({
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

    // Zone sombre autour du guide
    final Path path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, darkPaint);
    canvas.drawOval(ovalRect, borderPaint);

    final double cornerLength = 30;
    final double cornerOffset = 10;

    // Coins du guide
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

    // Ligne guide pour les yeux
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
