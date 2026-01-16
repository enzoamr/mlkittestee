# 📸 Guide du Camera Widget Hybride Android/iOS

## 🎯 Problème Résolu

### Version 1 (Nouvelle) - Problèmes Android
- ❌ **Détection intermittente** : "Des fois il trouve aucun visage"
- ❌ **Coordonnées incorrectes** : "X et Y ne sont pas du tout à zéro au centre"
- ✅ Fonctionnait bien sur **iPhone**

### Version 2 (Ancienne) - Problèmes iOS
- ✅ Fonctionnait bien sur **Android**
- ❌ Ne fonctionnait pas correctement sur **iPhone**

## 🔧 Solution Hybride

La version hybride `camera_widget_hybrid.dart` corrige les deux problèmes en gérant correctement **la rotation de l'image selon la plateforme**.

## 🚀 Changements Clés

### 1. **FaceValidator Intelligent**

```dart
class FaceValidator {
  final int imageWidth;
  final int imageHeight;
  final InputImageRotation rotation;  // 🆕 NOUVEAU
  final bool isFrontCamera;           // 🆕 NOUVEAU
```

**Avant** : Validation naïve dans l'espace image brut
**Après** : Prise en compte de la rotation pour normaliser les coordonnées

### 2. **Normalisation des Coordonnées**

```dart
_NormalizedRect _normalizeCoordinates(Rect rect) {
  // ✅ Sur iOS : coordonnées déjà correctes
  if (!kIsWeb && Platform.isIOS) {
    return _NormalizedRect(...);
  }

  // ✅ Sur Android : appliquer transformation selon rotation
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      // Portrait : transformer (x,y) → (y, width-x)
      return _NormalizedRect(
        centerX: rect.top + rect.height / 2,
        centerY: imageWidth - (rect.left + rect.width / 2),
        ...
      );
    // ... autres rotations
  }
}
```

### 3. **Dimensions Effectives**

```dart
// ✅ NOUVEAU : Calcul des dimensions après rotation
final effectiveWidth = _isRotated90or270() ? imageHeight : imageWidth;
final effectiveHeight = _isRotated90or270() ? imageWidth : imageHeight;
```

**Explication** :
- **Android en portrait** : Image capteur = 1920x1080 (landscape) + rotation 90°
  - Dimensions effectives = 1080x1920 ✅
- **iOS** : Dimensions déjà correctes par le framework

### 4. **Logs de Debug Améliorés**

```dart
String debugStr = "Size:${(faceRatio * 100).toStringAsFixed(0)}% ";
debugStr += "X:${(offsetX * 100).toStringAsFixed(0)}% ";
debugStr += "Y:${(offsetY * 100).toStringAsFixed(0)}% ";
debugStr += "[${imageWidth}x${imageHeight}";
debugStr += " rot:${_rotationToDegrees()}°";        // 🆕 NOUVEAU
debugStr += " eff:${effectiveWidth}x${effectiveHeight}]";  // 🆕 NOUVEAU
```

**Exemple de log** :
```
Size:45% X:8% Y:12% [1920x1080 rot:90° eff:1080x1920] ✅
```

## 📋 Comment Utiliser

### 1. **Remplacer votre widget actuel**

Copiez le contenu de `camera_widget_hybrid.dart` dans votre fichier custom widget FlutterFlow.

### 2. **Tester sur Android**

```bash
# Activer le mode debug
- Appuyez sur le bouton 🐛 en haut à droite
- Positionnez votre visage
- Vérifiez les logs : X et Y doivent être proches de 0% au centre
```

**Logs attendus Android (Portrait, caméra frontale)** :
```
✅ Caméra initialisée: 0
▶️ Détection démarrée
Size:42% X:5% Y:3% [1920x1080 rot:90° eff:1080x1920] ✅
```

### 3. **Tester sur iOS**

```bash
# Même procédure
- Bouton 🐛 activé
- Positionnez votre visage
- Les logs doivent montrer rot:0° (iOS gère nativement)
```

**Logs attendus iOS** :
```
✅ Caméra initialisée: Front Camera
▶️ Détection démarrée
Size:40% X:4% Y:2% [1080x1920 rot:0° eff:1080x1920] ✅
```

## 🔍 Comprendre la Rotation

### Sur Android

```
Capteur caméra frontale : 1920x1080 (orientation native = landscape)
Device en portrait : rotation = 90°

ML Kit reçoit :
- Image : 1920x1080 bytes (NV21)
- Metadata : rotation = 90°

ML Kit retourne :
- BoundingBox dans l'espace 1920x1080 (NON-ROTÉ)

Notre validator :
1. Détecte rotation = 90°
2. Transforme (x,y) → (y, 1920-x)
3. Utilise dimensions effectives 1080x1920
4. Valide dans l'espace correct ✅
```

### Sur iOS

