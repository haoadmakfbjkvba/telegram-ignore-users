import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ContextUI
import TelegramPresentationData

/// "Ignore Mark" in the menu of a message in a group, or "Stop Ignoring Mark". As the menu opens the row introduces
/// itself: it lights up and stays larger for a couple of seconds, its eye blinks and is crossed out (or opens again),
/// the title rises letter by letter, a ring goes out from the eye and a band of light passes over the row.
public final class IgnoreMenuItem: ContextMenuCustomItem {
    public enum Kind {
        case ignore
        case stopIgnoring
    }

    private static let introductionsKey = "IgnoreMenuItem.Introductions"
    private static let introductionCount = 3

    let kind: Kind
    let title: String
    let action: () -> Void

    public init(kind: Kind, title: String, action: @escaping () -> Void) {
        self.kind = kind
        self.title = title
        self.action = action
    }

    public func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        // "Ignore" introduces itself the first times it is seen; "Stop Ignoring" whenever it is offered (it is offered
        // only to someone who looks for it).
        let introduces: Bool
        switch self.kind {
        case .ignore:
            introduces = UserDefaults.standard.integer(forKey: IgnoreMenuItem.introductionsKey) < IgnoreMenuItem.introductionCount
        case .stopIgnoring:
            introduces = true
        }
        return IgnoreMenuItemNode(presentationData: presentationData, item: self, introduces: introduces, actionSelected: actionSelected)
    }

    fileprivate static func noteIntroduction() {
        let count = UserDefaults.standard.integer(forKey: IgnoreMenuItem.introductionsKey)
        UserDefaults.standard.set(count + 1, forKey: IgnoreMenuItem.introductionsKey)
    }
}

private final class IgnoreMenuItemNode: ASDisplayNode, ContextMenuCustomNode {
    private let item: IgnoreMenuItem
    private let actionSelected: (ContextMenuActionResult) -> Void
    private var presentationData: PresentationData
    private let introduces: Bool
    private var didIntroduce = false

    private let highlightView = UIView()
    private let tintView = UIView()
    private let contentView = UIView()
    private let eyeView: IgnoreEyeView
    private let titleView = IgnoreTextView()

    var needsSeparator: Bool {
        return false
    }

    var needsPadding: Bool {
        return true
    }

    init(presentationData: PresentationData, item: IgnoreMenuItem, introduces: Bool, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.item = item
        self.presentationData = presentationData
        self.introduces = introduces && !UIAccessibility.isReduceMotionEnabled
        self.actionSelected = actionSelected
        // "Ignore" shows the eye that is about to be crossed out; "Stop Ignoring" the crossed out eye about to open.
        self.eyeView = IgnoreEyeView(isSlashed: item.kind == .stopIgnoring)
        super.init()

        self.isAccessibilityElement = true
        self.accessibilityLabel = item.title
        self.accessibilityTraits = [.button]
    }

    override func didLoad() {
        super.didLoad()
        self.highlightView.isUserInteractionEnabled = false
        self.highlightView.alpha = 0.0
        self.view.addSubview(self.highlightView)
        self.tintView.isUserInteractionEnabled = false
        self.tintView.alpha = 0.0
        self.view.addSubview(self.tintView)
        self.contentView.isUserInteractionEnabled = false
        self.view.addSubview(self.contentView)
        self.contentView.addSubview(self.eyeView)
        self.contentView.addSubview(self.titleView)
        if self.introduces {
            // The row comes in by itself as the menu settles: until then it is empty.
            self.eyeView.alpha = 0.0
            self.titleView.alpha = 0.0
        }
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        if self.introduces && !self.didIntroduce {
            self.didIntroduce = true
            if self.item.kind == .ignore {
                IgnoreMenuItem.noteIntroduction()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: { [weak self] in
                self?.playIntroduction()
            })
        }
    }

    private var titleFont: UIFont {
        return Font.regular(self.presentationData.listsFontSize.baseDisplaySize)
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let theme = self.presentationData.theme
        let iconSideInset: CGFloat = 20.0
        let titleX = iconSideInset + 40.0
        let verticalInset: CGFloat = 11.0
        let titleSize = IgnoreTextView.measure(text: NSAttributedString(string: self.item.title, attributes: [.font: self.titleFont]), width: max(1.0, constrainedWidth - titleX - 18.0), maxLines: 1)
        let height = verticalInset * 2.0 + max(22.0, titleSize.height)
        let minWidth = titleX + titleSize.width + 18.0

        return (CGSize(width: minWidth, height: height), { [weak self] size, transition in
            guard let self else {
                return
            }
            let accent = theme.list.itemAccentColor
            self.highlightView.frame = CGRect(origin: CGPoint(), size: size)
            self.highlightView.backgroundColor = theme.contextMenu.itemHighlightedBackgroundColor
            self.tintView.frame = CGRect(origin: CGPoint(), size: size)
            self.tintView.backgroundColor = accent.withAlphaComponent(theme.overallDarkAppearance ? 0.24 : 0.13)
            self.contentView.frame = CGRect(origin: CGPoint(), size: size)
            let iconSize: CGFloat = 24.0
            self.eyeView.frame = CGRect(x: iconSideInset + floor((32.0 - iconSize) * 0.5), y: floor((size.height - iconSize) * 0.5), width: iconSize, height: iconSize)
            self.eyeView.color = theme.contextMenu.primaryColor
            let titleWidth = max(1.0, min(titleSize.width, size.width - titleX - 18.0))
            self.titleView.update(text: NSAttributedString(string: self.item.title, attributes: [.font: self.titleFont, .foregroundColor: theme.contextMenu.primaryColor]), width: titleWidth, maxLines: 1)
            self.titleView.frame = CGRect(origin: CGPoint(x: titleX, y: floor((size.height - titleSize.height) * 0.5)), size: CGSize(width: titleWidth, height: titleSize.height))
        })
    }

