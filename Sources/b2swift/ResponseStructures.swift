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
    let fileId: String
    let fileName: String
    let action: String
    let uploadTimestamp: Date
}

/// Response from b2_upload_file
///
/// [Backblaze Documentation](https://www.backblaze.com/b2/docs/b2_upload_file.html)
public struct UploadFileResponse: Codable {
    let fileId: String
    let fileName: String
    let accountId: String
    let bucketId: String
    let contentSha1: String
    let contentType: String
    let action: String
    let uploadTimestamp: Date
}
