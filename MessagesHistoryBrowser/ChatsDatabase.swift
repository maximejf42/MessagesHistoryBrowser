//
//  ChatsDatabase.swift
//  MessagesHistoryBrowser
//
//  Created by Guillaume Laurent on 04/10/15.
//  Copyright © 2015 Guillaume Laurent. All rights reserved.
//

import Cocoa
import SQLite

class ChatsDatabase {

    enum ChatasDatabaseError : Error {
        case DBConnectionFailed
    }

//    let chatsDBPath = "/Users/glaurent/tmp/chat.db"

    var contactsPhoneNumber:ContactsMap! // want delayed init

    var allChats:[Chat] {
        get {
            return Chat.allChatsInContext(MOCController.sharedInstance.managedObjectContext)
        }
    }

    var db:Connection!

    init(chatsDBPath:String) throws {

        contactsPhoneNumber = ContactsMap.sharedInstance

        do {

            db = try Connection(chatsDBPath, readonly:true)

        } catch let error {

            NSLog("\(#function) error : \(error)")
            throw ChatasDatabaseError.DBConnectionFailed
        }

    }

    func populate(_ progress:Progress, completion:@escaping () -> Void)
    {
        let defaultCountryPhonePrefix = UserDefaults.standard.string(forKey: CountryPhonePrefixUserDefaultsKey) ?? "+33"
        contactsPhoneNumber.populate(withCountryPhonePrefix: defaultCountryPhonePrefix)

//        let workerContext = MOCController.sharedInstance.workerContext()

        let appDelegate = NSApp.delegate as! AppDelegate
        let persistentContainer = appDelegate.persistentContainer

        persistentContainer.performBackgroundTask { (workerContext) in

            if Chat.numberOfChatsInContext(workerContext) == 0 {

                progress.localizedDescription = NSLocalizedString("Importing chats...", comment: "")
                progress.localizedAdditionalDescription = ""
                progress.becomeCurrent(withPendingUnitCount: 2)
                self.importAllChatsFromDB(workerContext)
                progress.resignCurrent()

                progress.localizedDescription = NSLocalizedString("Importing chat messages...", comment: "")
                progress.becomeCurrent(withPendingUnitCount: 8) // must be a total 10 units - see init of Progress in ChatTableViewController.setupProgressBeforeImport()
                self.collectAllMessagesFromAllChats(workerContext)
                progress.resignCurrent()
            }

            do {
                try workerContext.save()
//                MOCController.sharedInstance.save()
            } catch let error as NSError {
                NSLog("\(#function) : worker context save fail : \(error)")
            }

            // run completion block on main queue
            //
            DispatchQueue.main.async(execute: { () -> Void in

//                MOCController.sharedInstance.save()
                completion()

            })

        }

    }

    func importAllChatsFromDB(_ localContext:NSManagedObjectContext)
    {
        let chats = Table("chat")
        
        let chatRowIDColumn = Expression<Int>("ROWID")
        let chatGUIDColumn = Expression<String>("guid")
        let serviceNameColumn = Expression<String>("service_name")
        let chatIdentifierColumn = Expression<String>("chat_identifier")
        
        // Iterate over all chats
        //

        do {

            let nbRows = try Int64(db.scalar(chats.count))
            let taskProgress = Progress(totalUnitCount: nbRows)

            var rowIndex:Int64 = 0


            let dbRows = try db.prepare(chats.select(chatRowIDColumn, chatGUIDColumn, serviceNameColumn, chatIdentifierColumn))

            for chatData in dbRows {

                let guid = chatData[chatGUIDColumn]
                let rowID = chatData[chatRowIDColumn]
                let identifier = chatData[chatIdentifierColumn]
                let serviceName = chatData[serviceNameColumn]

                NSLog("\(#function) contact identifier \(identifier)")

                let chatContact = contactForIdentifier(identifier, service:serviceName, inContext: localContext)

                let _ = Chat(managedObjectContext:localContext, withContact:chatContact, withServiceName:serviceName,  withGUID: guid, andRowID: rowID)

//            NSLog("chat : %@ \tcontact : %@\trowId: %d", guid, chatContact.name, rowID)

                DispatchQueue.main.async { taskProgress.completedUnitCount = rowIndex }
                rowIndex += 1

            }

            do {
                try localContext.save()
            } catch let error as NSError {
                NSLog("\(#function) : worker context save fail : \(error)")
            }

        } catch {
            NSLog("\(#function) : error when preparing DB select")
        }
    }


