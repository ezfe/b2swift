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

// MARK: - b2_list_file_names

// [Backblaze Documentation](https://www.backblaze.com/b2/docs/b2_list_file_names.html)

struct ListFileNamesRequest: Encodable {
    let startFileName: String?
    let maxFileCount: Int?
    let prefix: String?
    let delimeter: String?
}

public struct ListFileNamesResponse: Decodable {
    /// File List
    ///
    /// An array of objects, each one describing one file or folder.
    let files: [File]

    /// Next File Name
    ///
    /// What to pass in to `startFileName` for the next search to continue where this one left off, or nil if there are no more files.
    /// - Note: This this may not be the name of an actual file, but using it is guaranteed to find the next file in the bucket.
    let nextFileName: String?

    public struct File: Decodable {
        /// The account that owns the file.
        let accountId: String

        /// One of `start`, `upload`, `hide`, `folder`, or other values added in the future. `upload` means a file that was uploaded to B2 Cloud Storage. `start` means that a large file has been started, but not finished or canceled. `hide` means a file version marking the file as hidden, so that it will not show up in `b2_list_file_names`. `folder` is used to indicate a virtual folder when listing files.
        let action: String

        /// The bucket that the file is in.
        let bucketId: String

        /// The number of bytes stored in the file.
        ///
        /// Only useful when the `action` is `upload`. Always `0` when the action is `start`, `hide`, or `folder`.
        let contentLength: Int

        /// The SHA1 of the bytes stored in the file as a 40-digit hex string.
        ///
        /// - Note: Large files do not have SHA1 checksums, and the value is `none`. The value is `nil` when the action is `hide` or `folder`.
        let contentSha1: String?

        /// The MD5 of the bytes stored in the file as a 32-digit hex string.
        ///
        /// - Note: Large files do not have MD5 checksums, and the value is `nil`. The value is also `nil` when the action is `hide` or `folder`.
        let contentMd5: String?

        /// When the action is `upload` or `start`, the MIME type of the file, as specified when the file was uploaded.
        ///
        /// - Note: For `hide` action, always `application/x-bz-hide-marker`.
        /// - Note: For `folder` action, always `nil`.
        let contentType: String?

        /// The unique identifier for this version of this file.
        ///
        /// Used with `b2_get_file_info`, `b2_download_file_by_id`, and `b2_delete_file_version`.
        /// - Note: The value is `nil` when for action `folder`.
        let fileId: String?

        // let fileInfo: [String: Any]

        /// The name of this file, which can be used with `b2_download_file_by_name`.
        let fileName: String

        /// This is a UTC time when this file was uploaded.
        ///
        /// - Note: Always `0` when the action is `folder`.
        let uploadTimestamp: Date
    }
}
