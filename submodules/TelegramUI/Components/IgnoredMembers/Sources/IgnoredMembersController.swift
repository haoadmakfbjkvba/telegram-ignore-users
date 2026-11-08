import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import ItemListPeerItem

private final class IgnoredMembersControllerArguments {
    let context: AccountContext
    let setPeerIdWithRevealedOptions: (EnginePeer.Id?, EnginePeer.Id?) -> Void
    let stopIgnoring: (EnginePeer.Id) -> Void
    let openPeer: (EnginePeer) -> Void

    init(context: AccountContext, setPeerIdWithRevealedOptions: @escaping (EnginePeer.Id?, EnginePeer.Id?) -> Void, stopIgnoring: @escaping (EnginePeer.Id) -> Void, openPeer: @escaping (EnginePeer) -> Void) {
        self.context = context
        self.setPeerIdWithRevealedOptions = setPeerIdWithRevealedOptions
        self.stopIgnoring = stopIgnoring
        self.openPeer = openPeer
    }
}

private enum IgnoredMembersSection: Int32 {
    case peers
}

private enum IgnoredMembersEntry: ItemListNodeEntry {
    case peer(Int32, PresentationStrings, PresentationDateTimeFormat, PresentationPersonNameOrder, EnginePeer, ItemListPeerItemEditing)
    case info(String)

    var section: ItemListSectionId {
        return IgnoredMembersSection.peers.rawValue
    }

    var stableId: AnyHashable {
        switch self {
        case let .peer(_, _, _, _, peer, _):
            return AnyHashable(peer.id)
        case .info:
            return AnyHashable("info")
        }
    }

    private var sortIndex: Int32 {
        switch self {
        case let .peer(index, _, _, _, _, _):
            return index
        case .info:
            return Int32.max
        }
    }

    static func ==(lhs: IgnoredMembersEntry, rhs: IgnoredMembersEntry) -> Bool {
        switch lhs {
        case let .peer(lhsIndex, lhsStrings, lhsFormat, lhsOrder, lhsPeer, lhsEditing):
            if case let .peer(rhsIndex, rhsStrings, rhsFormat, rhsOrder, rhsPeer, rhsEditing) = rhs {
                return lhsIndex == rhsIndex && lhsStrings === rhsStrings && lhsFormat == rhsFormat && lhsOrder == rhsOrder && lhsPeer == rhsPeer && lhsEditing == rhsEditing
            }
            return false
        case let .info(text):
            if case .info(text) = rhs {
                return true
            }
            return false
        }
    }

    static func <(lhs: IgnoredMembersEntry, rhs: IgnoredMembersEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IgnoredMembersControllerArguments
        switch self {
        case let .peer(_, strings, dateTimeFormat, nameDisplayOrder, peer, editing):
            let revealOptions = ItemListPeerItemRevealOptions(options: [ItemListPeerItemRevealOption(type: .accent, title: strings.IgnoredMembers_StopIgnoringShort, action: {
                arguments.stopIgnoring(peer.id)
            })])
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: dateTimeFormat, nameDisplayOrder: nameDisplayOrder, context: arguments.context, peer: peer, presence: nil, text: .none, label: .none, editing: editing, revealOptions: revealOptions, switchValue: nil, enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.openPeer(peer)
            }, setPeerIdWithRevealedOptions: { previousId, id in
                arguments.setPeerIdWithRevealedOptions(previousId, id)
            }, removePeer: { peerId in
                arguments.stopIgnoring(peerId)
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct IgnoredMembersControllerState: Equatable {
    var editing = false
    var peerIdWithRevealedOptions: EnginePeer.Id?
}

/// Settings → Privacy and Security → Ignored in Groups: the people whose messages are hidden in groups, each of whom
/// can be brought back.
public func ignoredMembersController(context: AccountContext) -> ViewController {
    let accountPeerId = context.account.peerId
    let statePromise = ValuePromise(IgnoredMembersControllerState(), ignoreRepeated: true)
    let stateValue = Atomic(value: IgnoredMembersControllerState())
    let updateState: ((IgnoredMembersControllerState) -> IgnoredMembersControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = IgnoredMembersControllerArguments(context: context, setPeerIdWithRevealedOptions: { peerId, fromPeerId in
        updateState { state in
            var state = state
            if (peerId == nil && fromPeerId == state.peerIdWithRevealedOptions) || (peerId != nil && fromPeerId == nil) {
                state.peerIdWithRevealedOptions = peerId
            }
            return state
        }
    }, stopIgnoring: { peerId in
        IgnoredMembers.shared.set(peerId, isIgnored: false, accountPeerId: accountPeerId)
    }, openPeer: { peer in
        if let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) {
            pushControllerImpl?(controller)
        }
    })

    // The ignored people, in the order they were ignored (the most recent first).
    let peers: Signal<[EnginePeer], NoError> = IgnoredMembers.shared.signal(accountPeerId: accountPeerId)
    |> mapToSignal { _ -> Signal<[EnginePeer], NoError> in
        let ids = IgnoredMembers.shared.list(accountPeerId: accountPeerId)
        return context.engine.data.subscribe(EngineDataList(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:))))
        |> map { peers -> [EnginePeer] in
            return peers.compactMap { $0 }
        }
    }

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get(), peers)
    |> deliverOnMainQueue
    |> map { presentationData, state, peers -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var rightNavigationButton: ItemListNavigationButton?
        if !peers.isEmpty {
            if state.editing {
                rightNavigationButton = ItemListNavigationButton(content: .icon(.done), style: .bold, enabled: true, staysInRow: true, action: {
                    updateState { state in
                        var state = state
                        state.editing = false
                        return state
                    }
                })
            } else {
                rightNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Edit), style: .regular, enabled: true, action: {
                    updateState { state in
                        var state = state
                        state.editing = true
                        return state
                    }
                })
            }
        }
        var entries: [IgnoredMembersEntry] = []
        for (index, peer) in peers.enumerated() {
            entries.append(.peer(Int32(index), presentationData.strings, presentationData.dateTimeFormat, presentationData.nameDisplayOrder, peer, ItemListPeerItemEditing(editable: true, editing: state.editing, revealed: peer.id == state.peerIdWithRevealedOptions)))
        }
        if !peers.isEmpty {
            entries.append(.info(presentationData.strings.IgnoredMembers_ListInfo))
        }
        let emptyStateItem: ItemListControllerEmptyStateItem? = peers.isEmpty ? ItemListTextEmptyStateItem(text: presentationData.strings.IgnoredMembers_ListEmpty) : nil
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.IgnoredMembers_ListTitle), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: true)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: emptyStateItem, animateChanges: true, scrollEnabled: emptyStateItem == nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}
