import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var privacyOverlay: UIVisualEffectView?

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    guard let window = self.window, privacyOverlay == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyOverlay = blur
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyOverlay?.removeFromSuperview()
    privacyOverlay = nil
  }
}