    /// The row lights up and grows, and stays larger for a couple of seconds while its eye blinks and is crossed out
    /// (or opens again), its title rises letter by letter, a ring goes out from the eye and light passes over it.
    private func playIntroduction() {
        guard self.isNodeLoaded, !self.bounds.isEmpty else {
            self.eyeView.alpha = 1.0
            self.titleView.alpha = 1.0
            return
        }
        self.eyeView.alpha = 1.0
        self.titleView.alpha = 1.0
        let accent = self.presentationData.theme.list.itemAccentColor

        // The whole row lights up and grows a little, holds there for a couple of seconds, then settles.
        let total = 2.6
        ignoreAddKeyframes(self.tintView.layer, keyPath: "opacity", values: [0.0, 1.0, 1.0, 0.0], keyTimes: [0.0, 0.1, 0.78, 1.0], duration: total, delay: 0.0)
        ignoreAddKeyframes(self.contentView.layer, keyPath: "transform.scale", values: [0.86, 1.2, 1.14, 1.17, 1.14, 1.0], keyTimes: [0.0, 0.12, 0.3, 0.52, 0.76, 1.0], duration: total, delay: 0.0)

        // The eye pops in turning, then blinks and is crossed out (or opens again).
        ignoreAddKeyframes(self.eyeView.layer, keyPath: "transform.scale", values: [0.1, 1.45, 0.88, 1.12, 1.0], keyTimes: [0.0, 0.35, 0.6, 0.8, 1.0], duration: 0.7, delay: 0.0)
        ignoreAddKeyframes(self.eyeView.layer, keyPath: "transform.rotation.z", values: [-0.9, 0.25, -0.1, 0.0], keyTimes: [0.0, 0.4, 0.7, 1.0], duration: 0.7, delay: 0.0)
        self.eyeView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.16)
        switch self.item.kind {
        case .ignore:
            self.eyeView.blink(delay: 0.62, duration: 0.34)
            self.eyeView.setSlashed(true, animated: true, delay: 0.98, duration: 0.42)
        case .stopIgnoring:
            self.eyeView.setSlashed(false, animated: true, delay: 0.62, duration: 0.42)
            self.eyeView.popIris(delay: 0.9)
        }
        // A little nod of the eye as the slash lands (or comes off).
        ignoreAddKeyframes(self.eyeView.layer, keyPath: "transform.translation.x", values: [0.0, -2.0, 1.5, 0.0], keyTimes: [0.0, 0.3, 0.65, 1.0], duration: 0.36, delay: 1.36)
        self.sendRing(color: accent, delay: 1.3)

        let _ = self.titleView.animateLettersIn(delay: 0.1, stagger: 0.024, offset: 10.0)
        ignoreAnimateSheen(over: self.contentView, cornerRadius: 0.0, delay: 1.0, duration: 0.9, alpha: self.presentationData.theme.overallDarkAppearance ? 0.18 : 0.5)
    }

    /// A ring going out from the eye and fading.
    private func sendRing(color: UIColor, delay: Double) {
        let center = self.eyeView.center
        let ring = CAShapeLayer()
        ring.contentsScale = UIScreenScale * 2.0
        ring.path = UIBezierPath(arcCenter: CGPoint(), radius: 15.0, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath
        ring.position = center
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2.0
        ring.opacity = 0.0
        self.contentView.layer.insertSublayer(ring, below: self.eyeView.layer)
        ignoreAddKeyframes(ring, keyPath: "transform.scale", values: [0.6, 1.9], keyTimes: [0.0, 1.0], duration: 0.7, delay: delay, timing: .easeOut)
        ignoreAddKeyframes(ring, keyPath: "opacity", values: [0.0, 0.7, 0.0], keyTimes: [0.0, 0.2, 1.0], duration: 0.7, delay: delay, timing: .easeOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.8, execute: { [weak ring] in
            ring?.removeFromSuperlayer()
        })
    }

    func updateTheme(presentationData: PresentationData) {
        self.presentationData = presentationData
    }

    func canBeHighlighted() -> Bool {
        return true
    }

    func updateIsHighlighted(isHighlighted: Bool) {
        if isHighlighted {
            self.highlightView.alpha = 1.0
        } else {
            let previous = self.highlightView.alpha
            self.highlightView.alpha = 0.0
            self.highlightView.layer.animateAlpha(from: previous, to: 0.0, duration: 0.2)
        }
    }

    func performAction() {
        self.actionSelected(.dismissWithoutContent)
        self.item.action()
    }
}
