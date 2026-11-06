//
//  PickerItem.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

nonisolated struct PickerItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    /// A backup route (TURN) reaches this server. Only set in a subscription where it
    /// does not reach every server, so the few that have it stand out.
    var marksBackupRoute: Bool = false
}

nonisolated struct PickerSection: Identifiable {
    let id: UUID
    /// Header text, or `nil` for an ungrouped section (chains, standalone configs).
    let header: String?
    let items: [PickerItem]
    /// Backup route status of the subscription behind this section; `nil` for chains,
    /// standalone configs and when the TURN feature is hidden.
    var backupRoute: TurnAvailability? = nil
}
