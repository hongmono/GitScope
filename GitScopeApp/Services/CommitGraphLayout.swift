import Foundation

enum CommitGraphLayout {
    static func makeRows(commits: [GitCommit]) -> [CommitRow] {
        let visibleCommitIDs = Set(commits.map(\.id))
        var activePaths: [ActivePath] = []
        var nextPathID = 0
        var rows: [CommitRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let topPaths = activePaths
            let incomingLanes = topPaths.indices.filter {
                topPaths[$0].target == commit.id
            }
            let incomingPathIDs = Set(incomingLanes.map { topPaths[$0].id })
            var bottomPaths = topPaths.filter { !incomingPathIDs.contains($0.id) }
            let nodeTopLane = incomingLanes.first
            let parentInsertionLane = nodeTopLane.map { lane in
                topPaths.indices.prefix(lane).filter {
                    !incomingPathIDs.contains(topPaths[$0].id)
                }.count
            } ?? bottomPaths.count
            var parentPathIDs: [Int] = []
            var newParentPaths: [ActivePath] = []

            for parentOID in commit.parentOIDs {
                let parentID = CommitID(repositoryID: commit.id.repositoryID, oid: parentOID)
                guard visibleCommitIDs.contains(parentID) else { continue }
                let path = ActivePath(
                    id: nextPathID,
                    target: parentID
                )
                nextPathID += 1
                newParentPaths.append(path)
                parentPathIDs.append(path.id)
            }

            if !newParentPaths.isEmpty {
                bottomPaths.insert(
                    contentsOf: newParentPaths,
                    at: min(parentInsertionLane, bottomPaths.count)
                )
            }

            let bottomLanesByPathID = Dictionary(
                uniqueKeysWithValues: bottomPaths.enumerated().map {
                    ($0.element.id, $0.offset)
                }
            )
            let passThroughConnections = topPaths.enumerated().compactMap {
                topLane, path -> GraphLaneConnection? in
                guard !incomingPathIDs.contains(path.id),
                      let bottomLane = bottomLanesByPathID[path.id] else {
                    return nil
                }
                return GraphLaneConnection(
                    incomingLane: topLane,
                    outgoingLane: bottomLane
                )
            }
            let parentLanes = parentPathIDs.compactMap {
                bottomLanesByPathID[$0]
            }
            let nodeLane = nodeTopLane
                ?? parentLanes.first
                ?? bottomPaths.count
            let highestLane = max(
                nodeLane,
                max(
                    incomingLanes.max() ?? 0,
                    max(
                        passThroughConnections.flatMap {
                            [$0.incomingLane, $0.outgoingLane]
                        }.max() ?? 0,
                        parentLanes.max() ?? 0
                    )
                )
            )
            rows.append(
                CommitRow(
                    commit: commit,
                    graph: GraphRowLayout(
                        nodeLane: nodeLane,
                        incomingLanes: incomingLanes,
                        passThroughConnections: passThroughConnections,
                        parentLanes: parentLanes,
                        laneCount: highestLane + 1
                    )
                )
            )
            activePaths = bottomPaths
        }

        return rows
    }

    private struct ActivePath {
        let id: Int
        let target: CommitID
    }
}
