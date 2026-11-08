import Foundation
import UIKit
import Display

/// An eye that can be crossed out (someone ignored) or open again. Drawn on a 24-point grid and scaled to the view, so
/// that every part can move: the eye blinks, the slash is drawn across it (cutting a gap through the eye as it goes) or
/// taken back, the iris pops.
public final class IgnoreEyeView: UIView {
    private static let grid: CGFloat = 24.0
    private static let slashStart = CGPoint(x: 4.0, y: 3.5)
    private static let slashEnd = CGPoint(x: 20.0, y: 20.5)

    private let canvas = CALayer()
    private let eyeContainer = CALayer()
    private let outlineLayer = CAShapeLayer()
    private let irisLayer = CAShapeLayer()
    private let gapMask = CAShapeLayer()
    private let slashLayer = CAShapeLayer()

    public private(set) var isSlashed: Bool
    public var lineWidth: CGFloat = 1.8 {
        didSet {
            self.updatePaths()
        }
    }
    public var color: UIColor = .black {
        didSet {
            self.outlineLayer.strokeColor = self.color.cgColor
            self.irisLayer.strokeColor = self.color.cgColor
            self.irisLayer.fillColor = self.color.cgColor
            self.slashLayer.strokeColor = self.color.cgColor
        }
    }

    public init(isSlashed: Bool) {
        self.isSlashed = isSlashed
        super.init(frame: CGRect())
        self.isUserInteractionEnabled = false
        self.layer.addSublayer(self.canvas)
        self.canvas.addSublayer(self.eyeContainer)
        self.eyeContainer.addSublayer(self.outlineLayer)
        self.eyeContainer.addSublayer(self.irisLayer)
        self.eyeContainer.mask = self.gapMask
        self.canvas.addSublayer(self.slashLayer)
        for layer in [self.outlineLayer, self.slashLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            layer.lineJoin = .round
        }
        self.irisLayer.lineCap = .round
        self.gapMask.fillRule = .evenOdd
        self.gapMask.fillColor = UIColor.white.cgColor
        // Set directly: didSet does not run in an initializer.
        self.outlineLayer.strokeColor = self.color.cgColor
        self.irisLayer.strokeColor = self.color.cgColor
        self.irisLayer.fillColor = self.color.cgColor
        self.slashLayer.strokeColor = self.color.cgColor
        self.updatePaths()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let scale = self.bounds.width / IgnoreEyeView.grid
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.canvas.bounds = CGRect(x: 0.0, y: 0.0, width: IgnoreEyeView.grid, height: IgnoreEyeView.grid)
        self.canvas.position = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        self.canvas.transform = CATransform3DMakeScale(scale, scale, 1.0)
        // The paths are drawn on a 24-point grid that is then scaled up to the view: they are drawn at the screen's
        // resolution of what is shown, twice over (the eye pops larger than itself and its row grows).
        let contentsScale = UIScreenScale * max(1.0, scale) * 2.0
        for layer in [self.canvas, self.eyeContainer, self.outlineLayer, self.irisLayer, self.gapMask, self.slashLayer] {
            layer.contentsScale = contentsScale
            layer.rasterizationScale = contentsScale
        }
        for layer in [self.eyeContainer, self.outlineLayer, self.irisLayer, self.gapMask, self.slashLayer] {
            layer.frame = CGRect(x: 0.0, y: 0.0, width: IgnoreEyeView.grid, height: IgnoreEyeView.grid)
        }
        CATransaction.commit()
    }

