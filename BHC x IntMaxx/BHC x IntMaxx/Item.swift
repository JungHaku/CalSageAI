//
//  Item.swift
//  BHC x IntMaxx
//
//  Created by Beck Jungwhan on 7/29/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
