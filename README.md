# CamControl

App iOS (SwiftUI) qui trouve les caméras IP de votre réseau WiFi et les pilote :
flux en direct, orientation PTZ, réglages d'image de la caméra, filtres de rendu
et instantanés.

Tout se passe en local. L'app parle directement aux caméras en ONVIF et RTSP —
aucun service tiers, aucun cloud, aucune donnée qui sort du réseau.

> **À n'utiliser que sur vos propres caméras, avec vos propres identifiants.**
> Accéder à un appareil qui ne vous appartient pas est illégal.

## Ce que fait l'app

**Bibliothèque** — vos caméras enregistrées, chacune avec sa dernière image
connue, son nom, son état. La liste survit aux relancements et aux changements
d'adresse IP : une caméra est identifiée par son numéro de série, donc un
nouveau bail DHCP ne crée pas de doublon et ne perd ni son nom ni ses
identifiants.

**Découverte** — quatre techniques en parallèle, parce qu'aucune ne suffit
seule. Un appel **WS-Discovery** en multicast, auquel les caméras ONVIF
répondent en une seconde. Une écoute **Bonjour**, qui attrape les caméras
annoncées sur un port qu'on n'aurait pas pensé à tester. Un **recensement par
résolution d'adresses** : chaque adresse du sous-réseau est sollicitée, puis la
table du noyau est relue — elle contient tout ce qui parle IP sur le segment,
même une caméra qui n'ouvre aucun port, avec son adresse matérielle et donc son
fabricant. Et un **balayage TCP**, court sur toutes les adresses, puis beaucoup
plus large sur celles qui se sont révélées habitées.

Ce qui reste non identifié est interrogé directement : une requête RTSP
`OPTIONS`, puis l'interface web. Le nom du modèle est presque toujours dans
l'en-tête `Server` ou dans le domaine d'authentification — y compris sur les
caméras qui ne parlent pas ONVIF du tout.

Les résultats s'affichent au fur et à mesure : une caméra trouvée à la première
seconde s'ajoute sans attendre les 250 adresses restantes.

**Lecteur** — vidéo plein écran, commandes flottantes qui s'effacent après
quelques secondes. Joystick analogique pour le PTZ (la distance au centre règle
la vitesse du moteur), zoom optique au palonnier, zoom numérique au pincement,
positions mémorisées, instantané vers Photos.

**Image** — deux couches, distinguées explicitement dans l'interface :
- le **rendu**, appliqué sur ce téléphone seulement, libre d'être annulé ;
- les **réglages caméra** (ONVIF Imaging), écrits dans l'appareil, qui changent
  ce que voient tous les autres clients et les enregistrements.

Les identifiants vont dans le Trousseau iOS, jamais dans la liste des caméras
(qui est du JSON en clair sur le disque).

## Compatibilité

Fonctionne avec toute caméra **ONVIF Profile S / T** — la grande majorité des
caméras IP vendues depuis ~2015 : Hikvision, Dahua, Reolink, Foscam, Amcrest,
Axis, ainsi que beaucoup de modèles Tapo et TP-Link. ONVIF doit parfois être
activé dans les réglages de la caméra, et demande souvent la création d'un
compte ONVIF distinct du compte de l'app du fabricant.

Les caméras qui passent tout par le cloud du fabricant (Ring, la plupart des
Nest et Wyze) apparaissent dans le scan mais ne sont pas pilotables : elles
n'exposent aucun protocole standard. Utilisez l'app du fabricant.

## Compiler

Il faut un **Mac** — un projet iOS ne se compile pas ailleurs.

```bash
brew install xcodegen
sudo gem install cocoapods

cd Cam
xcodegen generate     # génère CamControl.xcodeproj depuis project.yml
pod install           # récupère MobileVLCKit
open CamControl.xcworkspace
```

Dans Xcode : onglet **Signing & Capabilities** → choisissez votre équipe (un
compte Apple gratuit suffit pour installer sur votre propre appareil), branchez
un iPhone ou iPad, puis **Run**.

Au premier lancement, acceptez la demande **« Réseau local »** : sans elle,
iOS bloque silencieusement le scan et aucune caméra n'apparaît.

**Testez sur un appareil réel.** Le simulateur ne route ni le multicast ni le
balayage du sous-réseau correctement, et ne trouvera rien.

### Tests

