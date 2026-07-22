import Foundation

enum CommitGraphLayout {
    static func makeRows(commits: [GitCommit]) -> [CommitRow] {
        let visibleCommitIDs = Set(commits.map(\.id))
        var activeLanes: [CommitID?] = []
        var rows: [CommitRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let incomingLanes = activeLanes.indices.filter {
                activeLanes[$0] == commit.id
            }
            let nodeLane: Int

            if let existingLane = incomingLanes.first {
                nodeLane = existingLane
            } else if let emptyLane = activeLanes.firstIndex(where: { $0 == nil }) {
                nodeLane = emptyLane
            } else {
                nodeLane = activeLanes.count
                activeLanes.append(nil)
            }

            let passThroughLanes = activeLanes.indices.filter {
                !incomingLanes.contains($0) && activeLanes[$0] != nil
            }

            for lane in incomingLanes {
                activeLanes[lane] = nil
            }

            var parentLanes: [Int] = []
            for (parentIndex, parentOID) in commit.parentOIDs.enumerated() {
                let parentID = CommitID(repositoryID: commit.id.repositoryID, oid: parentOID)
                guard visibleCommitIDs.contains(parentID) else { continue }

                let preferredLane: Int?
                if parentIndex == 0 && activeLanes[nodeLane] == nil {
                    preferredLane = nodeLane
                } else {
                    preferredLane = activeLanes.firstIndex(where: { $0 == nil })
                }

                let parentLane: Int
                if let preferredLane {
                    parentLane = preferredLane
                    activeLanes[parentLane] = parentID
                } else {
                    parentLane = activeLanes.count
                    activeLanes.append(parentID)
                }
                parentLanes.append(parentLane)
            }

            while let lastLane = activeLanes.last, lastLane == nil {
                activeLanes.removeLast()
            }

            let highestLane = max(
                nodeLane,
                max(
                    incomingLanes.max() ?? 0,
                    max(passThroughLanes.max() ?? 0, parentLanes.max() ?? 0)
                )
            )
            rows.append(
                CommitRow(
                    commit: commit,
                    graph: GraphRowLayout(
                        nodeLane: nodeLane,
                        incomingLanes: incomingLanes,
                        passThroughLanes: passThroughLanes,
                        parentLanes: parentLanes,
                        laneCount: highestLane + 1
                    )
                )
            )
        }

        return rows
    }
}
