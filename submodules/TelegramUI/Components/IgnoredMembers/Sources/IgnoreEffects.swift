import Foundation
import UIKit
import Display
import AsyncDisplayKit

/// What a view (a part of it) looks like now, as an image, and where in it something is drawn (its bubble).
public struct IgnoreSnapshot {
    public let image: UIImage
    /// The part of the view the image shows, in the view's coordinates.
    public let rect: CGRect
    /// The part of the image that is not transparent, in the image's coordinates.
    public let contentRect: CGRect

    /// Draws `view` (the part `rect` of it, or all of it) as it is on screen now, or (`renderLayer`) as its layers are
    /// now, also before it has been shown (it is drawn as if it were visible). Nil if it has nothing to draw.
    public static func take(of view: UIView, in rect: CGRect? = nil, renderLayer: Bool = false) -> IgnoreSnapshot? {
        let bounds = view.bounds
        let rect = (rect ?? bounds).intersection(bounds).integral
        guard rect.width >= 1.0, rect.height >= 1.0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreenScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { context in
            if renderLayer {
                let wasHidden = view.isHidden
                let alpha = view.alpha
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                view.isHidden = false
                view.alpha = 1.0
                view.layer.render(in: context.cgContext)
                view.alpha = alpha
                view.isHidden = wasHidden
                CATransaction.commit()
            } else if !view.drawHierarchy(in: bounds, afterScreenUpdates: false) {
                view.layer.render(in: context.cgContext)
            }
        }
        guard let contentRect = IgnoreSnapshot.opaqueBounds(of: image) else {
            return nil
        }
        return IgnoreSnapshot(image: image, rect: rect, contentRect: contentRect)
    }

    /// The pixels of `image` drawn at a quarter of its size (or `factor`), RGBA, rows from the top.
    private static func pixels(of image: UIImage, factor: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let cgImage = image.cgImage else {
            return nil
        }
        let width = max(1, cgImage.width / factor)
        let height = max(1, cgImage.height / factor)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }

    /// The bounds of the pixels that are not (almost) transparent, in points; looked for on a smaller copy.
    private static func opaqueBounds(of image: UIImage) -> CGRect? {
        guard let (pixels, width, height) = IgnoreSnapshot.pixels(of: image, factor: 4) else {
            return nil
        }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[(y * width + x) * 4 + 3] > 24 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return nil
        }
        // The first row of a bitmap context's memory is the top of what is drawn into it.
        let pointsPerPixel = image.size.width / CGFloat(width)
        let rect = CGRect(x: CGFloat(minX) * pointsPerPixel, y: CGFloat(minY) * pointsPerPixel, width: CGFloat(maxX - minX + 1) * pointsPerPixel, height: CGFloat(maxY - minY + 1) * pointsPerPixel)
        return rect.intersection(CGRect(origin: CGPoint(), size: image.size))
    }

    /// Up to `count` points inside the content (in the image's coordinates) with the colors drawn there, spread over
    /// it; read from a smaller copy.
    func samples(count: Int) -> [(point: CGPoint, color: UIColor)] {
        guard count > 0, let (pixels, width, height) = IgnoreSnapshot.pixels(of: self.image, factor: 3) else {
            return []
        }
        let scale = CGFloat(width) / max(1.0, self.image.size.width)
        var result: [(point: CGPoint, color: UIColor)] = []
        var attempts = 0
        var generator = SystemRandomNumberGenerator()
        while result.count < count && attempts < count * 12 {
            attempts += 1
            let point = CGPoint(x: self.contentRect.minX + CGFloat.random(in: 0.0 ... 1.0, using: &generator) * self.contentRect.width, y: self.contentRect.minY + CGFloat.random(in: 0.0 ... 1.0, using: &generator) * self.contentRect.height)
            let px = min(width - 1, max(0, Int(point.x * scale)))
            let py = min(height - 1, max(0, Int(point.y * scale)))
            let offset = (py * width + px) * 4
            let alpha = CGFloat(pixels[offset + 3]) / 255.0
            guard alpha > 0.5 else {
                continue
            }
            let color = UIColor(red: CGFloat(pixels[offset]) / 255.0 / alpha, green: CGFloat(pixels[offset + 1]) / 255.0 / alpha, blue: CGFloat(pixels[offset + 2]) / 255.0 / alpha, alpha: 1.0)
            result.append((point, color))
        }
        return result
    }
}

