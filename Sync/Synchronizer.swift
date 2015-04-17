/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage
import UIKit
import XCGLogger

// TODO: same comment as for SyncAuthState.swift!
private let log = XCGLogger.defaultInstance()

public typealias Success = Deferred<Result<()>>

private func succeed() -> Success {
    return deferResult(())
}

// TODO: return values?
/**
 * A Synchronizer is (unavoidably) entirely in charge of what it does within a sync.
 * For example, it might make incremental progress in building a local cache of remote records, never actually performing an upload or modifying local storage.
 * It might only upload data. Etc.
 *
 * Eventually I envision an intent-like approach, or additional methods, to specify preferences and constraints
 * (e.g., "do what you can in a few seconds", or "do a full sync, no matter how long it takes"), but that'll come in time.
 *
 * A Synchronizer is a two-stage beast. It needs to support synchronization, of course; that
 * needs a completely configured client, which can only be obtained from Ready. But it also
 * needs to be able to do certain things beforehand:
 *
 * * Wipe its collections from the server (presumably via a delegate from the state machine).
 * * Prepare to sync from scratch ("reset") in response to a changed set of keys, syncID, or node assignment.
 * * Wipe local storage ("wipeClient").
 *
 * Those imply that some kind of 'Synchronizer' exists throughout the state machine. We *could*
 * pickle instructions for eventual delivery next time one is made and synchronized…
 */
public protocol Synchronizer {
    init(scratchpad: Scratchpad, basePrefs: Prefs)
    //func synchronize(client: Sync15StorageClient, info: InfoCollections) -> Deferred<Result<Scratchpad>>
}

public class FatalError: SyncError {
    let message: String
    init(message: String) {
        self.message = message
    }

    public var description: String {
        return self.message
    }
}

// TODO
public protocol Command {
    init?(command: String, args: [JSON])
    func run() -> Success
}

// Shit.
// We need a way to wipe or reset engines.
// We need a way to log out the account.
// So when we sync commands, we're gonna need a delegate of some kind.
public class WipeCommand: Command {
    public required init?(command: String, args: [JSON]) {
        return nil
    }

    public func run() -> Success {
        return succeed()
    }
}

public class DisplayURICommand: Command {
    let uri: NSURL
    // clientID: we don't care.
    let title: String

    public required init?(command: String, args: [JSON]) {
        if let uri = args[0].asString?.asURL,
               title = args[2].asString {
            self.uri = uri
            self.title = title
        } else {
            // Oh, Swift.
            self.uri = "http://localhost/".asURL!
            self.title = ""
            return nil
        }
    }

    public func run() -> Success {
        // TODO: localize.
        let app = UIApplication.sharedApplication()
        let notification = UILocalNotification()
        notification.alertTitle = "New tab: \(title)"
        notification.alertBody = uri.absoluteString!
        notification.alertAction = nil

        // TODO: put the URL into the alert userInfo.
        // TODO: application:didFinishLaunchingWithOptions:
        // TODO:
        // TODO: set additionalActions to bookmark or add to reading list.
        app.presentLocalNotificationNow(notification)
        return succeed()
    }
}

let Commands = [
    "wipeAll": WipeCommand.self,
    "wipeEngine": WipeCommand.self,
    // resetEngine
    // resetAll
    // logout
    "displayURI": DisplayURICommand.self,
]

public protocol SingleCollectionSynchronizer {
    func remoteHasChanges(info: InfoCollections) -> Bool
}

public class BaseSingleCollectionSynchronizer: SingleCollectionSynchronizer {
    let collection: String
    private let scratchpad: Scratchpad
    private let prefs: Prefs

    init(scratchpad: Scratchpad, basePrefs: Prefs, collection: String) {
        self.collection = collection
        self.scratchpad = scratchpad
        let branchName = "synchronizer." + collection + "."
        self.prefs = basePrefs.branch(branchName)

        log.info("Synchronizer configured with prefs \(branchName).")
    }

    var lastFetched: Timestamp {
        set(value) {
            self.prefs.setLong(value, forKey: "lastFetched")
        }

        get {
            return self.prefs.unsignedLongForKey("lastFetched") ?? 0
        }
    }

    public func remoteHasChanges(info: InfoCollections) -> Bool {
        return info.modified(self.collection) > self.lastFetched
    }
}

