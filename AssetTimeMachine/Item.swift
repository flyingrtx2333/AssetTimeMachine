//
//  Item.swift
//  AssetTimeMachine
//
//  Created by 向钧升 on 4/25/26.
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
