import Foundation
import SwiftSignalKit
import TelegramCore

/// The people an account ignores in groups: their messages are hidden for it in every group and in the comments of
/// channels. Only this device knows (the people ignored are not told, nothing is sent anywhere). Safe from any thread.
public final class IgnoredMembers {
    public static let shared = IgnoredMembers()

    private let lock = NSLock()
    private var peerIds: [EnginePeer.Id: [EnginePeer.Id]] = [:]
    private var promises: [EnginePeer.Id: ValuePromise<Set<EnginePeer.Id>>] = [:]

    private static func key(accountPeerId: EnginePeer.Id) -> String {
        return "IgnoredMembers.\(accountPeerId.toInt64())"
    }

    /// The ignored people of an account, the most recently ignored first. The caller holds the lock.
    private func loadedPeerIds(accountPeerId: EnginePeer.Id) -> [EnginePeer.Id] {
        if let current = self.peerIds[accountPeerId] {
            return current
        }
        let stored = (UserDefaults.standard.array(forKey: IgnoredMembers.key(accountPeerId: accountPeerId)) as? [NSNumber]) ?? []
        let loaded = stored.map { EnginePeer.Id($0.int64Value) }
        self.peerIds[accountPeerId] = loaded
        return loaded
    }

    /// The ignored people of an account, the most recently ignored first.
    public func list(accountPeerId: EnginePeer.Id) -> [EnginePeer.Id] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.loadedPeerIds(accountPeerId: accountPeerId)
    }

    public func isIgnored(_ peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> Bool {
        return self.list(accountPeerId: accountPeerId).contains(peerId)
    }

    /// The ignored people of an account, now and as they change.
    public func signal(accountPeerId: EnginePeer.Id) -> Signal<Set<EnginePeer.Id>, NoError> {
        self.lock.lock()
        let promise: ValuePromise<Set<EnginePeer.Id>>
        if let current = self.promises[accountPeerId] {
            promise = current
        } else {
            promise = ValuePromise(Set(self.loadedPeerIds(accountPeerId: accountPeerId)), ignoreRepeated: true)
            self.promises[accountPeerId] = promise
        }
        self.lock.unlock()
        return promise.get()
    }

    /// Starts or stops ignoring `peerId` (never the account itself).
    public func set(_ peerId: EnginePeer.Id, isIgnored: Bool, accountPeerId: EnginePeer.Id) {
        guard peerId != accountPeerId else {
            return
        }
        self.lock.lock()
        var list = self.loadedPeerIds(accountPeerId: accountPeerId)
        list.removeAll(where: { $0 == peerId })
        if isIgnored {
            list.insert(peerId, at: 0)
        }
        self.peerIds[accountPeerId] = list
        UserDefaults.standard.set(list.map { NSNumber(value: $0.toInt64()) }, forKey: IgnoredMembers.key(accountPeerId: accountPeerId))
        let promise = self.promises[accountPeerId]
        self.lock.unlock()
        promise?.set(Set(list))
    }

    /// Whether ignoring someone hides their messages in the chat `chatPeerId` (`channel`, if it is one): in groups and
    /// in the comments of channels; never in a private chat, a channel's own posts or a channel's direct messages.
    public static func applies(in chatPeerId: EnginePeer.Id, channel: TelegramChannel?) -> Bool {
        if chatPeerId.namespace == Namespaces.Peer.CloudGroup {
            return true
        }
        guard chatPeerId.namespace == Namespaces.Peer.CloudChannel else {
            return false
        }
        if let channel {
            if case .broadcast = channel.info {
                return false
            }
            if channel.flags.contains(.isMonoforum) {
                return false
            }
        }
        return true
    }

    /// Whether `message` is hidden: its author (who posted it, also a forward) is ignored and it is in a chat where
    /// ignoring applies. `chatChannel` is the chat, if it is a channel and known (else it is looked up in the message).
    public static func hides(message: EngineRawMessage, chatChannel: TelegramChannel? = nil, ignored: Set<EnginePeer.Id>) -> Bool {
        guard !ignored.isEmpty, let authorId = message.author?.id, authorId.namespace == Namespaces.Peer.CloudUser, ignored.contains(authorId) else {
            return false
        }
        let chatPeerId = message.id.peerId
        return IgnoredMembers.applies(in: chatPeerId, channel: chatChannel ?? (message.peers[chatPeerId] as? TelegramChannel))
    }
}
