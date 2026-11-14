//
//  ViewController.swift
//  HorairesPrieres
//
//  Écran unique : horloge géante, prochaine prière, horaires de la journée.
//  Swift 5 — UIKit 100 % programmatique — compatible iOS 12.0.
//  Aucune API postérieure à iOS 12 (pas de SwiftUI, Combine, async/await, SF Symbols).
//

import UIKit

// ============================================================================
// MARK: - RÉGLAGES (à modifier ici)
// ============================================================================

/// Ville affichée à l'écran et envoyée à l'API Aladhan.
private let city = "Massy"

/// Pays envoyé à l'API Aladhan.
private let country = "France"

/// Méthode de calcul Aladhan. 12 = UOIF (Musulmans de France).
private let method = 12

/// `false` : le Chourouk (lever du soleil) est affiché dans la rangée du bas
/// mais n'est jamais annoncé comme « prochaine prière ». Mettre `true` pour l'inclure.
private let chouroukCompteCommeProchaine = false

/// Actualisation normale des horaires : toutes les heures (en secondes).
private let intervalleActualisation: TimeInterval = 3600

/// Délai avant un nouvel essai quand le Wi-Fi est coupé (en secondes).
private let delaiNouvelEssai: TimeInterval = 60

// ============================================================================
// MARK: - Modèle
// ============================================================================

/// Les six horaires affichés, dans l'ordre de la journée.
/// La valeur brute est le nom du champ dans le JSON de l'API.
private enum Priere: String, CaseIterable {
    case fajr = "Fajr"
    case chourouk = "Sunrise"
    case dhouhr = "Dhuhr"
    case asr = "Asr"
    case maghrib = "Maghrib"
    case isha = "Isha"

    /// Nom affiché à l'écran.
    var nom: String {
        switch self {
        case .fajr: return "Fajr"
        case .chourouk: return "Chourouk"
        case .dhouhr: return "Dhouhr"
        case .asr: return "Asr"
        case .maghrib: return "Maghrib"
        case .isha: return "Isha"
        }
    }
}

/// Horaires d'une journée, tels qu'on les garde en mémoire (UserDefaults).
private struct JourPrieres: Codable {
    /// Date grégorienne au format « JJ-MM-AAAA » (sert de clé de cache).
    let cle: String
    /// Horaires nettoyés au format « HH:mm », indexés par nom de champ API (« Fajr », « Sunrise »…).
    let horaires: [String: String]
    let jourHegire: Int
    let moisHegire: Int
    let anneeHegire: Int
    /// Fuseau horaire de la ville renvoyé par l'API (ex. « Europe/Paris »).
    let fuseau: String?
}

/// Mois hégiriens en français (index 0 = mois n° 1).
private let moisHegiriens = [
    "Mouharram", "Safar", "Rabi’ al-Awwal", "Rabi’ ath-Thani",
    "Joumada al-Oula", "Joumada ath-Thania", "Rajab", "Chaabane",
    "Ramadan", "Chawwal", "Dhou al-Qi’da", "Dhou al-Hijja"
]

// ============================================================================
// MARK: - Décodage du JSON Aladhan (Codable)
// ============================================================================

/// L'API renvoie certains champs tantôt en texte ("4"), tantôt en nombre (6).
/// Ce type accepte les deux pour que le décodage ne casse jamais.
private struct ValeurSouple: Decodable {
    let texte: String

    init(from decoder: Decoder) throws {
        let conteneur = try decoder.singleValueContainer()
        if let chaine = try? conteneur.decode(String.self) {
            texte = chaine
        } else if let entier = try? conteneur.decode(Int.self) {
            texte = String(entier)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Texte ou nombre attendu"))
        }
    }

    var entier: Int? {
        return Int(texte.trimmingCharacters(in: .whitespaces))
    }
}

/// Seules les parties utiles de la réponse sont décrites ; le reste est ignoré.
private struct ReponseAladhan: Decodable {
    struct Donnees: Decodable {
        struct Dates: Decodable {
            struct Hegire: Decodable {
                struct Mois: Decodable {
                    let number: ValeurSouple
                }
                let day: ValeurSouple
                let month: Mois
                let year: ValeurSouple
            }
            struct Gregorien: Decodable {
                let date: String        // « 14-11-2026 »
            }
            let hijri: Hegire
            let gregorian: Gregorien
        }
        struct Meta: Decodable {
            let timezone: String?
        }
        let timings: [String: String]
        let date: Dates
        let meta: Meta?
    }
    let data: Donnees
}

// ============================================================================
// MARK: - Fonctions utilitaires (hors interface)
// ============================================================================

/// « 05:43 (CET) » → « 05:43 ». Renvoie `nil` si l'heure est illisible.
private func nettoyerHeure(_ brut: String?) -> String? {
    guard let brut = brut else { return nil }
    let sansSuffixe = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: " ").first ?? ""
    let morceaux = sansSuffixe.components(separatedBy: ":")
    guard morceaux.count >= 2,
          let heures = Int(morceaux[0]), let minutes = Int(morceaux[1]),
          (0...23).contains(heures), (0...59).contains(minutes) else { return nil }
    return String(format: "%02d:%02d", heures, minutes)
}

