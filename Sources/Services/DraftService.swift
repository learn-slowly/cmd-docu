import Foundation
import CloudKit

actor DraftService {
    private let dataDirectory: URL
    private var container: CKContainer?
    private var database: CKDatabase?
    private var localDrafts: [Draft] = []
    
    static let recordType = "Draft"
    
    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        
        let draftsURL = dataDirectory.appendingPathComponent("drafts.json")
        if let data = try? Data(contentsOf: draftsURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let drafts = try? decoder.decode([Draft].self, from: data) {
                localDrafts = drafts
            }
        }
    }
    
    private func ensureCloudKitSetup() {
        guard container == nil else { return }
        container = CKContainer(identifier: "iCloud.com.cmdmd.drafts")
        database = container?.privateCloudDatabase
    }
    
    func createDraft(title: String = "", body: String = "", tags: [String] = []) -> Draft {
        let draft = Draft(
            title: title,
            body: body,
            tags: tags
        )
        localDrafts.insert(draft, at: 0)
        saveLocalDrafts()
        return draft
    }
    
    func updateDraft(_ draft: Draft) {
        if let index = localDrafts.firstIndex(where: { $0.id == draft.id }) {
            var updated = draft
            updated.updatedAt = Date()
            localDrafts[index] = updated
            saveLocalDrafts()
        }
    }
    
    func deleteDraft(_ draft: Draft) {
        localDrafts.removeAll { $0.id == draft.id }
        saveLocalDrafts()
    }
    
    func getAllDrafts() -> [Draft] {
        localDrafts.filter { $0.status == .active }
    }
    
    func getArchivedDrafts() -> [Draft] {
        localDrafts.filter { $0.status == .archived }
    }
    
    func archiveDraft(_ draft: Draft) {
        if let index = localDrafts.firstIndex(where: { $0.id == draft.id }) {
            var updated = localDrafts[index]
            updated.status = .archived
            updated.updatedAt = Date()
            localDrafts[index] = updated
            saveLocalDrafts()
        }
    }
    
    func markAsSent(_ draft: Draft) {
        if let index = localDrafts.firstIndex(where: { $0.id == draft.id }) {
            var updated = localDrafts[index]
            updated.status = .sent
            updated.updatedAt = Date()
            localDrafts[index] = updated
            saveLocalDrafts()
        }
    }
    
    func syncWithCloud() async throws {
        throw DraftSyncError.notSignedIn
    }
    
    private func draftToRecord(_ draft: Draft) -> CKRecord {
        let recordID = CKRecord.ID(recordName: draft.id.uuidString)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        
        record["id"] = draft.id.uuidString
        record["title"] = draft.title
        record["body"] = draft.body
        record["createdAt"] = draft.createdAt
        record["updatedAt"] = draft.updatedAt
        record["sourceDevice"] = draft.sourceDevice
        record["tags"] = draft.tags
        record["status"] = draft.status.rawValue
        
        return record
    }
    
    private func recordToDraft(_ record: CKRecord) -> Draft? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let title = record["title"] as? String,
              let body = record["body"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date,
              let sourceDevice = record["sourceDevice"] as? String,
              let statusString = record["status"] as? String,
              let status = DraftStatus(rawValue: statusString) else {
            return nil
        }
        
        let tags = record["tags"] as? [String] ?? []
        
        return Draft(
            id: id,
            title: title,
            body: body,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourceDevice: sourceDevice,
            tags: tags,
            status: status
        )
    }
    

    
    private func saveLocalDrafts() {
        let draftsURL = dataDirectory.appendingPathComponent("drafts.json")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        if let data = try? encoder.encode(localDrafts) {
            try? data.write(to: draftsURL)
        }
    }
}

enum DraftSyncError: LocalizedError {
    case notSignedIn
    case syncFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Please sign in to iCloud to sync drafts"
        case .syncFailed(let error):
            return "Sync failed: \(error.localizedDescription)"
        }
    }
}
