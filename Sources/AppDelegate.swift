//
//  AppDelegate.swift
//  HorairesPrieres
//
//  Point d'entrée de l'application. Compatible iOS 12 :
//  pas de UISceneDelegate, pas de Storyboard, la fenêtre est créée à la main.
//

import UIKit

// `@UIApplicationMain` est volontaire : c'est l'attribut d'époque, garanti sous iOS 12.
// Xcode 16 affiche un simple avertissement (« use @main ») sans conséquence en Swift 5.
@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Fenêtre unique de l'application (obligatoire sous iOS 12, sans scènes).
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Création programmatique de la fenêtre sur tout l'écran.
        let fenetre = UIWindow(frame: UIScreen.main.bounds)
        fenetre.backgroundColor = UIColor(red: 250.0 / 255.0, green: 248.0 / 255.0, blue: 245.0 / 255.0, alpha: 1.0)
        fenetre.rootViewController = ViewController()
        fenetre.makeKeyAndVisible()
        window = fenetre

        // L'iPad ne doit jamais se mettre en veille tant que l'application est affichée.
        application.isIdleTimerDisabled = true
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // iOS peut réactiver la mise en veille après un passage en arrière-plan : on la re-désactive.
        application.isIdleTimerDisabled = true
    }
}