/// « 14-11-2026 » → « 20261114 » (pour trier les clés par date).
private func cleTriable(_ cle: String) -> String {
    let morceaux = cle.components(separatedBy: "-")
    guard morceaux.count == 3 else { return cle }
    return morceaux[2] + morceaux[1] + morceaux[0]
}

/// Transforme la réponse JSON de l'API en `JourPrieres`. Renvoie `nil` si elle est incomplète.
private func decoderReponse(_ data: Data) -> JourPrieres? {
    guard let reponse = try? JSONDecoder().decode(ReponseAladhan.self, from: data) else { return nil }
    let donnees = reponse.data

    // Les six horaires doivent tous être présents et lisibles.
    var horaires: [String: String] = [:]
    for priere in Priere.allCases {
        guard let heure = nettoyerHeure(donnees.timings[priere.rawValue]) else { return nil }
        horaires[priere.rawValue] = heure
    }

    // Date grégorienne « JJ-MM-AAAA », remise au format exact de nos clés.
    let nombres = donnees.date.gregorian.date.components(separatedBy: "-").compactMap { Int($0) }
    guard nombres.count == 3 else { return nil }
    let cle = String(format: "%02d-%02d-%04d", nombres[0], nombres[1], nombres[2])

    return JourPrieres(cle: cle,
                       horaires: horaires,
                       jourHegire: donnees.date.hijri.day.entier ?? 0,
                       moisHegire: donnees.date.hijri.month.number.entier ?? 0,
                       anneeHegire: donnees.date.hijri.year.entier ?? 0,
                       fuseau: donnees.meta?.timezone)
}

/// Télécharge les horaires d'une journée avec `URLSession.shared.dataTask`.
/// Le travail réseau et le décodage se font en arrière-plan ;
/// `fin` est appelé hors du fil principal, avec `nil` en cas d'échec.
private func telechargerHoraires(depuis url: URL, fin: @escaping (JourPrieres?) -> Void) {
    var requete = URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 20)
    requete.setValue("application/json", forHTTPHeaderField: "Accept")

    let tache = URLSession.shared.dataTask(with: requete) { data, reponse, erreur in
        let jour: JourPrieres?
        if erreur == nil,
           let http = reponse as? HTTPURLResponse, http.statusCode == 200,
           let data = data {
            jour = decoderReponse(data)
        } else {
            jour = nil
        }
        fin(jour)
    }
    tache.resume()
}

// ============================================================================
// MARK: - Couleurs
// ============================================================================

private extension UIColor {
    /// Couleur à partir d'un code hexadécimal, ex. `UIColor(hex: 0x0F5132)`.
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}

/// Palette à très haut contraste, sans blanc pur en fond (pas d'éblouissement).
private enum Palette {
    static let fond = UIColor(hex: 0xFAF8F5)          // crème doux
    static let texte = UIColor(hex: 0x141414)         // noir charbon
    static let secondaire = UIColor(hex: 0x4A4640)    // gris chaud foncé (dates, secondes)
    static let vert = UIColor(hex: 0x0F5132)          // vert émeraude profond
    static let blanc = UIColor(hex: 0xFFFFFF)
    static let dore = UIColor(hex: 0xFBBF24)          // accent doré
    static let carte = UIColor(hex: 0xFFFFFF)         // fond des petites cartes
    static let bordure = UIColor(hex: 0xCFC6B8)       // bordure des petites cartes
    static let alerte = UIColor(hex: 0x9A3412)        // message « hors connexion »
}

// ============================================================================
// MARK: - Petite carte d'une prière (bandeau inférieur)
// ============================================================================

private final class CartePriere: UIView {

    enum Style {
        case normale      // prière à venir
        case passee       // prière déjà passée : atténuée
        case prochaine    // prochaine prière : fond vert + bordure dorée épaisse
    }

    private let nomLabel = UILabel()
    private let heureLabel = UILabel()

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = 18
        layer.masksToBounds = true

        for label in [nomLabel, heureLabel] {
            label.textAlignment = .center
            label.numberOfLines = 1
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.baselineAdjustment = .alignCenters
            label.setContentHuggingPriority(UILayoutPriority(rawValue: 999), for: .vertical)
        }

        let pile = UIStackView(arrangedSubviews: [nomLabel, heureLabel])
        pile.axis = .vertical
        pile.alignment = .fill
        pile.spacing = 4
        pile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pile)

        NSLayoutConstraint.activate([
            pile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pile.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pile.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            pile.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        appliquer(.normale)
    }

    required init?(coder: NSCoder) {
        fatalError("Interface 100 % programmatique : pas de Storyboard ni de XIB.")
    }

    /// Met à jour le contenu et l'apparence de la carte.
    func configurer(nom: String, heure: String, style: Style) {
        nomLabel.text = nom
        heureLabel.text = heure
        appliquer(style)
    }

    /// Ajuste la taille des polices (appelé à chaque rotation de l'iPad).
    func reglerPolices(nom: CGFloat, heure: CGFloat) {
        nomLabel.font = UIFont.systemFont(ofSize: nom, weight: .bold)
        heureLabel.font = UIFont.monospacedDigitSystemFont(ofSize: heure, weight: .bold)
    }

    private func appliquer(_ style: Style) {
        switch style {
        case .normale, .passee:
            backgroundColor = Palette.carte
            layer.borderWidth = 2
            layer.borderColor = Palette.bordure.cgColor
            nomLabel.textColor = Palette.texte
            heureLabel.textColor = Palette.texte
            alpha = (style == .passee) ? 0.45 : 1.0
        case .prochaine:
            backgroundColor = Palette.vert
            layer.borderWidth = 6
            layer.borderColor = Palette.dore.cgColor
            nomLabel.textColor = Palette.dore
            heureLabel.textColor = Palette.blanc
            alpha = 1.0
        }
    }
}

