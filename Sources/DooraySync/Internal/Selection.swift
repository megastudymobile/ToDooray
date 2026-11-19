import Foundation

/// docs/dooray-api.md "업무 선별 규칙".
enum Selection {
    /// Rule 1. A member entry wins over a group entry, whatever their order in `users.to`.
    static func myWorkflowID(in post: PostDTO, me: MemberID) -> WorkflowID? {
        for case .member(me, let workflowID) in post.assignees {
            return workflowID
        }
        for case .group(let members) in post.assignees {
            if let mine = members.first(where: { $0.memberID == me }) {
                return mine.workflowID
            }
        }
        return nil
    }

    static func referencesUnknownWorkflow(_ post: PostDTO, me: MemberID, in table: WorkflowTable) -> Bool {
        guard let id = myWorkflowID(in: post, me: me) else { return false }
        return table.classes[id] == nil
    }

    /// Rules 1 to 4. nil means the post is not shown.
    static func openState(of post: PostDTO, me: MemberID, in table: WorkflowTable) -> OpenState? {
        if let id = myWorkflowID(in: post, me: me), let workflowClass = table.classes[id] {
            return workflowClass.openState
        }
        return post.workflowClass?.openState
    }
}