```bash
xcodebuild test -workspace CamControl.xcworkspace -scheme CamControl \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

La suite couvre la logique pure : parsing SOAP/ONVIF, arithmétique de
sous-réseau, réponse du joystick, conversion des plages d'imagerie, fusion et
persistance des caméras. Rien qui demande une caméra réelle.

## Intégration continue (Codemagic)

`codemagic.yaml` définit deux workflows, volontairement séparés.

### 1. `CamControl · Compilation` — à lancer en premier

Compile l'app pour le simulateur, sans signature. **Ne demande aucun compte
Apple, aucun certificat, aucun identifiant enregistré.** Se déclenche à chaque
push sur `claude/app-construction-m7cuc2`.

C'est le workflow qui répond à la seule question qui compte au début : est-ce
que ça compile ? Le tester avant de s'occuper de la signature évite de
déboguer deux problèmes en même temps.

### 2. `CamControl · TestFlight` — à lancer à la main

Signe, construit et envoie sur TestFlight. La signature utilise les fichiers
déposés dans Codemagic (*Teams → Code signing identities*) plutôt que ceux
récupérés chez Apple, pour une raison qui n'est pas contournable : l'API App
Store Connect ne renvoie jamais la clé privée d'un certificat, seulement sa
partie publique. `app-store-connect fetch-signing-files --create` s'arrête donc
sur *« Cannot save Signing Certificates without certificate private key »* dès
qu'un certificat de distribution existe déjà. Les deux issues sont d'exporter la
clé dans un secret `CERTIFICATE_PRIVATE_KEY`, ou d'émettre un second certificat
contre une nouvelle clé — et Apple plafonne le nombre de certificats de
distribution, donc un build qui en crée un à chaque fois finit bloqué.

Quatre prérequis, tous côté Codemagic ou App Store Connect :

1. **Un compte Apple Developer payant** (99 €/an). Un compte gratuit ne permet
   ni la distribution App Store ni TestFlight.
2. **Une clé API App Store Connect** avec le rôle *App Manager*
   ([Users and Access → Integrations](https://appstoreconnect.apple.com/access/integrations/api)),
   ajoutée dans Codemagic sous *Teams → Integrations → Developer Portal* avec le
   nom exact **`PetMind ASC API`** — c'est la chaîne que `codemagic.yaml`
   référence, et elle est comparée caractère par caractère.
3. **Un certificat de distribution et un profil de provisionnement** dans
   *Teams → Code signing identities*, tous deux pour `BUNDLE_ID`. Le bouton
   *Generate* de Codemagic les fabrique à partir de la clé API ; le certificat
   déjà présent est réutilisé, il n'en faut pas un second. Attention : un profil
   porte un *nom* libre, qui n'est pas forcément l'identifiant qu'il couvre —
   c'est le champ **Bundle ID** qui doit correspondre à `BUNDLE_ID`.
4. **L'app créée dans App Store Connect** avec le même identifiant que
   `BUNDLE_ID` dans `codemagic.yaml` (`app.cam.io`). L'API App Store Connect ne
   permet pas de créer une fiche d'app : cette étape passe obligatoirement par
   l'interface web.

Le numéro de build vient du compteur Codemagic, donc aucune collision avec un
envoi précédent.

Les tests unitaires ne sont dans aucun des deux workflows : `xcodebuild test`
exige un nom de simulateur exact, qui change à chaque image Xcode, et un
renommage bloquerait une livraison pour une raison sans rapport avec le code.
Lancez-les localement (voir plus haut).

## Architecture

```
Sources/
  App/            point d'entrée, navigation racine
  DesignSystem/   tokens (couleur, type, espacement, motion), composants, radar
  Models/         Camera, ImagingSettings, PTZVector, ConnectionState
  Services/       ONVIFClient (actor), découverte, scan de ports, SOAP, filtres
  Stores/         CameraStore (persistance), CameraSession (une caméra ouverte),
                  ThumbnailStore (aperçus)
  Features/       Library, Discovery, Player, Controls, Settings