// ============================================================================
// MARK: - État calculé à chaque seconde
// ============================================================================

private struct Etat {
    /// Journée affichée dans la rangée du bas (aujourd'hui, ou demain après Isha).
    var jour: JourPrieres?
    /// `true` après Isha : la rangée du bas montre les horaires du lendemain.
    var estDemain = false
    /// `true` si l'on affiche les horaires d'un autre jour faute de connexion.
    var approximatif = false
    var prochaine: Priere?
    var dateProchaine: Date?
    var passees = Set<Priere>()
}

// ============================================================================
// MARK: - Contrôleur principal
// ============================================================================

final class ViewController: UIViewController {

    // MARK: Données

    /// Horaires connus, indexés par date « JJ-MM-AAAA ». Copie persistante dans UserDefaults.
    private var cache: [String: JourPrieres] = [:]
    private let cleStockage = "horaires.cache.v1"

    /// Fuseau de la ville (fourni par l'API). Sert à l'horloge, aux dates et aux horaires.
    private var fuseau = TimeZone.current {
        didSet {
            calendrier.timeZone = fuseau
            formateurDate.timeZone = fuseau
            formateurHeure.timeZone = fuseau
        }
    }

    private var calendrier: Calendar = {
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.locale = Locale(identifier: "fr_FR")
        return calendrier
    }()

    /// Date grégorienne en français, ex. « samedi 14 novembre 2026 ».
    private let formateurDate: DateFormatter = {
        let formateur = DateFormatter()
        formateur.calendar = Calendar(identifier: .gregorian)
        formateur.locale = Locale(identifier: "fr_FR")
        formateur.dateFormat = "EEEE d MMMM yyyy"
        return formateur
    }()

    private let formateurHeure: DateFormatter = {
        let formateur = DateFormatter()
        formateur.calendar = Calendar(identifier: .gregorian)
        formateur.locale = Locale(identifier: "fr_FR")
        formateur.dateFormat = "HH:mm"
        return formateur
    }()

    // MARK: Suivi des actualisations

    private var requetesEnCours = 0
    private var echecPendantLeCycle = false
    private var horsLigne = false
    private var actualisationDemandee = false
    /// Instant du dernier essai (horloge interne `systemUptime`, insensible aux changements d'heure).
    private var dernierEssai: TimeInterval = -1_000_000
    private var heureDernierSucces: Date?

    private var minuteur: Timer?
    private var observateurs: [NSObjectProtocol] = []
    private var cleJourCourant: String?
    private var signatureAffichee = ""
    private var tailleAppliquee = CGSize.zero

    // MARK: Vues

    private let pilePrincipale = UIStackView()

    // 1. Bandeau supérieur
    private let bandeau = UIStackView()
    private let villeLabel = UILabel()
    private let dateGregLabel = UILabel()
    private let dateHegireLabel = UILabel()

    // 2. Zone centrale
    private let zoneCentrale = UIStackView()
    private let horlogeLabel = UILabel()
    private let carteProchaine = UIView()
    private let pileProchaine = UIStackView()
    private let titreProchaineLabel = UILabel()
    private let nomProchaineLabel = UILabel()
    private let heureProchaineLabel = UILabel()
    private let resteLabel = UILabel()
    private var largeurCarteProchaine: NSLayoutConstraint?

    // 3. Bandeau inférieur
    private let sectionBas = UIStackView()
    private let titreJourLabel = UILabel()
    private let grille = UIStackView()
    private let rangeeHaut = UIStackView()
    private let rangeeBas = UIStackView()
    private var cartes: [CartePriere] = []

    // Ligne d'état (connexion, dernière mise à jour)
    private let etatLabel = UILabel()

    // Polices de l'horloge (recalculées à chaque rotation)
    private var policeHorloge = UIFont.monospacedDigitSystemFont(ofSize: 144, weight: .bold)
    private var policeSecondes = UIFont.monospacedDigitSystemFont(ofSize: 58, weight: .semibold)

    // MARK: Cycle de vie

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.fond

        // Écran toujours allumé.
        UIApplication.shared.isIdleTimerDisabled = true

        construireInterface()
        chargerCache()
        observerLeSysteme()
        demarrerHorloge()

