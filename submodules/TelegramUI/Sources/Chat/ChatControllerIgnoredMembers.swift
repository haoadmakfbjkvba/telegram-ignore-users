import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState
import ContextUI
import UndoUI
import ChatMessageItemView
import ChatMessageItemImpl
import IgnoredMembers

/// What a group chat knows of the people ignored in groups: whose messages are hidden here (for the line under the
/// header), and whose messages are coming back.
final class ChatControllerIgnoredMembersState {
    var hiddenPeersDisposable: Disposable?
    /// The history node the line follows (the chat's node can change it).
    weak var subscribedHistoryNode: ChatHistoryListNodeImpl?
    /// The people whose messages are hidden here, the most recently ignored first. Once someone is in the line they
    /// stay there while the chat is open (also when their messages scroll out of the loaded part), until they are
    /// brought back.
    var hiddenPeers: [EnginePeer] = []
    let shownPeerIds = Atomic<Set<EnginePeer.Id>>(value: Set())
    /// Those the line has introduced itself for (it does so once, not each time it comes back after a search).
    var introducedPeerIds = Set<EnginePeer.Id>()
    /// The messages that are coming back (of someone no longer ignored), until they have appeared.
    var revealingMessageIds = Set<EngineMessage.Id>()
    var revealingAuthorId: EnginePeer.Id?
    var revealingUntil: Double = 0.0
    /// Where the effects are drawn: over the messages, under everything else.
    var overlayView: UIView?

    deinit {
        self.hiddenPeersDisposable?.dispose()
    }
}

extension ChatControllerImpl {
    private var ignoreEffectStyle: IgnoreEffectStyle {
        return IgnoreEffectStyle(badgeColor: self.presentationData.theme.list.itemAccentColor, glyphColor: .white)
    }

    /// The view the effects are drawn in, just over the messages.
    private func ignoreOverlayView() -> UIView? {
        guard self.isNodeLoaded else {
            return nil
        }
        let historyView = self.chatDisplayNode.historyNode.view
        guard let superview = historyView.superview else {
            return nil
        }
        let state = self.ignoredMembersState
        if let overlay = state.overlayView, overlay.superview === superview {
            overlay.frame = superview.bounds
            return overlay
        }
        state.overlayView?.removeFromSuperview()
        let overlay = UIView(frame: superview.bounds)
        overlay.isUserInteractionEnabled = false
        overlay.clipsToBounds = true
        superview.insertSubview(overlay, aboveSubview: historyView)
        state.overlayView = overlay
        return overlay
    }

    // MARK: - Ignoring

    /// Starts ignoring `peer` from the menu of their message `sourceMessageId`: once the menu has gone, their messages
    /// on screen are drawn into eyes that close, one after another out from that message, and then leave the chat.
    func ignoreAuthor(_ peer: EnginePeer, sourceMessageId: EngineMessage.Id) {
        let accountPeerId = self.context.account.peerId
        Queue.mainQueue().after(0.3, { [weak self] in
            guard let self else {
                // The chat was closed meanwhile: they are ignored all the same.
                IgnoredMembers.shared.set(peer.id, isIgnored: true, accountPeerId: accountPeerId)
                return
            }
            self.playIgnore(peer, sourceMessageId: sourceMessageId)
        })
    }

