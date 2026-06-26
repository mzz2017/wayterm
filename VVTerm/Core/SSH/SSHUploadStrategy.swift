//
//  SSHUploadStrategy.swift
//  VVTerm
//
//  Remote upload transport preference.
//

import Foundation

nonisolated enum SSHUploadStrategy: Sendable {
    case automatic
    case execPreferred
}