```

Quelques décisions qui ne se devinent pas à la lecture :

- **`ONVIFClient` est un `actor`.** Une caméra est une ressource sérialisée : le
  joystick, les curseurs d'image et le bouton d'instantané tirent dessus en même
  temps, et l'état négocié (URLs de service, jeton de profil, décalage
  d'horloge) ne doit pas être lu pendant qu'une autre tâche le remplit.

- **Les réponses sont parsées avec `XMLParser`, pas avec des expressions
  régulières.** Les fabricants utilisent des préfixes de namespace différents
  pour le même schéma, et les jetons de profil sont des *attributs* sur des
  éléments répétés. Le parseur travaille sur les noms locaux, donc le préfixe
  du vendeur disparaît avant que quoi que ce soit d'autre le voie.

- **L'horloge de la caméra est lue avant toute authentification.** Le digest
  WS-Security est rejeté si l'horodatage `Created` s'écarte de quelques minutes
  de l'heure de l'appareil, et les caméras grand public sans NTP sont
  couramment des années à côté.

- **Les valeurs d'imagerie sont normalisées en 0…1 dans l'UI, converties au
  dernier moment.** Les plages réelles varient d'un modèle à l'autre (0–100,
  0–255, -128…127) et sont lues via `GetOptions` ; écrire hors plage fait
  rejeter toute la requête.

- **Les commandes PTZ sont regroupées.** Un glissement émet des dizaines de
  mises à jour par seconde ; une caméra qui répondrait à chacune prendrait des
  secondes de retard sur le doigt.

- **Le RTSP est forcé en TCP.** RTP sur UDP perd des paquets sur un WiFi chargé
  et déchire l'image ; l'entrelacement sur la connexion TCP existante est ce qui
  rend le flux stable à la maison.

- **Le décodeur est surveillé.** VLC reste en état « playing » quand une caméra
  cesse d'émettre : la lecture est confirmée par l'avancée de l'horloge du média,
  pas par l'état déclaré.

- **Les adresses de flux sont vérifiées par une requête `DESCRIBE`, pas par le
  décodeur.** Sur une caméra sans ONVIF, l'app doit deviner où vit le flux. Lui
  faire essayer chaque adresse en la donnant au décodeur avait deux défauts :
  chaque mauvaise réponse coûtait un délai complet, et surtout un échec de
  lecture ne distingue pas une mauvaise adresse d'une caméra qui réclame un mot
  de passe. Les deux sont identiques. Une caméra à qui il ne manquait qu'un mot
  de passe parcourait donc les quinze adresses avant d'annoncer qu'aucun flux
  n'existait. `DESCRIBE` répond aux deux questions d'un coup : 200 signifie
  « c'est la bonne adresse », 401 signifie « demandez le mot de passe ».

- **L'authentification RTSP couvre les deux générations de digest.** Les caméras
  qui annoncent `qop` attendent le nonce client et le compteur dans le calcul
  (RFC 2617) ; les plus anciennes n'en annoncent pas et rejettent une requête
  portant des champs qu'elles n'ont pas demandés (RFC 2069). Se tromper là-dessus
  fait rejeter un mot de passe correct, ce qui est l'échec le plus déroutant que
  cette app puisse afficher.

- **Le multicast n'utilise pas `Network.framework`.** Envoyer une sonde vers un
  groupe multicast et lire les réponses unicast sur le même port éphémère ne
  demande pas de *rejoindre* le groupe, donc pas d'entitlement Apple — et le
  balayage TCP trouve les mêmes caméras si le multicast est bloqué.

- **La table de résolution d'adresses est lue, pas devinée.** Un datagramme UDP
  d'un octet vers chaque adresse force le noyau à résoudre le lien, et la table
  se lit ensuite par `sysctl`. C'est le seul canal qu'une caméra ne peut pas
  refuser : elle peut ignorer le multicast, ne rien annoncer et fermer tous ses
  ports, mais si elle parle IP, elle répond à la résolution d'adresse.

- **Les ports sont testés en deux passes.** La liste courte sur les mille
  adresses du sous-réseau, la liste longue seulement sur les quelques dizaines
  qui hébergent vraiment un appareil. Une seule passe large coûterait quinze
  fois plus de connexions pour le même résultat, et saturerait la radio du
  téléphone bien avant la fin.

- **Un refus d'authentification ONVIF compte comme une découverte.** Exiger que
  `GetDeviceInformation` réussisse sans identifiants écartait toutes les caméras
  configurées comme leur manuel le recommande — précisément celles dont le
  propriétaire a le mot de passe.

- **L'adresse matérielle sert à nommer, jamais à conclure.** Un préfixe
  Hikvision ou Dahua suffit à afficher un appareil qui n'a répondu à rien
  d'autre ; un préfixe TP-Link ou Xiaomi ne sert que d'étiquette, sans quoi la
  liste se remplirait de prises connectées et d'enceintes.

- **Les filtres de rendu utilisent les effets SwiftUI, pas `CALayer.filters`.**
  Cette propriété existe sur iOS mais n'y a aucun effet ; un filtre construit
  dessus ne ferait silencieusement rien sur la vidéo en direct.

## Limites connues

- **Pas d'enregistrement vidéo.** MobileVLCKit sait le faire, mais l'API varie
  selon les versions du pod et n'a pas pu être vérifiée ici. Mieux vaut pas de
  fonction qu'une fonction non testée.
- **Une seule caméra à la fois.** Pas encore de mur d'images multi-flux.
- **Media2 (ONVIF ver20) n'est pas utilisé** pour la récupération du flux : le
  service ver10 est accepté par tout ce qui est Profile S, et tous les appareils
  qui annoncent Media2 ne l'implémentent pas complètement.
- **HTTPS avec certificat auto-signé n'est pas contourné.** Les caméras parlent
  HTTP en clair sur le LAN — c'est le standard ONVIF — et l'exception ATS est
  limitée aux adresses privées. Désactiver la validation TLS aurait été plus
  simple et nettement moins sûr.
- Le projet n'a **pas pu être compilé** dans l'environnement où il a été écrit
  (pas de macOS) : la première compilation sur votre Mac est la première
  vérification réelle.