public class ClientsSynchronizer: BaseSingleCollectionSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, basePrefs: Prefs) {
        super.init(scratchpad: scratchpad, basePrefs: basePrefs, collection: "clients")
    }

    private func clientRecordToLocalClientEntry(record: Record<ClientPayload>) -> RemoteClient {
        let modified = record.modified
        let payload = record.payload
        return RemoteClient(json: payload, modified: modified)
    }

    // If this is a fresh start, do a wipe.
    // N.B., we don't wipe outgoing commands! (TODO: check this when we implement commands!)
    // N.B., but perhaps we should discard outgoing wipe/reset commands!
    private func wipeIfNecessary(localClients: RemoteClientsAndTabs) -> Success {
        if self.lastFetched == 0 {
            return localClients.wipeClients()
        }
        return succeed()
    }

    private func processCommands(commands: [JSON]) -> Success {
        if commands.isEmpty {
            return succeed()
        }

        func parse(json: JSON) -> Command? {
            if let name = json["command"].asString,
                   args = json["args"].asArray,
                   constructor = Commands[name] {
                return constructor(command: name, args: args)
            }
            return nil
        }

        let commands = optFilter(commands.map(parse))

        // TODO: run commands.
        commands
        return succeed()
    }

    private func processCommandsFromRecord(record: Record<ClientPayload>?, withServer storageClient: Sync15StorageClient) -> Success {
        // TODO: process commands.
        // TODO: upload a replacement record if we need to override commands.
        // TODO: short-circuit based on the modified time of the record we uploaded, so we don't need to skip ahead.
        if let record = record {
            return processCommands(record.payload.commands)
        }
        return succeed()
    }

    private func applyStorageResponse(response: StorageResponse<[Record<ClientPayload>]>, toLocalClients localClients: RemoteClientsAndTabs, withServer storageClient: Sync15StorageClient) -> Success {
        // TODO: decide whether to upload ours.

        let records = response.value
        let responseTimestamp = response.metadata.lastModifiedMilliseconds

        func updateMetadata() -> Success {
            self.lastFetched = responseTimestamp!
            return succeed()
        }

        log.debug("Got \(records.count) client records.")

        let ourGUID = self.scratchpad.clientGUID
        var toInsert = [RemoteClient]()
        var ours: Record<ClientPayload>? = nil

        for (rec) in records {
            if rec.id == ourGUID {
                ours = rec
            } else {
                toInsert.append(self.clientRecordToLocalClientEntry(rec))
            }
        }

        return localClients.insertOrUpdateClients(toInsert)
          >>== { self.processCommandsFromRecord(ours, withServer: storageClient) }
          >>== updateMetadata
    }

    // TODO: return whether or not the sync should continue.
    public func synchronizeLocalClients(localClients: RemoteClientsAndTabs, withServer storageClient: Sync15StorageClient, info: InfoCollections) -> Success {

        if !self.remoteHasChanges(info) {
            // Nothing to do.
            // TODO: upload local client if necessary.
            // TODO: move client upload timestamp out of Scratchpad.
            log.debug("No remote changes for clients. (Last fetched \(self.lastFetched).)")
            return succeed()
        }

        let factory: ((String) -> ClientPayload?)? = self.scratchpad.keys?.value.factory(self.collection, f: { ClientPayload($0) })
        if factory == nil {
            log.error("Couldn't make clients factory.")
            return deferResult(FatalError(message: "Couldn't make clients factory."))
        }

        let clientsClient = storageClient.clientForCollection(self.collection, factory: factory!)
        return clientsClient.getSince(self.lastFetched)
          >>== { response in
            return self.wipeIfNecessary(localClients)
               >>> {
                self.applyStorageResponse(response, toLocalClients: localClients, withServer: storageClient)
            }
        }
    }
}

public class TabsSynchronizer: BaseSingleCollectionSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, basePrefs: Prefs) {
        super.init(scratchpad: scratchpad, basePrefs: basePrefs, collection: "tabs")
    }

    public func synchronizeLocalTabs(localTabs: RemoteClientsAndTabs, withServer storageClient: Sync15StorageClient, info: InfoCollections) -> Success {
        func onResponseReceived(response: StorageResponse<[Record<TabsPayload>]>) -> Success {

            func afterWipe() -> Success {

                func doInsert(record: Record<TabsPayload>) -> Deferred<Result<(Int)>> {
                    let remotes = record.payload.remoteTabs
                    log.info("Inserting \(remotes.count) tabs for client \(record.id).")
                    return localTabs.insertOrUpdateTabsForClientGUID(record.id, tabs: remotes)
                }

                // TODO: decide whether to upload ours.
                let ourGUID = self.scratchpad.clientGUID
                let records = response.value
                let responseTimestamp = response.metadata.lastModifiedMilliseconds

                log.debug("Got \(records.count) tab records.")

                let allDone = all(records.filter({ $0.id != ourGUID }).map(doInsert))
                return allDone.bind { (results) -> Success in
                    if let failure = find(results, { $0.isFailure }) {
                        return deferResult(failure.failureValue!)
                    }

                    self.lastFetched = responseTimestamp!
                    return succeed()
                }
            }

            // If this is a fresh start, do a wipe.
            if self.lastFetched == 0 {
                return localTabs.wipeTabs()
                  >>== afterWipe
            }

            return afterWipe()
        }

        if !self.remoteHasChanges(info) {
            // Nothing to do.
            // TODO: upload local tabs if they've changed or we're in a fresh start.
            return succeed()
        }

        if let factory: (String) -> TabsPayload? = self.scratchpad.keys?.value.factory(self.collection, f: { TabsPayload($0) }) {
            let tabsClient = storageClient.clientForCollection(self.collection, factory: factory)

            return tabsClient.getSince(self.lastFetched)
              >>== onResponseReceived
        }

        log.error("Couldn't make tabs factory.")
        return deferResult(FatalError(message: "Couldn't make tabs factory."))
    }
}