    private func playIgnore(_ peer: EnginePeer, sourceMessageId: EngineMessage.Id) {
        let accountPeerId = self.context.account.peerId
        guard let overlay = self.ignoreOverlayView() else {
            IgnoredMembers.shared.set(peer.id, isIgnored: true, accountPeerId: accountPeerId)
            return
        }
        let historyNode = self.chatDisplayNode.historyNode

        // Their messages on screen (the parts of them on screen), and their avatars; the rest are hidden at once (as
        // the list closes up they would come into view while they go).
        var parts: [(node: ChatMessageItemView, snapshot: IgnoreSnapshot, frame: CGRect, isSource: Bool)] = []
        var hiddenNodes: [ASDisplayNode] = []
        historyNode.forEachItemNode { node in
            guard let itemNode = node as? ChatMessageItemView, let item = itemNode.item, item.message.author?.id == peer.id else {
                return
            }
            hiddenNodes.append(itemNode)
            let visibleRect = overlay.convert(overlay.bounds, to: itemNode.view).intersection(itemNode.view.bounds)
            if itemNode.view.window != nil, !visibleRect.isEmpty, let snapshot = IgnoreSnapshot.take(of: itemNode.view, in: visibleRect) {
                let frame = itemNode.view.convert(snapshot.rect, to: overlay)
                let isSource = item.content.contains(where: { $0.0.id == sourceMessageId })
                parts.append((itemNode, snapshot, frame, isSource))
            }
        }
        var avatars: [(snapshot: IgnoreSnapshot, frame: CGRect)] = []
        historyNode.forEachItemHeaderNode { headerNode in
            guard let avatarNode = headerNode as? ChatMessageAvatarHeaderNodeImpl, avatarNode.avatarPeerId == peer.id else {
                return
            }
            hiddenNodes.append(avatarNode)
            let frame = avatarNode.view.convert(avatarNode.view.bounds, to: overlay)
            if frame.intersects(overlay.bounds), let snapshot = IgnoreSnapshot.take(of: avatarNode.view) {
                avatars.append((snapshot, frame))
            }
        }
        // Hidden, not made transparent: the list sets the opacity of its nodes as it moves them.
        for node in hiddenNodes {
            node.isHidden = true
        }

        // Out from the message the menu was opened on, nearest first.
        let sourceY = parts.first(where: { $0.isSource })?.frame.midY ?? overlay.bounds.midY
        let ordered = parts.sorted(by: { abs($0.frame.midY - sourceY) < abs($1.frame.midY - sourceY) })
        let step = 0.085
        // Each avatar goes with the message of theirs nearest to it.
        var extras: [Int: [(snapshot: IgnoreSnapshot, frame: CGRect)]] = [:]
        for avatar in avatars {
            if let index = ordered.indices.min(by: { abs(ordered[$0].frame.maxY - avatar.frame.maxY) < abs(ordered[$1].frame.maxY - avatar.frame.maxY) }) {
                extras[index, default: []].append(avatar)
            }
        }
        for (index, part) in ordered.enumerated() {
            ignorePlayDissolve(snapshot: part.snapshot, frame: part.frame, extra: extras[index] ?? [], in: overlay, style: self.ignoreEffectStyle, delay: Double(index) * step)
        }
        if !ordered.isEmpty {
            HapticFeedback().impact(.light)
        }

        // Once the last of them has gone into its eye, they leave the chat for good.
        let leaveAfter = ordered.isEmpty ? 0.0 : Double(ordered.count - 1) * step + 0.8
        Queue.mainQueue().after(leaveAfter, { [weak self] in
            IgnoredMembers.shared.set(peer.id, isIgnored: true, accountPeerId: accountPeerId)
            // By now their nodes have left the list; any still in it show again (they are no longer ignored, after Undo,
            // or their message is one that stays).
            Queue.mainQueue().after(1.0, {
                let ignored = Set(IgnoredMembers.shared.list(accountPeerId: accountPeerId))
                for node in hiddenNodes where node.supernode != nil {
                    if let itemNode = node as? ChatMessageItemView, let message = itemNode.item?.message, IgnoredMembers.hides(message: message, ignored: ignored) {
                        continue
                    }
                    node.isHidden = false
                }
            })
            guard let self else {
                return
            }
            let strings = self.presentationData.strings
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .actionSucceeded(title: strings.IgnoredMembers_ToastIgnoredTitle(peer.compactDisplayTitle).string, text: strings.IgnoredMembers_ToastIgnoredText, cancel: strings.Undo_Undo, destructive: false), elevatedLayout: false, action: { [weak self] action in
                if case .undo = action {
                    self?.stopIgnoring(peer)
                }
                return false
            }), in: .current)
        })
    }

    // MARK: - Bringing back

    /// Stops ignoring `peer`: their messages come back, each out of an eye that opens.
    func stopIgnoring(_ peer: EnginePeer) {
        let state = self.ignoredMembersState
        if self.isNodeLoaded {
            // Only these messages come in with the effect, as they appear.
            state.revealingMessageIds = self.chatDisplayNode.historyNode.loadedMessageIds(authorId: peer.id)
            state.revealingAuthorId = peer.id
            state.revealingUntil = CACurrentMediaTime() + 1.5
        }
        IgnoredMembers.shared.set(peer.id, isIgnored: false, accountPeerId: self.context.account.peerId)
    }

    /// An update of the history is in place (its nodes are not yet on screen): the messages coming back that it shows
    /// come in with the effect.
    func ignoredMembersHistoryTransitionApplied() {
        let state = self.ignoredMembersState
        guard !state.revealingMessageIds.isEmpty, let authorId = state.revealingAuthorId else {
            return
        }
        guard CACurrentMediaTime() < state.revealingUntil, let overlay = self.ignoreOverlayView() else {
            state.revealingMessageIds.removeAll()
            state.revealingAuthorId = nil
            return
        }
        let historyNode = self.chatDisplayNode.historyNode
        var nodes: [ChatMessageItemView] = []
        historyNode.forEachVisibleMessageItemNode { itemNode in
            guard let item = itemNode.item, item.content.contains(where: { state.revealingMessageIds.contains($0.0.id) }) else {
                return
            }
            let frame = itemNode.view.convert(itemNode.view.bounds, to: overlay)
            if frame.intersects(overlay.bounds) {
                nodes.append(itemNode)
            }
        }
        guard !nodes.isEmpty else {
            // Not in this update.
            return
        }
        // Each comes in once.
        state.revealingMessageIds.removeAll()
        state.revealingAuthorId = nil
        for node in nodes {
            node.isHidden = true
        }
        var avatarNodes: [ASDisplayNode] = []
        historyNode.forEachItemHeaderNode { headerNode in
            if let avatarNode = headerNode as? ChatMessageAvatarHeaderNodeImpl, avatarNode.avatarPeerId == authorId {
                avatarNode.isHidden = true
                avatarNodes.append(avatarNode)
            }
        }
        let style = self.ignoreEffectStyle
        // Once they have been laid out (they are drawn for the effect before they are shown), top to bottom.
        Queue.mainQueue().after(0.12, { [weak overlay] in
            guard let overlay else {
                for node in nodes {
                    node.isHidden = false
                }
                for node in avatarNodes {
                    node.isHidden = false
                }
                return
            }
            let ordered = nodes.sorted(by: { $0.view.convert($0.view.bounds, to: overlay).minY < $1.view.convert($1.view.bounds, to: overlay).minY })
            for (index, node) in ordered.enumerated() {
                let visibleRect = overlay.convert(overlay.bounds, to: node.view).intersection(node.view.bounds)
                guard node.view.window != nil, !visibleRect.isEmpty, let snapshot = IgnoreSnapshot.take(of: node.view, in: visibleRect, renderLayer: true) else {
                    node.isHidden = false
                    continue
                }
                ignorePlayReassemble(node: node, snapshot: snapshot, in: overlay, style: style, delay: Double(index) * 0.085)
            }
            if !ordered.isEmpty {
                HapticFeedback().impact(.light)
            }
            // The avatars come back with their messages, popping in.
            for node in avatarNodes {
                node.isHidden = false
                if !UIAccessibility.isReduceMotionEnabled {
                    node.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3, delay: 0.55)
                    node.layer.animateSpring(from: 0.3 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.55, damping: 60.0)
                }
            }
        })
    }

    // MARK: - The line under the header

    /// The line for `interfaceState`, set on the chat's node. Returns whether it appeared, went or changed.
    func updateIgnoredMembersPanel(interfaceState: ChatPresentationInterfaceState) -> Bool {
        let state = self.ignoredMembersState
        if self.isNodeLoaded, state.subscribedHistoryNode !== self.chatDisplayNode.historyNode {
            let context = self.context
            let accountPeerId = context.account.peerId
            let historyNode = self.chatDisplayNode.historyNode
            state.subscribedHistoryNode = historyNode
            state.hiddenPeersDisposable?.dispose()
            historyNode.historyTransitionApplied = { [weak self] in
                self?.ignoredMembersHistoryTransitionApplied()
            }
            let shownPeerIds = state.shownPeerIds
            state.hiddenPeersDisposable = (combineLatest(historyNode.ignoredHiddenAuthors, IgnoredMembers.shared.signal(accountPeerId: accountPeerId))
            |> map { counts, ignored -> [EnginePeer.Id] in
                // Those whose messages are hidden here, and those already in the line while they are still ignored; in
                // the order they were ignored, the most recent first.
                let shown = shownPeerIds.modify { current in
                    return current.filter { ignored.contains($0) }.union(counts.keys.filter { ignored.contains($0) })
                }
                return IgnoredMembers.shared.list(accountPeerId: accountPeerId).filter { shown.contains($0) }
            }
            |> distinctUntilChanged
            |> mapToSignal { ids -> Signal<[EnginePeer], NoError> in
                return context.engine.data.get(EngineDataList(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:))))
                |> map { peers -> [EnginePeer] in
                    return peers.compactMap { $0 }
                }
            }
            |> deliverOnMainQueue).startStrict(next: { [weak self] peers in
                guard let self else {
                    return
                }
                self.ignoredMembersState.hiddenPeers = peers
                self.updateChatPresentationInterfaceState(animated: true, interactive: false, { $0 })
            })
        }

        var panel: IgnoredChatPanelComponent?
        if !state.hiddenPeers.isEmpty, interfaceState.search == nil, interfaceState.interfaceState.selectionState == nil {
            // It introduces itself for people it has not shown yet in this chat.
            let peerIds = Set(state.hiddenPeers.map(\.id))
            let introduces = !peerIds.isSubset(of: state.introducedPeerIds)
            panel = IgnoredChatPanelComponent(
                theme: interfaceState.theme,
                strings: interfaceState.strings,
                names: state.hiddenPeers.map { $0.compactDisplayTitle },
                introduces: introduces,
                action: { [weak self] view in
                    self?.presentIgnoredMembersMenu(sourceView: view)
                }
            )
        }
        guard self.chatDisplayNode.ignoredMembersPanel != panel else {
            return false
        }
        if let panel, panel.introduces {
            state.introducedPeerIds.formUnion(state.hiddenPeers.map(\.id))
        }
        self.chatDisplayNode.ignoredMembersPanel = panel
        return true
    }

    /// The menu of the line under the header: bring back each of the people hidden here, or see all who are ignored.
    private func presentIgnoredMembersMenu(sourceView: UIView) {
        let strings = self.presentationData.strings
        var items: [ContextMenuItem] = []
        for peer in self.ignoredMembersState.hiddenPeers {
            items.append(.custom(IgnoreMenuItem(kind: .stopIgnoring, title: strings.IgnoredMembers_StopIgnoring(peer.compactDisplayTitle).string, action: { [weak self] in
                self?.stopIgnoring(peer)
            }), false))
        }
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: strings.IgnoredMembers_ListTitle, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Eye"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.dismissWithoutContent)
            guard let self else {
                return
            }
            self.effectiveNavigationController?.pushViewController(ignoredMembersController(context: self.context))
        })))
        let contextController = makeContextController(
            presentationData: self.presentationData,
            source: .reference(ChatControllerContextReferenceContentSource(controller: self, sourceView: sourceView, insets: .zero, actionsOnTop: false)),
            items: .single(ContextController.Items(content: .list(items))),
            gesture: nil
        )
        self.chatDisplayNode.dismissInput()
        self.presentInGlobalOverlay(contextController)
    }
}