/// The colors of the effect.
public struct IgnoreEffectStyle {
    public let badgeColor: UIColor
    public let glyphColor: UIColor

    public init(badgeColor: UIColor, glyphColor: UIColor) {
        self.badgeColor = badgeColor
        self.glyphColor = glyphColor
    }
}

private let ignoreEffectBadgeSize: CGFloat = 34.0

/// The eye that the effect gathers a message into (or lets it out of): a round badge with the eye on it.
private final class IgnoreEffectBadge {
    let view = UIView()
    let eye: IgnoreEyeView

    init(style: IgnoreEffectStyle, isSlashed: Bool) {
        self.eye = IgnoreEyeView(isSlashed: isSlashed)
        self.view.frame = CGRect(x: 0.0, y: 0.0, width: ignoreEffectBadgeSize, height: ignoreEffectBadgeSize)
        self.view.layer.cornerRadius = ignoreEffectBadgeSize * 0.5
        self.view.backgroundColor = style.badgeColor
        self.view.layer.shadowColor = UIColor.black.cgColor
        self.view.layer.shadowOpacity = 0.18
        self.view.layer.shadowRadius = 6.0
        self.view.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
        self.eye.color = style.glyphColor
        self.eye.lineWidth = 2.0
        self.eye.frame = CGRect(x: 7.0, y: 7.0, width: 20.0, height: 20.0)
        self.view.addSubview(self.eye)
        self.view.isUserInteractionEnabled = false
    }
}

