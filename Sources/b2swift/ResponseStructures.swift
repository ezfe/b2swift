//
//  ResponseStructures.swift
//  b2swift
//
//  Created by Ezekiel Elin on 6/15/18.
//

import Foundation

/// Response from b2_hide_file
///
/// [Backblaze Documentation](https://www.backblaze.com/b2/docs/b2_hide_file.html)
public struct HideFileResponse: Codable {
    var fileId: String
    var fileName: String
    var action: String
    var uploadTimestamp: Date
}