        // Premier affichage immédiat (avec le cache s'il existe) ; `tic()` lance aussi le téléchargement.
        rafraichirTout()
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Rotation ou premier affichage : on adapte la disposition et les tailles de police.
        let taille = view.bounds.size
        if taille != tailleAppliquee && taille.width > 0 && taille.height > 0 {
            tailleAppliquee = taille
            appliquerMiseEnPage(taille)
        }
    }

    // MARK: Construction de l'interface (Auto Layout, sans Storyboard)

    private func preparer(_ label: UILabel, couleur: UIColor, alignement: NSTextAlignment) {
        label.textColor = couleur
        label.textAlignment = alignement
        label.numberOfLines = 1
        // Filet de sécurité : si un texte est trop large, il rétrécit au lieu d'être coupé.
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.baselineAdjustment = .alignCenters
        // Les textes gardent leur hauteur naturelle : seule la zone centrale s'étire.
        label.setContentHuggingPriority(UILayoutPriority(rawValue: 999), for: .vertical)
    }

    private func construireInterface() {

        // ---------- 1. Bandeau supérieur : ville à gauche, dates à droite ----------
        preparer(villeLabel, couleur: Palette.texte, alignement: .left)
        villeLabel.text = city
        villeLabel.setContentHuggingPriority(UILayoutPriority(rawValue: 1), for: .horizontal)
        villeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        preparer(dateGregLabel, couleur: Palette.texte, alignement: .right)
        preparer(dateHegireLabel, couleur: Palette.secondaire, alignement: .right)
        for label in [dateGregLabel, dateHegireLabel] {
            label.text = " "
            label.setContentHuggingPriority(UILayoutPriority(rawValue: 750), for: .horizontal)
            label.setContentCompressionResistancePriority(UILayoutPriority(rawValue: 760), for: .horizontal)
        }

        let pileDates = UIStackView(arrangedSubviews: [dateGregLabel, dateHegireLabel])
        pileDates.axis = .vertical
        pileDates.alignment = .fill
        pileDates.spacing = 2

        bandeau.axis = .horizontal
        bandeau.alignment = .fill
        bandeau.distribution = .fill
        bandeau.spacing = 16
        bandeau.addArrangedSubview(villeLabel)
        bandeau.addArrangedSubview(pileDates)

        // ---------- 2. Zone centrale : horloge + carte « prochaine prière » ----------
        horlogeLabel.textAlignment = .center
        horlogeLabel.numberOfLines = 1
        horlogeLabel.adjustsFontSizeToFitWidth = true
        horlogeLabel.minimumScaleFactor = 0.4
        horlogeLabel.baselineAdjustment = .alignCenters
        // L'horloge absorbe l'espace libre (priorités très basses).
        horlogeLabel.setContentHuggingPriority(UILayoutPriority(rawValue: 1), for: .horizontal)
        horlogeLabel.setContentHuggingPriority(UILayoutPriority(rawValue: 1), for: .vertical)
        horlogeLabel.setContentCompressionResistancePriority(UILayoutPriority(rawValue: 250), for: .horizontal)

        carteProchaine.backgroundColor = Palette.vert
        carteProchaine.layer.cornerRadius = 28
        carteProchaine.layer.masksToBounds = true

        preparer(titreProchaineLabel, couleur: Palette.dore, alignement: .center)
        preparer(nomProchaineLabel, couleur: Palette.blanc, alignement: .center)
        preparer(heureProchaineLabel, couleur: Palette.blanc, alignement: .center)
        preparer(resteLabel, couleur: Palette.dore, alignement: .center)
        titreProchaineLabel.text = "PROCHAINE PRIÈRE"
        nomProchaineLabel.text = "—"
        heureProchaineLabel.text = "--:--"
        resteLabel.text = " "

        pileProchaine.axis = .vertical
        pileProchaine.alignment = .fill
        pileProchaine.spacing = 6
        pileProchaine.translatesAutoresizingMaskIntoConstraints = false
        pileProchaine.addArrangedSubview(titreProchaineLabel)
        pileProchaine.addArrangedSubview(nomProchaineLabel)
        pileProchaine.addArrangedSubview(heureProchaineLabel)
        pileProchaine.addArrangedSubview(resteLabel)
        carteProchaine.addSubview(pileProchaine)

        NSLayoutConstraint.activate([
            pileProchaine.leadingAnchor.constraint(equalTo: carteProchaine.leadingAnchor, constant: 20),
            pileProchaine.trailingAnchor.constraint(equalTo: carteProchaine.trailingAnchor, constant: -20),
            pileProchaine.centerYAnchor.constraint(equalTo: carteProchaine.centerYAnchor),
            pileProchaine.topAnchor.constraint(greaterThanOrEqualTo: carteProchaine.topAnchor, constant: 18),
            pileProchaine.bottomAnchor.constraint(lessThanOrEqualTo: carteProchaine.bottomAnchor, constant: -18)
        ])

        zoneCentrale.alignment = .fill
        zoneCentrale.distribution = .fill
        zoneCentrale.addArrangedSubview(horlogeLabel)
        zoneCentrale.addArrangedSubview(carteProchaine)

        // En paysage, la carte occupe 43 % de la largeur ; l'horloge prend le reste.
        // (Contrainte activée ou non selon l'orientation, voir `appliquerMiseEnPage`.)
        largeurCarteProchaine = carteProchaine.widthAnchor.constraint(equalTo: zoneCentrale.widthAnchor,
                                                                     multiplier: 0.43)

        // ---------- 3. Bandeau inférieur : les 6 cartes de la journée ----------
        preparer(titreJourLabel, couleur: Palette.secondaire, alignement: .left)
        titreJourLabel.text = "HORAIRES DU JOUR"

        for priere in Priere.allCases {
            let carte = CartePriere()
            carte.configurer(nom: priere.nom, heure: "--:--", style: .normale)
            cartes.append(carte)
        }
        for (index, carte) in cartes.enumerated() {
            // 3 cartes par rangée ; les deux rangées sont côte à côte en paysage (= 6 cartes égales).
            if index < 3 {
                rangeeHaut.addArrangedSubview(carte)
            } else {
                rangeeBas.addArrangedSubview(carte)
            }
        }
        for rangee in [rangeeHaut, rangeeBas] {
            rangee.axis = .horizontal
            rangee.alignment = .fill
            rangee.distribution = .fillEqually
        }
        grille.alignment = .fill
        grille.distribution = .fillEqually
        grille.addArrangedSubview(rangeeHaut)
        grille.addArrangedSubview(rangeeBas)

        sectionBas.axis = .vertical
        sectionBas.alignment = .fill
        sectionBas.spacing = 8
        sectionBas.addArrangedSubview(titreJourLabel)
        sectionBas.addArrangedSubview(grille)

        // ---------- Ligne d'état ----------
        preparer(etatLabel, couleur: Palette.secondaire, alignement: .center)
        etatLabel.text = "Chargement des horaires…"

        // ---------- Assemblage ----------
        pilePrincipale.axis = .vertical
        pilePrincipale.alignment = .fill
        pilePrincipale.distribution = .fill
        pilePrincipale.translatesAutoresizingMaskIntoConstraints = false
        pilePrincipale.addArrangedSubview(bandeau)
        pilePrincipale.addArrangedSubview(zoneCentrale)
        pilePrincipale.addArrangedSubview(sectionBas)
        pilePrincipale.addArrangedSubview(etatLabel)
        view.addSubview(pilePrincipale)

        let zoneSure = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pilePrincipale.topAnchor.constraint(equalTo: zoneSure.topAnchor, constant: 20),
            pilePrincipale.bottomAnchor.constraint(equalTo: zoneSure.bottomAnchor, constant: -14),
            pilePrincipale.leadingAnchor.constraint(equalTo: zoneSure.leadingAnchor, constant: 28),
            pilePrincipale.trailingAnchor.constraint(equalTo: zoneSure.trailingAnchor, constant: -28)
        ])
    }

    /// Adapte la disposition (paysage / portrait) et les tailles de police à l'écran.
    /// Les tailles de référence sont celles d'un iPad 9,7 pouces (1024 × 768 points).
    private func appliquerMiseEnPage(_ taille: CGSize) {
        let paysage = taille.width >= taille.height
        let reference = paysage ? CGSize(width: 1024, height: 768) : CGSize(width: 768, height: 1024)
        let echelle = min(taille.width / reference.width, taille.height / reference.height)

        func pt(_ valeur: CGFloat) -> CGFloat {
            return (valeur * echelle).rounded()
        }

        // Disposition générale
        pilePrincipale.spacing = pt(paysage ? 18 : 16)
        zoneCentrale.axis = paysage ? .horizontal : .vertical
        zoneCentrale.spacing = pt(paysage ? 24 : 16)
        largeurCarteProchaine?.isActive = paysage

        // Paysage : 1 rangée de 6 cartes. Portrait : 2 rangées de 3 cartes (plus lisibles).
        let espaceCartes = pt(12)
        grille.axis = paysage ? .horizontal : .vertical
        grille.spacing = espaceCartes
        rangeeHaut.spacing = espaceCartes
        rangeeBas.spacing = espaceCartes

        // Bandeau supérieur
        villeLabel.font = UIFont.systemFont(ofSize: pt(60), weight: .heavy)
        dateGregLabel.font = UIFont.systemFont(ofSize: pt(32), weight: .bold)
        dateHegireLabel.font = UIFont.systemFont(ofSize: pt(28), weight: .semibold)

        // Horloge : chiffres à chasse fixe pour éviter tout tremblement chaque seconde.
        policeHorloge = UIFont.monospacedDigitSystemFont(ofSize: pt(paysage ? 144 : 140), weight: .bold)
        policeSecondes = UIFont.monospacedDigitSystemFont(ofSize: pt(58), weight: .semibold)

        // Carte « prochaine prière »
        titreProchaineLabel.font = UIFont.systemFont(ofSize: pt(28), weight: .bold)
        nomProchaineLabel.font = UIFont.systemFont(ofSize: pt(paysage ? 62 : 56), weight: .heavy)
        heureProchaineLabel.font = UIFont.monospacedDigitSystemFont(ofSize: pt(paysage ? 124 : 104), weight: .bold)
        resteLabel.font = UIFont.systemFont(ofSize: pt(38), weight: .bold)

        // Bandeau inférieur
        titreJourLabel.font = UIFont.systemFont(ofSize: pt(22), weight: .bold)
        for carte in cartes {
            carte.reglerPolices(nom: pt(paysage ? 28 : 32), heure: pt(paysage ? 44 : 48))
        }

        etatLabel.font = UIFont.systemFont(ofSize: pt(15), weight: .medium)

        // L'horloge utilise un texte mis en forme : on la redessine avec les nouvelles polices.
        afficherHorloge(Date())
    }

    // MARK: Horloge et événements système

    /// Lance le minuteur d'une seconde, calé sur le début de chaque seconde.
    private func demarrerHorloge() {
        minuteur?.invalidate()
        let maintenant = Date().timeIntervalSinceReferenceDate
        let prochaineSeconde = Date(timeIntervalSinceReferenceDate: maintenant.rounded(.down) + 1.0)
        let nouveau = Timer(fire: prochaineSeconde, interval: 1.0, repeats: true) { [weak self] _ in
            self?.tic()
        }
        nouveau.tolerance = 0.05
        // Mode `.common` : le minuteur continue pendant les animations et les rotations.
        RunLoop.main.add(nouveau, forMode: .common)
        minuteur = nouveau
    }

    /// Réagit au retour au premier plan, au passage à minuit et aux changements d'heure ou de fuseau.
    private func observerLeSysteme() {
        let noms: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.significantTimeChangeNotification,   // envoyée notamment à minuit
            Notification.Name.NSSystemTimeZoneDidChange
        ]
        for nom in noms {
            let jeton = NotificationCenter.default.addObserver(forName: nom, object: nil, queue: .main) { [weak self] _ in
                self?.reveil()
            }
            observateurs.append(jeton)
        }
    }

    private func reveil() {
        UIApplication.shared.isIdleTimerDisabled = true
        actualisationDemandee = true
        rafraichirTout()
    }

    /// Appelé chaque seconde : horloge, prochaine prière, compte à rebours, actualisations.
    private func tic() {
        let maintenant = Date()
        afficherHorloge(maintenant)

        // Changement de jour (minuit) : on demande une actualisation.
        let cleDuJour = cle(pour: maintenant)
        if let precedente = cleJourCourant, precedente != cleDuJour {
            actualisationDemandee = true
        }
        cleJourCourant = cleDuJour

        // On ne redessine le reste de l'écran que si quelque chose a réellement changé.
        let etat = calculerEtat(maintenant)
        let signature = [
            cleDuJour,
            etat.jour?.cle ?? "-",
            etat.prochaine?.rawValue ?? "-",
            String(etat.passees.count),
            etat.approximatif ? "approx" : "exact",
            horsLigne ? "hors-ligne" : "en-ligne"
        ].joined(separator: "|")
        if signature != signatureAffichee {
            signatureAffichee = signature
            afficher(etat, maintenant: maintenant)
        }

        afficherCompteARebours(etat, maintenant: maintenant)
        planifierActualisation(maintenant)
    }

    /// Force un réaffichage complet (après réception de données, réveil…).
    private func rafraichirTout() {
        signatureAffichee = ""
        tic()
    }

    // MARK: Dates et calculs

    /// Clé « JJ-MM-AAAA » du jour contenant `date`, dans le fuseau de la ville.
    private func cle(pour date: Date) -> String {
        let c = calendrier.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d-%02d-%04d", c.day ?? 1, c.month ?? 1, c.year ?? 2000)
    }

    private func lendemain(de date: Date) -> Date {
        return calendrier.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
    }

    /// Date exacte d'une heure « HH:mm » le même jour que `jour`.
    private func date(heure: String, leJourDe jour: Date) -> Date? {
        let morceaux = heure.components(separatedBy: ":")
        guard morceaux.count == 2, let h = Int(morceaux[0]), let m = Int(morceaux[1]) else { return nil }
        var composants = calendrier.dateComponents([.year, .month, .day], from: jour)
        composants.hour = h
        composants.minute = m
        composants.second = 0
        return calendrier.date(from: composants)
    }

    /// Les six horaires d'une journée convertis en dates, dans l'ordre.
    private func datesDesPrieres(_ jour: JourPrieres, leJourDe reference: Date) -> [(priere: Priere, date: Date)] {
        var resultat: [(priere: Priere, date: Date)] = []
        var precedente: Date?
        for priere in Priere.allCases {
            guard let heure = jour.horaires[priere.rawValue],
                  var instant = date(heure: heure, leJourDe: reference) else { continue }
            // Cas rare (été, hautes latitudes) : un horaire qui dépasse minuit appartient au lendemain.
            if let avant = precedente, instant < avant {
                instant = lendemain(de: instant)
            }
            precedente = instant
            resultat.append((priere: priere, date: instant))
        }
        return resultat
    }

    /// Horaires du jour demandé. À défaut (hors connexion), ceux du jour le plus récent connu :
    /// d'un jour à l'autre, les horaires ne bougent que d'une à deux minutes.
    private func jourEnCache(_ cle: String) -> (jour: JourPrieres, exact: Bool)? {
        if let jour = cache[cle] {
            return (jour: jour, exact: true)
        }
        guard let plusRecente = cache.keys.max(by: { cleTriable($0) < cleTriable($1) }),
              let jour = cache[plusRecente] else { return nil }
        return (jour: jour, exact: false)
    }

    /// Détermine la prochaine prière, les prières passées et la journée à afficher.
    private func calculerEtat(_ maintenant: Date) -> Etat {
        var etat = Etat()
        guard let aujourdHui = jourEnCache(cle(pour: maintenant)) else { return etat }

        var prochaine: (priere: Priere, date: Date)?
        for element in datesDesPrieres(aujourdHui.jour, leJourDe: maintenant) {
            if element.date <= maintenant {
                etat.passees.insert(element.priere)
            } else if prochaine == nil && (element.priere != .chourouk || chouroukCompteCommeProchaine) {
                prochaine = element
            }
        }

        if let trouvee = prochaine {
            etat.jour = aujourdHui.jour
            etat.approximatif = !aujourdHui.exact
            etat.prochaine = trouvee.priere
            etat.dateProchaine = trouvee.date
            return etat
        }

        // Après Isha : la prochaine prière est le Fajr du lendemain,
        // et la rangée du bas affiche les horaires de demain.
        let demain = lendemain(de: maintenant)
        let jourDemain = jourEnCache(cle(pour: demain)) ?? aujourdHui
        etat.jour = jourDemain.jour
        etat.estDemain = true
        etat.approximatif = !jourDemain.exact
        etat.passees = []
        if let fajr = datesDesPrieres(jourDemain.jour, leJourDe: demain).first(where: { $0.priere == .fajr }) {
            etat.prochaine = .fajr
            etat.dateProchaine = fajr.date
        }
        return etat
    }

    /// « samedi 14 novembre 2026 » → « Samedi 14 Novembre 2026 ».
    private func dateFrancaise(_ date: Date) -> String {
        let mots = formateurDate.string(from: date).components(separatedBy: " ")
        var resultat: [String] = []
        for (index, mot) in mots.enumerated() {
            if index == 1 && mot == "1" {
                resultat.append("1er")
            } else {
                resultat.append(mot.prefix(1).uppercased() + String(mot.dropFirst()))
            }
        }
        return resultat.joined(separator: " ")
    }

    /// Date hégirienne en français, ex. « 4 Joumada ath-Thania 1448 H ».
    private func dateHegirienne(_ jour: JourPrieres) -> String {
        guard jour.jourHegire > 0, jour.anneeHegire > 0,
              (1...moisHegiriens.count).contains(jour.moisHegire) else { return " " }
        let quantieme = (jour.jourHegire == 1) ? "1er" : String(jour.jourHegire)
        return "\(quantieme) \(moisHegiriens[jour.moisHegire - 1]) \(jour.anneeHegire) H"
    }

    // MARK: Affichage

    /// Horloge « HH:mm » géante, suivie des secondes en plus petit.
    private func afficherHorloge(_ date: Date) {
        let c = calendrier.dateComponents([.hour, .minute, .second], from: date)
        let texte = NSMutableAttributedString(
            string: String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0),
            attributes: [.font: policeHorloge, .foregroundColor: Palette.texte])
        texte.append(NSAttributedString(
            string: String(format: " %02d", c.second ?? 0),
            attributes: [.font: policeSecondes, .foregroundColor: Palette.secondaire]))
        horlogeLabel.attributedText = texte
    }

    private func afficher(_ etat: Etat, maintenant: Date) {

        // Bandeau supérieur
        dateGregLabel.text = dateFrancaise(maintenant)
        if let aujourdHui = cache[cle(pour: maintenant)] {
            dateHegireLabel.text = dateHegirienne(aujourdHui)
        } else {
            dateHegireLabel.text = " "
        }

        // Carte « prochaine prière »
        titreProchaineLabel.text = etat.estDemain ? "PROCHAINE PRIÈRE · DEMAIN" : "PROCHAINE PRIÈRE"
        if let prochaine = etat.prochaine, let jour = etat.jour {
            nomProchaineLabel.text = prochaine.nom
            heureProchaineLabel.text = jour.horaires[prochaine.rawValue] ?? "--:--"
        } else {
            nomProchaineLabel.text = "—"
            heureProchaineLabel.text = "--:--"
        }

        // Bandeau inférieur
        titreJourLabel.text = etat.estDemain ? "HORAIRES DE DEMAIN" : "HORAIRES DU JOUR"
        for (index, priere) in Priere.allCases.enumerated() where index < cartes.count {
            let heure = etat.jour?.horaires[priere.rawValue] ?? "--:--"
            let style: CartePriere.Style
            if etat.prochaine == priere {
                style = .prochaine
            } else if etat.passees.contains(priere) {
                style = .passee
            } else {
                style = .normale
            }
            cartes[index].configurer(nom: priere.nom, heure: heure, style: style)
        }

        // Ligne d'état
        etatLabel.text = texteEtat(etat)
        etatLabel.textColor = (horsLigne || etat.approximatif) ? Palette.alerte : Palette.secondaire
    }

    /// « Dans 1 h 25 min »
    private func afficherCompteARebours(_ etat: Etat, maintenant: Date) {
        let texte: String
        if let cible = etat.dateProchaine {
            let secondes = max(0, cible.timeIntervalSince(maintenant))
            let minutesTotales = Int((secondes / 60).rounded(.up))
            let heures = minutesTotales / 60
            let minutes = minutesTotales % 60
            if minutesTotales <= 0 {
                texte = "Maintenant"
            } else if heures == 0 {
                texte = "Dans \(minutes) min"
            } else if minutes == 0 {
                texte = "Dans \(heures) h"
            } else {
                texte = "Dans \(heures) h \(minutes) min"
            }
        } else {
            texte = " "
        }
        if resteLabel.text != texte {
            resteLabel.text = texte
        }
    }

    private func texteEtat(_ etat: Etat) -> String {
        if cache.isEmpty {
            return horsLigne
                ? "Pas de connexion Internet — nouvel essai automatique chaque minute"
                : "Chargement des horaires…"
        }
        if etat.approximatif, let jour = etat.jour {
            let dateConnue = jour.cle.replacingOccurrences(of: "-", with: "/")
            return "Hors connexion — horaires approximatifs (ceux du \(dateConnue))"
        }
        if horsLigne {
            return "Hors connexion — horaires enregistrés affichés"
        }
        if let succes = heureDernierSucces {
            return "\(city), \(country) — horaires actualisés à \(formateurHeure.string(from: succes))"
        }
        return "\(city), \(country) — horaires enregistrés"
    }

    // MARK: Cache (UserDefaults)

    private func chargerCache() {
        guard let data = UserDefaults.standard.data(forKey: cleStockage),
              let enregistre = try? JSONDecoder().decode([String: JourPrieres].self, from: data) else { return }
        cache = enregistre
        // On reprend le fuseau de la ville mémorisé avec les derniers horaires.
        if let plusRecente = cache.keys.max(by: { cleTriable($0) < cleTriable($1) }),
           let identifiant = cache[plusRecente]?.fuseau,
           let zone = TimeZone(identifier: identifiant) {
            fuseau = zone
        }
    }

    private func enregistrerCache() {
        // On ne garde que les 4 journées les plus récentes.
        let clesTriees = cache.keys.sorted { cleTriable($0) > cleTriable($1) }
        for ancienne in clesTriees.dropFirst(4) {
            cache.removeValue(forKey: ancienne)
        }
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cleStockage)
        }
    }

    // MARK: Réseau (API Aladhan)

    /// Ex. https://api.aladhan.com/v1/timingsByCity/14-11-2026?city=Massy&country=France&method=12
    /// (C'est l'adresse vers laquelle l'API redirige elle-même quand on ne précise pas la date.)
    private func urlAPI(pour date: Date) -> URL? {
        var composants = URLComponents(string: "https://api.aladhan.com/v1/timingsByCity/" + cle(pour: date))
        composants?.queryItems = [
            URLQueryItem(name: "city", value: city),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "method", value: String(method))
        ]
        return composants?.url
    }

    /// Décide, chaque seconde, s'il est temps de recontacter l'API :
    /// - toutes les heures en temps normal ;
    /// - chaque minute tant que la connexion est coupée ;
    /// - tout de suite au changement de jour ou au réveil de l'application.
    private func planifierActualisation(_ maintenant: Date) {
        guard requetesEnCours == 0 else { return }
        let ecoule = ProcessInfo.processInfo.systemUptime - dernierEssai
        let manque = cache[cle(pour: maintenant)] == nil
            || cache[cle(pour: lendemain(de: maintenant))] == nil

        let delai: TimeInterval
        if actualisationDemandee {
            delai = 10
        } else if horsLigne {
            delai = delaiNouvelEssai
        } else if manque {
            delai = 300
        } else {
            delai = intervalleActualisation
        }
        if ecoule >= delai {
            actualiser()
        }
    }

    /// Télécharge les horaires d'aujourd'hui ET de demain
    /// (demain sert à afficher le Fajr suivant dès que l'Isha est passé).
    private func actualiser() {
        guard requetesEnCours == 0 else { return }
        actualisationDemandee = false
        echecPendantLeCycle = false
        dernierEssai = ProcessInfo.processInfo.systemUptime

        let maintenant = Date()
        let adresses = [urlAPI(pour: maintenant), urlAPI(pour: lendemain(de: maintenant))].compactMap { $0 }
        guard !adresses.isEmpty else { return }

        requetesEnCours = adresses.count
        for adresse in adresses {
            telechargerHoraires(depuis: adresse) { [weak self] jour in
                // Retour sur le fil principal avant de toucher aux données et à l'écran.
                DispatchQueue.main.async {
                    self?.reception(jour)
                }
            }
        }
    }

    /// Reçoit le résultat d'un téléchargement (`nil` = échec), sur le fil principal.
    private func reception(_ jour: JourPrieres?) {
        requetesEnCours = max(0, requetesEnCours - 1)

        if let jour = jour {
            cache[jour.cle] = jour
            if let identifiant = jour.fuseau, let zone = TimeZone(identifier: identifiant), zone != fuseau {
                fuseau = zone
            }
        } else {
            echecPendantLeCycle = true
        }

        // On attend la fin des deux téléchargements pour conclure.
        guard requetesEnCours == 0 else { return }
        horsLigne = echecPendantLeCycle
        if !echecPendantLeCycle {
            heureDernierSucces = Date()
            actualisationDemandee = false
        }
        enregistrerCache()
        rafraichirTout()
    }
}