    func contactForIdentifier(_ identifier:String, service serviceName:String, inContext context:NSManagedObjectContext) -> ChatContact
    {
        var contactName = identifier
        var contactIsKnown = false
        var contactCNIdentifier = ""

        if serviceName == "AIM" || serviceName == "Jabber" {

            if let chatContactNameIdentifierPair = contactsPhoneNumber.nameForInstantMessageAddress(identifier) {
                contactName = chatContactNameIdentifierPair.0
                contactCNIdentifier = chatContactNameIdentifierPair.1
                contactIsKnown = true
            } else {
                contactIsKnown = false
                NSLog("\(#function) : no contact name found for identifier \(identifier)")
            }

        } else if serviceName == "iMessage" || serviceName == "SMS" {

            // check if identifier contains a '@'
            if identifier.contains("@") {
                if let chatContactNameIdentifierPair = contactsPhoneNumber.nameForEmailAddress(identifier) {
                    contactName = chatContactNameIdentifierPair.0
                    contactCNIdentifier = chatContactNameIdentifierPair.1
                    contactIsKnown = true
                }
            } else if let chatContactNameIdentifierPair = contactsPhoneNumber.nameForPhoneNumber(identifier) {
                contactName = chatContactNameIdentifierPair.0
                contactCNIdentifier = chatContactNameIdentifierPair.1
                contactIsKnown = true
            } else {
                contactName = identifier
                contactIsKnown = false
            }
        } else {
            contactName = identifier
            contactIsKnown = false
        }

//        contactsPhoneNumber.nameAndCNIdentifierFromChatIdentifier(identifier, serviceName: serviceName) { (contactAndCNIdentifierPair, contactIsKnown) in
//            var contactName = identifier
//            var contactCNIdentifier = ""
//
//            if let contactAndCNIdentifierPair = contactAndCNIdentifierPair {
//                contactName = contactAndCNIdentifierPair.0
//                contactCNIdentifier = contactAndCNIdentifierPair.1
//            }
//
//            let contact = ChatContact.contactIn(context, named: contactName, withIdentifier: contactCNIdentifier)
//            contact.known = contactIsKnown
//
//            completion(contact)
//        }

        let contact = ChatContact.contactIn(context, named: contactName, withIdentifier: contactCNIdentifier)
        contact.known = contactIsKnown
        return contact
    }

    func messagesForChat(_ chat:Chat) -> ([ChatMessage], [ChatAttachment])
    {
        let allMessages = chat.messages.allObjects as! [ChatMessage]

        let allMessagesSorted = allMessages.sorted { $0.date.compare($1.date as Date) == .orderedAscending }

        let allAttachments = chat.attachments.allObjects as! [ChatAttachment]
        let allAttachmentsSorted = allAttachments.sorted { $0.date.compare($1.date as Date) == .orderedAscending }

        return (allMessagesSorted, allAttachmentsSorted)
    
    }

