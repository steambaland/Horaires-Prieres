# Horaires de prières — iPad (iOS 12)

Application iPad plein écran : horloge géante, prochaine prière, horaires du jour.
Swift 5, UIKit 100 % programmatique, iOS 12.0 minimum (iPad Air 1 sous iOS 12.5.7).
Développée depuis Windows, compilée par GitHub Actions, installée avec Sideloadly.

## Arborescence

```
.github/workflows/build-ipa.yml   Compilation automatique de l'IPA
project.yml                       Configuration XcodeGen (génère le .xcodeproj)
Info.plist                        Configuration iPad, sans Storyboard
Sources/AppDelegate.swift         Fenêtre créée par code
Sources/ViewController.swift      Toute l'application (réglages en haut du fichier)
```

## Réglages

En haut de `Sources/ViewController.swift` :

| Constante | Valeur | Rôle |
|---|---|---|
| `city` | `"Massy"` | Ville |
| `country` | `"France"` | Pays |
| `method` | `12` | Méthode de calcul Aladhan (12 = UOIF) |
| `chouroukCompteCommeProchaine` | `false` | Le Chourouk est affiché mais jamais annoncé comme « prochaine prière » |

## Compiler

Chaque `push` sur `main` lance le workflow **Build IPA**. L'IPA se télécharge dans
**Actions → dernière exécution → Artifacts → HorairesPrieres-ipa** (un .zip qui contient `HorairesPrieres.ipa`).

## Installer

Ouvrir `HorairesPrieres.ipa` dans Sideloadly, iPad branché en USB, puis sur l'iPad :
**Réglages → Général → Gestion des appareils → faire confiance** à l'identifiant Apple utilisé.
Avec un identifiant Apple gratuit, la signature expire au bout de 7 jours : laisser Sideloadly la renouveler automatiquement.

## Version web (dossier `docs/`)

Même écran que l'app iPad, avec recherche de villes, favoris et météo (aujourd'hui + 3 jours).
Hébergée par GitHub Pages (Settings → Pages → Branch `main`, dossier `/docs`), installée sur l'iPad via
Safari → Partager → « Sur l'écran d'accueil ». Aucune signature, aucune expiration.

Réglages en haut du `<script>` de `docs/index.html` : `METHODE` (12 = UOIF), `CHOUROUK_PROCHAINE`, `VILLES_DEFAUT`.
Sources : Aladhan (horaires), Open-Meteo (météo et recherche de villes), sans clé API.