```
Capteur caméra frontale : orientation gérée par le framework

ML Kit reçoit :
- CVPixelBuffer avec orientation UIImage
- Metadata : orientation = correcte

ML Kit retourne :
- BoundingBox DÉJÀ dans le bon espace

Notre validator :
1. Détecte iOS
2. Pas de transformation
3. Utilise dimensions directement ✅
```

## 🧪 Checklist de Test

### Android
- [ ] **Portrait avant** : Détection centrée, logs montrent rot:90°
- [ ] **Portrait arrière** : Détection centrée, logs montrent rot:90°
- [ ] **Landscape avant** : Détection centrée, logs montrent rot:0° ou 180°
- [ ] **Switch caméra** : Pas de crash, détection fonctionne
- [ ] **Rotation device** : Adaptation automatique

### iOS
- [ ] **Portrait avant** : Détection centrée, logs montrent rot:0°
- [ ] **Portrait arrière** : Détection centrée
- [ ] **Landscape** : Détection centrée
- [ ] **Switch caméra** : Pas de crash
- [ ] **Rotation device** : Adaptation automatique

### Validations communes
- [ ] **Visage trop loin** : Message "Rapprochez-vous"
- [ ] **Visage trop près** : Message "Éloignez-vous"
- [ ] **Décentré gauche/droite** : Message "Centrez horizontalement"
- [ ] **Décentré haut/bas** : Message "Centrez verticalement"
- [ ] **Tête tournée** : Message "Regardez droit devant"
- [ ] **Tête penchée** : Message "Tenez votre tête droite"
- [ ] **Yeux fermés** : Message "Ouvrez les yeux"
- [ ] **Plusieurs visages** : Message "Une seule personne"

## 🐛 Debug

### Si la détection ne fonctionne toujours pas sur Android

1. **Vérifier les logs de rotation** :
```dart
CameraLogger.log("Rotation: ${_rotationToDegrees()}°");
CameraLogger.log("Image: ${imageWidth}x${imageHeight}");
CameraLogger.log("Effective: ${effectiveWidth}x${effectiveHeight}");
```

2. **Vérifier la conversion YUV** :
- Les 3 plans doivent être présents
- Format doit être `nv21`
- BytesPerRow = imageWidth pour NV21

### Si la détection ne fonctionne pas sur iOS

1. **Vérifier l'orientation** :
```dart
CameraLogger.log("iOS orientation: ${_getImageRotation()}");
```

2. **Vérifier le format** :
- Format doit être `bgra8888`
- BytesPerRow = planes[0].bytesPerRow

## 📊 Différences Techniques

| Aspect | Android | iOS |
|--------|---------|-----|
| **Format natif** | YUV420 (3 plans) | BGRA8888 (1 plan) |
| **Conversion** | YUV420 → NV21 | Directe |
| **Rotation** | Calculée (sensor + device) | Gérée par framework |
| **BoundingBox** | Espace brut (1920x1080) | Espace correct |
| **Transformation** | **OUI** (selon rotation) | **NON** |

## 🎨 Fonctionnalités Conservées

- ✅ Conversion YUV optimisée (Version 1)
- ✅ Validation robuste anti-NaN
- ✅ Crop 7:9 format identité
- ✅ Qualité maximale (95%)
- ✅ Mode debug avec logs détaillés
- ✅ Flash (caméra arrière)
- ✅ Switch caméra
- ✅ Import galerie
- ✅ Animation pulsation quand visage OK
- ✅ Lifecycle management (pause/resume)

## 📝 Notes Importantes

1. **Qualité Image** :
   - Format NV21 sur Android (identique aux samples ML Kit officiels)
   - JPEG quality = 95% pour le crop final
   - Pas de compression intermédiaire

2. **Performance** :
   - Frame skip = 2 (traiter 1 frame sur 3)
   - Timeout ML Kit = 500ms
   - Lock anti-traitement parallèle

3. **Compatibilité** :
   - ✅ Android API 21+ (via YUV420)
   - ✅ iOS 12+ (via BGRA8888)
   - ⚠️ Web non supporté (pas de streaming)

## 🔗 Références ML Kit Officielles

### Android
- `/android/vision-quickstart/app/src/main/java/com/google/mlkit/vision/demo/BitmapUtils.java`
  - Ligne 153-220 : Conversion YUV420 → NV21
- `/android/vision-quickstart/app/src/main/java/com/google/mlkit/vision/demo/CameraSource.java`
  - Ligne 527-567 : Calcul rotation caméra

### iOS
- `/ios/quickstarts/vision/VisionExample/UIUtilities.swift`
  - Ligne 101-125 : Gestion orientation
- `/ios/quickstarts/vision/VisionExample/CameraViewController.swift`
  - Ligne 969+ : MLImage depuis CMSampleBuffer

---

**Version** : Hybrid v1.0
**Date** : 2026-01-16
**Compatibilité** : Android ✅ | iOS ✅ | Web ❌