    func collectMessagesForChat(_ chat:Chat, workerContext:NSManagedObjectContext)
    {
        let messageSaveThreshold = 300

        do {
            let messagesTable  = Table("message")
            let isFromMeColumn = Expression<Bool>("is_from_me")
            let textColumn     = Expression<String?>("text")
            let dateColumn     = Expression<Int>("date")

//            let dateDeliveredColumn = Expression<Int>("date_delivered") // used only for sanity check on dateColumn value

            let chatHandleJoinTable = Table("chat_handle_join")
            let handleIdColumn      = Expression<Int>("handle_id")
            let chatIdColumn        = Expression<Int>("chat_id")

            let chatTable   = Table("chat")
            let rowIDColumn = Expression<Int>("ROWID")
            let guidColumn  = Expression<String>("guid")

            let chatIDQuery = try db.prepare(chatTable.select(rowIDColumn).filter(guidColumn == chat.guid))
            var allRowIDs = [Int]()
            for row in chatIDQuery {
                allRowIDs.append(row[rowIDColumn])
            }


            let handleIDQuery = try db.prepare(chatHandleJoinTable.select(handleIdColumn).filter(allRowIDs.contains(chatIdColumn)))
            var allHandleIDs = [Int]()
            for row in handleIDQuery {
                allHandleIDs.append(row[handleIdColumn])
            }

            let query = try db.prepare(messagesTable.select(isFromMeColumn, textColumn, dateColumn).filter(allHandleIDs.contains(handleIdColumn)))

            var messageCounter = 0

            for messageData in query {
                let messageContent = messageData[textColumn] ?? ""
                var dateInt = messageData[dateColumn]
                if dateInt > Int(10e9) { // I have this case of timestamp values being multiplied by 10e8 on my iMac running High Sierra, with no apparent effect on the values displayed in the chats history
                    dateInt = dateInt / Int(10e8)
                }
                let dateTimeInterval = TimeInterval(dateInt)
                let messageDate = Date(timeIntervalSinceReferenceDate: dateTimeInterval)
//              NSLog("message : \(messageContent)")

                let chatMessage = ChatMessage(managedObjectContext: workerContext, withMessage: messageContent, withDate: messageDate, inChat: chat)
                chatMessage.isFromMe = messageData[isFromMeColumn]

                messageCounter += 1
                if messageCounter >= messageSaveThreshold {
                    messageCounter = 0
                    do {
                        try workerContext.save()
//                        MOCController.sharedInstance.save()
                    } catch let error as NSError {
                        print("ChatsDatabase.collectMessagesForChat : worker context save fail : \(error)")
                    }
                }
            }


            // attachments
            //
            let attachments = Table("attachment")
            let filenameColumn = Expression<String?>("filename")
            let attachmentIdColumn = Expression<Int>("attachment_id")
            let cacheHasAttachmentColumn = Expression<Bool>("cache_has_attachments")

            let messagesWithAttachmentsROWIDsQuery = try db.prepare(messagesTable.select(rowIDColumn, cacheHasAttachmentColumn, handleIdColumn).filter(allHandleIDs.contains(handleIdColumn) && cacheHasAttachmentColumn == true))

            var messagesWithAttachmentsROWIDs = [Int]()
            for row in messagesWithAttachmentsROWIDsQuery {
                messagesWithAttachmentsROWIDs.append(row[rowIDColumn])
            }

            let messageAttachmentJoinTable = Table("message_attachment_join")
            let messageIDColumn = Expression<Int>("message_id")
            let attachmentIDsQuery = try db.prepare(messageAttachmentJoinTable.select(messageIDColumn, attachmentIdColumn).filter(messagesWithAttachmentsROWIDs.contains(messageIDColumn)))

            var allAttachmentIDs = [Int]()
            for row in attachmentIDsQuery {
                allAttachmentIDs.append(row[attachmentIdColumn])
            }


            let attachmentDateColumn = Expression<Int>("created_date")

            let attachmentDataQuery = try db.prepare(attachments.select(rowIDColumn, filenameColumn, attachmentDateColumn).filter(allAttachmentIDs.contains(rowIDColumn)))

            for attachmentData in attachmentDataQuery {
                let attachmentFileName:String? = attachmentData[filenameColumn]
                let attachmentDateInt = attachmentData[attachmentDateColumn]
                let attachmentTimeInterval = TimeInterval(attachmentDateInt)
                let attachmentDate = Date(timeIntervalSinceReferenceDate: attachmentTimeInterval)

                if let attachmentFileName = attachmentFileName {
                    let _ = ChatAttachment(managedObjectContext: chat.managedObjectContext!, withFileName: attachmentFileName, withDate: attachmentDate as Date, inChat:chat)
                }
            }
            
        } catch {
            NSLog("\(#function) : error when preparing DB select")
        }

    }

    func collectAllMessagesFromAllChats(_ workerContext:NSManagedObjectContext)
    {
        let allContacts = ChatContact.allContacts(workerContext)
        let allContactsCount = Int64(allContacts.count)

        let taskProgress = Progress(totalUnitCount: allContactsCount)

        for contact in allContacts {

            Progress.current()?.localizedAdditionalDescription = contact.name

            for obj in contact.chats {
                let chat = obj as! Chat
                if chat.messages.count == 0 {
                    collectMessagesForChat(chat, workerContext: workerContext)

                    do {
                        try workerContext.save()
//                        MOCController.sharedInstance.save()
                    } catch let error as NSError {
                        print("ChatsDatabase.collectAllMessagesFromAllChats : worker context save fail : \(error)")
                    }

                }
            }

            indexMessagesForContact(contact)

            DispatchQueue.main.async { taskProgress.completedUnitCount += 1 }
            
        }
    }

    func indexMessagesForContact(_ contact:ChatContact)
    {
        let allMessages = contact.messages.allObjects as! [ChatMessage]

        let allMessagesDateSorted = allMessages.sorted { $0.date.compare($1.date as Date) == .orderedAscending }

        var index:Int64 = 0

        _ = allMessagesDateSorted.map { $0.index = index; index += 1 }

    }


}
