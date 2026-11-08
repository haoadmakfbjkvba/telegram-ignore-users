import Foundation
import UIKit
import Display

/// Keyframes that start after `delay` and hold their first value until then and their last one after.
public func ignoreAddKeyframes(_ layer: CALayer, keyPath: String, values: [Any], keyTimes: [NSNumber], duration: Double, delay: Double, timing: CAMediaTimingFunctionName = .easeInEaseOut) {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values
    animation.keyTimes = keyTimes
    animation.duration = duration
    animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
    animation.fillMode = .both
    animation.isRemovedOnCompletion = false
    animation.timingFunction = CAMediaTimingFunction(name: timing)
    layer.add(animation, forKey: keyPath)
}
