import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData

/// The line under the header of a group where messages of someone ignored are hidden: who is ignored, and that a tap
/// brings them back.
public final class IgnoredChatPanelComponent: Component {
    let theme: PresentationTheme
    let strings: PresentationStrings
    /// The names of the people whose messages are hidden here, the most recently ignored first.
    let names: [String]
    /// Whether it introduces itself as it appears (the first time it shows these people in a chat; not each time it
    /// comes back, as after a search).
    public let introduces: Bool
    let action: (UIView) -> Void

    public init(theme: PresentationTheme, strings: PresentationStrings, names: [String], introduces: Bool, action: @escaping (UIView) -> Void) {
        self.theme = theme
        self.strings = strings
        self.names = names
        self.introduces = introduces
        self.action = action
    }

    public static func ==(lhs: IgnoredChatPanelComponent, rhs: IgnoredChatPanelComponent) -> Bool {
        return lhs.theme === rhs.theme && lhs.strings === rhs.strings && lhs.names == rhs.names
    }

    public final class View: UIView {
        private let contentView = UIView()
        private let badgeView = UIView()
        private let eyeView = IgnoreEyeView(isSlashed: true)
        private let titleView = IgnoreTextView()
        private let textView = IgnoreTextView()
        private let arrowLayer = CAShapeLayer()
        private var component: IgnoredChatPanelComponent?
        private var didAppear = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.contentView.isUserInteractionEnabled = false
            self.addSubview(self.contentView)
            self.badgeView.addSubview(self.eyeView)
            self.contentView.addSubview(self.badgeView)
            self.contentView.addSubview(self.titleView)
            self.contentView.addSubview(self.textView)
            self.arrowLayer.fillColor = UIColor.clear.cgColor
            self.arrowLayer.contentsScale = UIScreenScale * 2.0
            self.arrowLayer.lineWidth = 2.0
            self.arrowLayer.lineCap = .round
            self.arrowLayer.lineJoin = .round
            self.contentView.layer.addSublayer(self.arrowLayer)
            self.isAccessibilityElement = true
            self.accessibilityTraits = [.button]
            self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped)))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func tapped() {
            guard let component = self.component else {
                return
            }
            if !UIAccessibility.isReduceMotionEnabled {
                ignoreAnimatePop(self.contentView.layer, from: 0.96, overshoot: 1.02, duration: 0.3)
            }
            component.action(self)
        }

        private func texts(_ component: IgnoredChatPanelComponent) -> (title: String, text: String) {
            let title: String
            if component.names.count == 1, let name = component.names.first {
                title = component.strings.IgnoredMembers_PanelTitle(name).string
            } else {
                title = component.strings.IgnoredMembers_PanelTitleMany("\(component.names.count)").string
            }
            return (title, component.strings.IgnoredMembers_PanelText)
        }

        func update(component: IgnoredChatPanelComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            self.component = component
            let theme = component.theme
            let (title, text) = self.texts(component)

            let iconSize: CGFloat = 30.0
            let leftInset: CGFloat = 12.0
            let rightInset: CGFloat = 16.0
            let arrowWidth: CGFloat = 7.0
            let textX = leftInset + iconSize + 11.0
            let textWidth = max(1.0, availableSize.width - textX - rightInset - arrowWidth - 10.0)
            let titleColor = theme.rootController.navigationBar.primaryTextColor
            let textColor = theme.rootController.navigationBar.secondaryTextColor
            let titleSize = self.titleView.update(text: NSAttributedString(string: title, attributes: [.font: Font.semibold(15.0), .foregroundColor: titleColor]), width: textWidth, maxLines: 1)
            let textSize = self.textView.update(text: NSAttributedString(string: text, attributes: [.font: Font.regular(13.0), .foregroundColor: textColor]), width: textWidth, maxLines: 1)

            let verticalInset: CGFloat = 8.0
            let height = max(iconSize + verticalInset * 2.0, verticalInset * 2.0 + titleSize.height + 1.0 + textSize.height)
            let size = CGSize(width: availableSize.width, height: height)
            self.contentView.frame = CGRect(origin: CGPoint(), size: size)

            self.badgeView.frame = CGRect(x: leftInset, y: floor((height - iconSize) * 0.5), width: iconSize, height: iconSize)
            self.badgeView.layer.cornerRadius = iconSize * 0.5
            self.badgeView.backgroundColor = theme.list.itemAccentColor
            self.eyeView.frame = self.badgeView.bounds.insetBy(dx: 6.0, dy: 6.0)
            self.eyeView.color = .white
            self.eyeView.lineWidth = 2.0

            let blockHeight = titleSize.height + 1.0 + textSize.height
            self.titleView.frame = CGRect(origin: CGPoint(x: textX, y: floor((height - blockHeight) * 0.5)), size: titleSize)
            self.textView.frame = CGRect(origin: CGPoint(x: textX, y: self.titleView.frame.maxY + 1.0), size: textSize)

            let arrow = UIBezierPath()
            let arrowX = size.width - rightInset - arrowWidth
            arrow.move(to: CGPoint(x: arrowX, y: height * 0.5 - 6.0))
            arrow.addLine(to: CGPoint(x: arrowX + arrowWidth, y: height * 0.5))
            arrow.addLine(to: CGPoint(x: arrowX, y: height * 0.5 + 6.0))
            self.arrowLayer.path = arrow.cgPath
            self.arrowLayer.strokeColor = textColor.withAlphaComponent(0.7).cgColor
            self.arrowLayer.frame = CGRect(origin: CGPoint(), size: size)

            self.accessibilityLabel = title
            self.accessibilityHint = text

            if !self.didAppear {
                self.didAppear = true
                if component.introduces {
                    // Once the container has given the line its frame (the light passing over needs it).
                    DispatchQueue.main.async { [weak self] in
                        self?.animateAppearance()
                    }
                    UIAccessibility.post(notification: .announcement, argument: title)
                }
            }
            return size
        }

        /// The line comes in large and stays so for a moment: the eye pops up turning and is crossed out, a ring goes
        /// out of it, the title and the line under it come in letter by letter, light passes over, and it settles.
        private func animateAppearance() {
            guard !UIAccessibility.isReduceMotionEnabled, let component = self.component else {
                return
            }
            // The line as a whole grows (with its glass) in the chat's node; inside it, a second ring later keeps the eye in
            // view while the text comes in.
            self.sendRing(color: component.theme.list.itemAccentColor, delay: 1.35)
            let badge = self.badgeView.layer
            ignoreAddKeyframes(badge, keyPath: "transform.scale", values: [0.0, 1.4, 0.88, 1.08, 1.0], keyTimes: [0.0, 0.35, 0.6, 0.8, 1.0], duration: 0.8, delay: 0.08)
            ignoreAddKeyframes(badge, keyPath: "transform.rotation.z", values: [-1.0, 0.2, -0.06, 0.0], keyTimes: [0.0, 0.4, 0.7, 1.0], duration: 0.8, delay: 0.08)
            // The eye is drawn open first and crossed out as it lands.
            self.eyeView.setSlashed(false, animated: false)
            self.eyeView.blink(delay: 0.45, duration: 0.26)
            self.eyeView.setSlashed(true, animated: true, delay: 0.68, duration: 0.3)
            self.sendRing(color: component.theme.list.itemAccentColor, delay: 0.62)
            let titleDuration = self.titleView.animateLettersIn(delay: 0.2, stagger: 0.022, offset: 9.0)
            let _ = self.textView.animateLettersIn(delay: min(titleDuration, 0.55), stagger: 0.012, offset: 6.0)
            self.arrowLayer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3, delay: 0.5)
            ignoreAddKeyframes(self.arrowLayer, keyPath: "transform.translation.x", values: [-8.0, 2.0, 0.0], keyTimes: [0.0, 0.6, 1.0], duration: 0.45, delay: 0.5)
            ignoreAnimateSheen(over: self, cornerRadius: self.bounds.height * 0.5, delay: 0.95, duration: 0.9, alpha: component.theme.overallDarkAppearance ? 0.16 : 0.45)
        }

        /// A ring going out from the eye and fading.
        private func sendRing(color: UIColor, delay: Double) {
            let ring = CAShapeLayer()
            ring.contentsScale = UIScreenScale * 2.0
            ring.path = UIBezierPath(arcCenter: CGPoint(), radius: self.badgeView.bounds.width * 0.5, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath
            ring.position = self.badgeView.center
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = color.cgColor
            ring.lineWidth = 2.0
            ring.opacity = 0.0
            self.contentView.layer.insertSublayer(ring, below: self.badgeView.layer)
            ignoreAddKeyframes(ring, keyPath: "transform.scale", values: [0.8, 1.9], keyTimes: [0.0, 1.0], duration: 0.65, delay: delay, timing: .easeOut)
            ignoreAddKeyframes(ring, keyPath: "opacity", values: [0.0, 0.75, 0.0], keyTimes: [0.0, 0.2, 1.0], duration: 0.65, delay: delay, timing: .easeOut)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.75, execute: { [weak ring] in
                ring?.removeFromSuperlayer()
            })
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
