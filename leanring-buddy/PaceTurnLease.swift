//
//  PaceTurnLease.swift
//  leanring-buddy
//

import Foundation

/// Identifies one accepted user turn. Async work must still own the active
/// lease before it is allowed to install response work or update turn state.
struct PaceTurnLease: Equatable, Sendable {
    fileprivate let generation: UInt64
}

/// Pure generation gate for rejecting results from cancelled or superseded
/// routing work. CompanionManager owns task cancellation; this type owns the
/// separate truth of whether an async result still belongs to the active turn.
struct PaceTurnLeaseRegistry {
    private var currentGeneration: UInt64 = 0

    mutating func beginTurn() -> PaceTurnLease {
        currentGeneration &+= 1
        return PaceTurnLease(generation: currentGeneration)
    }

    mutating func invalidateCurrentTurn() {
        currentGeneration &+= 1
    }

    func isCurrent(_ lease: PaceTurnLease) -> Bool {
        lease.generation == currentGeneration
    }
}