/// A ring going out from `center` and fading.
private func ignoreRingBurst(in container: UIView, center: CGPoint, color: UIColor, radius: CGFloat, delay: Double) {
    let ring = CAShapeLayer()
    ring.contentsScale = UIScreenScale * 2.0
    ring.path = UIBezierPath(arcCenter: CGPoint(), radius: radius, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath
    ring.position = center
    ring.fillColor = UIColor.clear.cgColor
    ring.strokeColor = color.cgColor
    ring.lineWidth = 2.0
    ring.opacity = 0.0
    container.layer.addSublayer(ring)
    ignoreAddKeyframes(ring, keyPath: "transform.scale", values: [0.5, 1.8], keyTimes: [0.0, 1.0], duration: 0.55, delay: delay, timing: .easeOut)
    ignoreAddKeyframes(ring, keyPath: "opacity", values: [0.0, 0.8, 0.0], keyTimes: [0.0, 0.2, 1.0], duration: 0.55, delay: delay, timing: .easeOut)
}

/// A message being ignored: the eye pops up over it, the message is drawn into the eye (it narrows, blurs and fades
/// while its pieces swirl into the eye), the eye blinks, is crossed out and goes with a ring. `snapshot` is the
/// message drawn at `frame` (in `container`'s coordinates); `extra` are more parts of it (its avatar) to take along.
/// Everything it adds to `container` is removed when it is done; returns how long it takes from now.
@discardableResult
public func ignorePlayDissolve(snapshot: IgnoreSnapshot, frame: CGRect, extra: [(snapshot: IgnoreSnapshot, frame: CGRect)] = [], in container: UIView, style: IgnoreEffectStyle, delay: Double) -> Double {
    let host = UIView(frame: container.bounds)
    host.isUserInteractionEnabled = false
    container.addSubview(host)

    let content = snapshot.contentRect.offsetBy(dx: frame.minX, dy: frame.minY)
    let center = CGPoint(x: content.midX, y: content.midY)
    // Until the last ring has gone.
    let end = delay + 1.5
    DispatchQueue.main.asyncAfter(deadline: .now() + end, execute: { [weak host] in
        host?.removeFromSuperview()
    })

    // The message itself, from now on drawn by the effect.
    let bubble = CALayer()
    bubble.contents = snapshot.image.cgImage
    bubble.contentsScale = snapshot.image.scale
    bubble.frame = frame
    // Narrowing towards the middle of the bubble, not of the row.
    let anchor = CGPoint(x: (center.x - frame.minX) / max(1.0, frame.width), y: (center.y - frame.minY) / max(1.0, frame.height))
    bubble.anchorPoint = anchor
    bubble.position = center
    host.layer.addSublayer(bubble)

    if UIAccessibility.isReduceMotionEnabled {
        ignoreAddKeyframes(bubble, keyPath: "opacity", values: [1.0, 0.0], keyTimes: [0.0, 1.0], duration: 0.3, delay: delay)
        return end
    }

    // A little lift first, then drawn in: narrower and flatter, blurred, gone.
    ignoreAddKeyframes(bubble, keyPath: "transform.scale.x", values: [1.0, 1.04, 0.62, 0.12], keyTimes: [0.0, 0.14, 0.55, 1.0], duration: 0.72, delay: delay, timing: .easeIn)
    ignoreAddKeyframes(bubble, keyPath: "transform.scale.y", values: [1.0, 1.06, 0.7, 0.3], keyTimes: [0.0, 0.14, 0.55, 1.0], duration: 0.72, delay: delay, timing: .easeIn)
    ignoreAddKeyframes(bubble, keyPath: "opacity", values: [1.0, 1.0, 0.85, 0.0], keyTimes: [0.0, 0.3, 0.7, 1.0], duration: 0.72, delay: delay)
    if let blur = CALayer.blur() {
        blur.setValue(0.0 as NSNumber, forKey: "inputRadius")
        bubble.filters = [blur]
        ignoreAddKeyframes(bubble, keyPath: "filters.gaussianBlur.inputRadius", values: [0.0, 0.0, 6.0, 14.0], keyTimes: [0.0, 0.18, 0.6, 1.0], duration: 0.72, delay: delay, timing: .easeIn)
    }

    // The rest of it (its avatar) goes the same way.
    for (part, partFrame) in extra {
        let layer = CALayer()
        layer.contents = part.image.cgImage
        layer.contentsScale = part.image.scale
        layer.frame = partFrame
        host.layer.addSublayer(layer)
        ignoreAddKeyframes(layer, keyPath: "transform.scale", values: [1.0, 1.08, 0.2], keyTimes: [0.0, 0.2, 1.0], duration: 0.6, delay: delay + 0.08, timing: .easeIn)
        ignoreAddKeyframes(layer, keyPath: "opacity", values: [1.0, 1.0, 0.0], keyTimes: [0.0, 0.4, 1.0], duration: 0.6, delay: delay + 0.08)
        let target = CGPoint(x: center.x - layer.position.x, y: center.y - layer.position.y)
        ignoreAddKeyframes(layer, keyPath: "transform.translation", values: [NSValue(cgPoint: CGPoint()), NSValue(cgPoint: CGPoint(x: target.x * 0.35, y: target.y * 0.35))], keyTimes: [0.0, 1.0], duration: 0.6, delay: delay + 0.08, timing: .easeIn)
    }

    // Its pieces swirl into the eye.
    let pieces = snapshot.samples(count: 46)
    for (index, piece) in pieces.enumerated() {
        let start = CGPoint(x: frame.minX + piece.point.x, y: frame.minY + piece.point.y)
        let size = CGFloat.random(in: 2.0 ... 4.2)
        let layer = CALayer()
        layer.bounds = CGRect(x: 0.0, y: 0.0, width: size, height: size)
        layer.cornerRadius = size * (index % 3 == 0 ? 0.5 : 0.2)
        layer.backgroundColor = piece.color.cgColor
        layer.position = start
        layer.opacity = 0.0
        host.layer.addSublayer(layer)
        // A curved way in: out to the side first, then into the middle.
        let dx = center.x - start.x
        let dy = center.y - start.y
        let side: CGFloat = index % 2 == 0 ? 1.0 : -1.0
        let swirl = CGPoint(x: start.x + dx * 0.45 - dy * 0.35 * side, y: start.y + dy * 0.45 + dx * 0.12 * side - 10.0)
        let path = UIBezierPath()
        path.move(to: start)
        path.addQuadCurve(to: center, controlPoint: swirl)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path.cgPath
        move.duration = Double.random(in: 0.5 ... 0.7)
        move.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay + 0.1 + Double(index % 9) * 0.012
        move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        move.fillMode = .both
        move.isRemovedOnCompletion = false
        layer.add(move, forKey: "position")
        ignoreAddKeyframes(layer, keyPath: "opacity", values: [0.0, 1.0, 1.0, 0.0], keyTimes: [0.0, 0.15, 0.75, 1.0], duration: move.duration, delay: delay + 0.1 + Double(index % 9) * 0.012)
        ignoreAddKeyframes(layer, keyPath: "transform.scale", values: [1.3, 1.0, 0.3], keyTimes: [0.0, 0.4, 1.0], duration: move.duration, delay: delay + 0.1 + Double(index % 9) * 0.012)
    }

    // The eye: pops up, takes the message in, blinks, is crossed out, goes with a ring.
    let badge = IgnoreEffectBadge(style: style, isSlashed: false)
    badge.view.center = center
    host.addSubview(badge.view)
    badge.view.alpha = 0.0
    ignoreAddKeyframes(badge.view.layer, keyPath: "opacity", values: [0.0, 1.0, 1.0, 0.0], keyTimes: [0.0, 0.1, 0.82, 1.0], duration: 1.15, delay: delay + 0.06)
    ignoreAddKeyframes(badge.view.layer, keyPath: "transform.scale", values: [0.1, 1.25, 0.95, 1.0, 1.0, 1.28, 0.1], keyTimes: [0.0, 0.16, 0.26, 0.34, 0.7, 0.82, 1.0], duration: 1.15, delay: delay + 0.06)
    ignoreAddKeyframes(badge.view.layer, keyPath: "transform.rotation.z", values: [-0.6, 0.12, 0.0, 0.0, -0.25], keyTimes: [0.0, 0.2, 0.34, 0.8, 1.0], duration: 1.15, delay: delay + 0.06)
    badge.eye.blink(delay: delay + 0.62, duration: 0.24)
    badge.eye.setSlashed(true, animated: true, delay: delay + 0.74, duration: 0.2)
    ignoreRingBurst(in: host, center: center, color: style.badgeColor, radius: ignoreEffectBadgeSize * 0.5, delay: delay + 0.9)
    return end
}

/// A message coming back as someone is no longer ignored: the crossed out eye pops up where it will be, the slash comes
/// off and the eye opens, then the message comes out of it: pieces fly out to their places and the message unfolds out
/// of a blur, a little large, and settles. `node` is the message's own node (shown again at the end).
@discardableResult
public func ignorePlayReassemble(node: ASDisplayNode, snapshot: IgnoreSnapshot, in container: UIView, style: IgnoreEffectStyle, delay: Double) -> Double {
    let frame = node.view.convert(snapshot.rect, to: container)
    let host = UIView(frame: container.bounds)
    host.isUserInteractionEnabled = false
    container.addSubview(host)

    let content = snapshot.contentRect.offsetBy(dx: frame.minX, dy: frame.minY)
    let center = CGPoint(x: content.midX, y: content.midY)
    let end = delay + 1.3
    node.isHidden = true

    let bubble = CALayer()
    bubble.contents = snapshot.image.cgImage
    bubble.contentsScale = snapshot.image.scale
    bubble.frame = frame
    bubble.anchorPoint = CGPoint(x: (center.x - frame.minX) / max(1.0, frame.width), y: (center.y - frame.minY) / max(1.0, frame.height))
    bubble.position = center
    bubble.opacity = 0.0
    host.layer.addSublayer(bubble)

    // At the end the message itself takes over from the effect.
    DispatchQueue.main.asyncAfter(deadline: .now() + end, execute: { [weak host, weak node] in
        node?.isHidden = false
        host?.removeFromSuperview()
    })

    if UIAccessibility.isReduceMotionEnabled {
        ignoreAddKeyframes(bubble, keyPath: "opacity", values: [0.0, 1.0], keyTimes: [0.0, 1.0], duration: 0.3, delay: delay)
        return end
    }

    let open = delay + 0.42
    // The eye: pops up crossed out, the slash comes off, it opens; it goes as the message comes out.
    let badge = IgnoreEffectBadge(style: style, isSlashed: true)
    badge.view.center = center
    host.addSubview(badge.view)
    ignoreAddKeyframes(badge.view.layer, keyPath: "opacity", values: [0.0, 1.0, 1.0, 0.0], keyTimes: [0.0, 0.12, 0.6, 0.85], duration: 1.1, delay: delay)
    ignoreAddKeyframes(badge.view.layer, keyPath: "transform.scale", values: [0.1, 1.25, 0.95, 1.0, 1.3, 0.2], keyTimes: [0.0, 0.18, 0.3, 0.45, 0.6, 0.85], duration: 1.1, delay: delay)
    badge.eye.setSlashed(false, animated: true, delay: delay + 0.24, duration: 0.2)
    badge.eye.popIris(delay: delay + 0.4)
    ignoreRingBurst(in: host, center: center, color: style.badgeColor, radius: ignoreEffectBadgeSize * 0.5, delay: open)

    // The message unfolds out of the eye: from narrow and blurred to itself, a little large first.
    ignoreAddKeyframes(bubble, keyPath: "opacity", values: [0.0, 1.0, 1.0], keyTimes: [0.0, 0.25, 1.0], duration: 0.8, delay: open)
    ignoreAddKeyframes(bubble, keyPath: "transform.scale.x", values: [0.12, 0.7, 1.06, 0.98, 1.0], keyTimes: [0.0, 0.3, 0.6, 0.82, 1.0], duration: 0.8, delay: open, timing: .easeOut)
    ignoreAddKeyframes(bubble, keyPath: "transform.scale.y", values: [0.3, 0.75, 1.08, 0.98, 1.0], keyTimes: [0.0, 0.3, 0.6, 0.82, 1.0], duration: 0.8, delay: open, timing: .easeOut)
    if let blur = CALayer.blur() {
        blur.setValue(0.0 as NSNumber, forKey: "inputRadius")
        bubble.filters = [blur]
        ignoreAddKeyframes(bubble, keyPath: "filters.gaussianBlur.inputRadius", values: [14.0, 5.0, 0.0, 0.0], keyTimes: [0.0, 0.35, 0.65, 1.0], duration: 0.8, delay: open, timing: .easeOut)
    }

    // Its pieces fly out of the eye to their places.
    let pieces = snapshot.samples(count: 40)
    for (index, piece) in pieces.enumerated() {
        let target = CGPoint(x: frame.minX + piece.point.x, y: frame.minY + piece.point.y)
        let size = CGFloat.random(in: 2.0 ... 4.0)
        let layer = CALayer()
        layer.bounds = CGRect(x: 0.0, y: 0.0, width: size, height: size)
        layer.cornerRadius = size * (index % 3 == 0 ? 0.5 : 0.2)
        layer.backgroundColor = piece.color.cgColor
        layer.position = target
        layer.opacity = 0.0
        host.layer.addSublayer(layer)
        let dx = target.x - center.x
        let dy = target.y - center.y
        let side: CGFloat = index % 2 == 0 ? 1.0 : -1.0
        let control = CGPoint(x: center.x + dx * 0.55 + dy * 0.3 * side, y: center.y + dy * 0.55 - dx * 0.1 * side - 12.0)
        let path = UIBezierPath()
        path.move(to: center)
        path.addQuadCurve(to: target, controlPoint: control)
        let pieceDelay = open - 0.04 + Double(index % 9) * 0.012
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path.cgPath
        move.duration = Double.random(in: 0.42 ... 0.6)
        move.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + pieceDelay
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        move.fillMode = .both
        move.isRemovedOnCompletion = false
        layer.add(move, forKey: "position")
        ignoreAddKeyframes(layer, keyPath: "opacity", values: [0.0, 1.0, 1.0, 0.0], keyTimes: [0.0, 0.15, 0.7, 1.0], duration: move.duration, delay: pieceDelay)
        ignoreAddKeyframes(layer, keyPath: "transform.scale", values: [0.3, 1.2, 0.8], keyTimes: [0.0, 0.5, 1.0], duration: move.duration, delay: pieceDelay)
    }
    return end
}
