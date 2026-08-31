# CamControl

App iOS (SwiftUI) qui scanne votre réseau WiFi local, détecte les caméras IP
qui s'y trouvent (protocole ONVIF), et permet de les contrôler : flux vidéo
en direct, PTZ (pan/tilt/zoom), réglages d'image matériels (luminosité,
contraste, saturation, netteté, contre-jour, WDR, vision nocturne) et filtres
visuels appliqués en direct dans l'app.

**⚠️ À utiliser uniquement sur votre propre réseau et vos propres caméras**,
avec vos propres identifiants. Le scan et le contrôle d'appareils qui ne vous
appartiennent pas sont illégaux.

## Ce que fait l'app

1. **Scan réseau** (`NetworkScanner.swift`) : détecte le sous-réseau WiFi de
   l'iPad/iPhone, puis teste en parallèle les ports habituels des caméras IP
   (80, 8080, 8000, 8899, 554, 37777, 9000, 443) sur toutes les adresses du
   réseau. Aucune requête ne sort jamais de votre réseau local.
2. **Découverte ONVIF** (`ONVIFDiscovery.swift`) : envoie en complément une
   sonde WS-Discovery en multicast (standard utilisé par la quasi-totalité
   des caméras IP du marché — Hikvision, Dahua, Reolink, Tapo compatibles
   ONVIF, TP-Link, Foscam, etc.) pour identifier précisément les caméras.
3. **Contrôle ONVIF** (`ONVIFClient.swift`) : une fois connecté avec vos
   identifiants, l'app peut :
   - récupérer l'URL du flux RTSP et l'afficher en direct (`RTSPPlayerView.swift`,
     via MobileVLCKit — iOS n'a pas de support RTSP natif) ;
   - piloter le moteur PTZ (déplacements continus, arrêt, préréglages) ;
   - lire et modifier les réglages d'image matériels de la caméra (service
     ONVIF *Imaging*) ;
   - récupérer un instantané JPEG et l'enregistrer dans Photos.
4. **Filtres visuels en direct** (`ImagingControlView.swift`,
   `RTSPPlayerView.swift`) : luminosité/contraste/saturation/netteté et
   préréglages (N&B, sépia, vif, froid, chaud) appliqués côté client sur
   l'image affichée — fonctionnent même si la caméra n'expose pas le service
   ONVIF Imaging.

Les identifiants de chaque caméra sont stockés dans le Trousseau iOS
(Keychain), jamais en clair dans le code ou dans `UserDefaults`.

## Compatibilité

- Fonctionne avec **toute caméra compatible ONVIF Profile S/T** (la grande
  majorité des caméras IP vendues depuis ~2015, y compris beaucoup de
  modèles Tapo, Reolink, Hikvision, Dahua, Foscam, Amcrest, etc., souvent
  après activation d'ONVIF dans les réglages de la caméra ou de son app).
- Les caméras détectées mais non-ONVIF (Ring, certains modèles Nest/Wyze qui
  passent tout par le cloud du fabricant) apparaissent dans la liste mais ne
  pourront pas être pilotées depuis cette app — utilisez alors l'app du
  fabricant.

## Prérequis pour compiler

- Un **Mac** avec Xcode 15+ (ce projet ne peut pas être compilé sans macOS).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) : `brew install xcodegen`
- [CocoaPods](https://cocoapods.org) : `sudo gem install cocoapods`
- Un iPhone/iPad réel connecté au même réseau WiFi que les caméras (le
  scan réseau et le multicast ne fonctionnent pas correctement dans le
  simulateur iOS).

## Compilation

```bash
cd CamControl   # dossier contenant project.yml
xcodegen generate
pod install
open CamControl.xcworkspace
```

Dans Xcode :
1. Sélectionnez le projet → l'onglet **Signing & Capabilities** → choisissez
   votre équipe de développement (compte Apple gratuit suffit pour un
   déploiement sur votre propre appareil).
2. Branchez votre iPhone/iPad, sélectionnez-le comme cible, puis **Run**.
3. Acceptez la demande d'autorisation « Réseau local » au premier lancement
   — sans elle, le scan ne peut pas fonctionner.

### À propos de la découverte ONVIF « instantanée »

En complément du scan de ports (la méthode principale, fiable et qui ne
demande aucune permission spéciale), l'app envoie une sonde WS-Discovery en
UDP vers l'adresse multicast standard 239.255.255.250:3702, via des sockets
BSD classiques plutôt que l'API multicast de Network.framework — ce qui
évite d'avoir besoin de l'entitlement Apple dédié aux flux multicast entrants.
Le fichier `CamControl.entitlements` le déclare quand même par précaution ;
si vous rencontrez un jour une limitation, vous pouvez en faire la demande
ici : https://developer.apple.com/contact/request/networking-multicast

**Ce n'est pas bloquant** : que cette sonde reçoive une réponse ou non, le
scan de ports TCP détecte les mêmes caméras.

## Notes techniques

- **PTZ / Imaging non supportés par une caméra** : l'app le détecte via
  `GetCapabilities` et masque simplement les contrôles correspondants
  (beaucoup de caméras fixes n'ont pas de moteur PTZ, par exemple).
- **RTSP** : MobileVLCKit gère nativement H.264/H.265, l'authentification
  intégrée à l'URL, et un cache réseau réduit (300 ms) pour une latence
  proche du temps réel sur réseau local.
- **Sécurité** : l'app parle uniquement en HTTP/RTSP en clair sur le réseau
  local, comme le font les caméras elles-mêmes — c'est le protocole standard
  ONVIF/RTSP, non un choix de cette app.