    private func updatePaths() {
        let outline = UIBezierPath()
        outline.move(to: CGPoint(x: 1.8, y: 12.0))
        outline.addQuadCurve(to: CGPoint(x: 22.2, y: 12.0), controlPoint: CGPoint(x: 12.0, y: 1.6))
        outline.addQuadCurve(to: CGPoint(x: 1.8, y: 12.0), controlPoint: CGPoint(x: 12.0, y: 22.4))
        outline.close()
        self.outlineLayer.path = outline.cgPath
        self.outlineLayer.lineWidth = self.lineWidth
        self.irisLayer.path = UIBezierPath(arcCenter: CGPoint(x: 12.0, y: 12.0), radius: 3.3, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath
        self.irisLayer.lineWidth = 0.0

        let slash = UIBezierPath()
        slash.move(to: IgnoreEyeView.slashStart)
        slash.addLine(to: IgnoreEyeView.slashEnd)
        self.slashLayer.path = slash.cgPath
        self.slashLayer.lineWidth = self.lineWidth
        self.slashLayer.strokeEnd = self.isSlashed ? 1.0 : 0.0
        // A line of no length still draws its round cap as a dot: the slash is hidden while it is not there.
        self.slashLayer.opacity = self.isSlashed ? 1.0 : 0.0
        self.gapMask.path = self.gapPath(progress: self.isSlashed ? 1.0 : 0.0)
    }

    /// The whole grid with a band cut along the slash, as far as `progress` of its length.
    private func gapPath(progress: CGFloat) -> CGPath {
        let path = UIBezierPath(rect: CGRect(x: -4.0, y: -4.0, width: IgnoreEyeView.grid + 8.0, height: IgnoreEyeView.grid + 8.0))
        let start = IgnoreEyeView.slashStart
        let end = CGPoint(x: start.x + (IgnoreEyeView.slashEnd.x - start.x) * progress, y: start.y + (IgnoreEyeView.slashEnd.y - start.y) * progress)
        let dx = IgnoreEyeView.slashEnd.x - start.x
        let dy = IgnoreEyeView.slashEnd.y - start.y
        let length = max(0.001, sqrt(dx * dx + dy * dy))
        // Perpendicular, wide enough for the slash and a gap on each side of it.
        let half = self.lineWidth * 0.5 + self.lineWidth * 1.1
        let nx = -dy / length * half
        let ny = dx / length * half
        let band = UIBezierPath()
        band.move(to: CGPoint(x: start.x + nx, y: start.y + ny))
        band.addLine(to: CGPoint(x: end.x + nx, y: end.y + ny))
        band.addLine(to: CGPoint(x: end.x - nx, y: end.y - ny))
        band.addLine(to: CGPoint(x: start.x - nx, y: start.y - ny))
        band.close()
        path.append(band)
        return path.cgPath
    }

    /// Crosses the eye out or opens it again.
    public func setSlashed(_ isSlashed: Bool, animated: Bool, delay: Double = 0.0, duration: Double = 0.36) {
        guard self.isSlashed != isSlashed || !animated else {
            return
        }
        self.isSlashed = isSlashed
        let to: CGFloat = isSlashed ? 1.0 : 0.0
        let from: CGFloat = isSlashed ? 0.0 : 1.0
        self.slashLayer.strokeEnd = to
        self.slashLayer.opacity = isSlashed ? 1.0 : 0.0
        self.gapMask.path = self.gapPath(progress: to)
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            return
        }
        // Shown from the moment it starts to be drawn, until the moment it is fully taken back (no dot either side).
        if isSlashed {
            ignoreAddKeyframes(self.slashLayer, keyPath: "opacity", values: [0.0 as NSNumber, 1.0 as NSNumber, 1.0 as NSNumber], keyTimes: [0.0, 0.02, 1.0], duration: duration, delay: delay, timing: .linear)
        } else {
            ignoreAddKeyframes(self.slashLayer, keyPath: "opacity", values: [1.0 as NSNumber, 1.0 as NSNumber, 0.0 as NSNumber], keyTimes: [0.0, 0.98, 1.0], duration: duration, delay: delay, timing: .linear)
        }
        let timing: CAMediaTimingFunctionName = isSlashed ? .easeOut : .easeIn
        ignoreAddKeyframes(self.slashLayer, keyPath: "strokeEnd", values: [from as NSNumber, to as NSNumber], keyTimes: [0.0, 1.0], duration: duration, delay: delay, timing: timing)
        let steps = 8
        var paths: [Any] = []
        var times: [NSNumber] = []
        for step in 0 ... steps {
            let t = CGFloat(step) / CGFloat(steps)
            paths.append(self.gapPath(progress: from + (to - from) * t))
            times.append(NSNumber(value: Double(t)))
        }
        ignoreAddKeyframes(self.gapMask, keyPath: "path", values: paths, keyTimes: times, duration: duration, delay: delay, timing: timing)
    }

    /// The eye closes for a moment and opens again.
    public func blink(delay: Double = 0.0, duration: Double = 0.32) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            return
        }
        ignoreAddKeyframes(self.eyeContainer, keyPath: "transform.scale.y", values: [1.0, 0.08, 1.0], keyTimes: [0.0, 0.45, 1.0], duration: duration, delay: delay)
    }

    /// The iris grows and settles (the eye looks again).
    public func popIris(delay: Double = 0.0) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            return
        }
        ignoreAddKeyframes(self.irisLayer, keyPath: "transform.scale", values: [0.2, 1.35, 0.9, 1.0], keyTimes: [0.0, 0.45, 0.75, 1.0], duration: 0.5, delay: delay)
    }
}
