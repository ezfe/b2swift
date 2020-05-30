//
//  AuthorizationResult.swift
//  b2swift
//
//  Created by Ezekiel Elin on 8/24/17.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

import NIO

extension Backblaze {
    /**
     * Log into the Backblaze B2 service
     *
     * - Sets authorizationToken that can be used for account-level operations
     * - Sets URLs that should be used as the base URL for subsequent API calls.
     *
     * Backblaze Endpoint: [b2_authorize_account](https://www.backblaze.com/b2/docs/b2_authorize_account.html)
     */
    @discardableResult
    public func authorize(on eventLoop: EventLoop) throws -> EventLoopFuture<Void> {
        // Check if the API is authorized
        guard self.authorizationToken == nil else {
            return eventLoop.makeSucceededFuture(())
        }

        // Build the request
        let url = self.authURL.appendingPathComponent("b2api/v1/b2_authorize_account")
        var request = URLRequest(url: url)

        // GET Request
        request.httpMethod = "GET"

        // Set authorization headers
        let authSessionConfig = URLSessionConfiguration.default
        authSessionConfig.httpAdditionalHeaders = [
            "Authorization": try authorizationHeader(accountId: self.accountId,
                                                     applicationKey: self.applicationKey)
        ]

        // Execute the network request
        return executeRequest(request,
                              withSessionConfig: authSessionConfig,
                              on: eventLoop).flatMap { data in
            do {
                struct RawAuthorizationResult: Decodable {
                    let accountId: String
                    /// An authorization token to use with all calls, other than `b2_authorize_account`, that need an Authorization header.
                    /// - Note: This authorization token is valid for at most 24 hours.
                    let authorizationToken: String
                    /// An object containing the capabilities of this auth token, and any restrictions on using it.
                    let allowed: AllowedField
                    /// The base URL to use for all API calls except for uploading and downloading files.
                    let apiUrl: String
                    /// The base URL to use for downloading files.
                    let downloadUrl: String
                    /// The recommended size for each part of a large file. We recommend using this part size for optimal upload performance.
                    let recommendedPartSize: Int
                    /// The smallest possible size of a part of a large file (except the last one). This is smaller than the `recommendedPartSize`. If you use it, you may find that it takes longer overall to upload a large file.
                    let absoluteMinimumPartSize: Int

                    struct AllowedField: Decodable {
                        /// A list of strings, each one naming a capability the key has.
                        /// Possibilities are: `listKeys`, `writeKeys`, `deleteKeys`, `listBuckets`, `writeBuckets`, `deleteBuckets`, `listFiles`, `readFiles`, `shareFiles`, `writeFiles`, and `deleteFiles`.
                        let capabilities: [String]
                        /// When present, access is restricted to one bucket.
                        let bucketId: String?
                        /// When bucketId is set, and it is a valid bucket that has not been deleted, this field is set to the name of the bucket. It's possible that bucketId is set to a bucket that no longer exists, in which case this field will be null. It's also null when bucketId is null.
                        let bucketName: String?
                        /// When present, access is restricted to files whose names start with the prefix
                        let namePrefix: String?
                    }
                }
                
                let decoder = JSONDecoder()
                let requestResults = try decoder.decode(RawAuthorizationResult.self, from: data)
                
                self.downloadUrl = URL(string: requestResults.downloadUrl)
                self.apiUrl = URL(string: requestResults.apiUrl)
                self.authorizationToken = requestResults.authorizationToken
                self.recommendedPartSize = requestResults.recommendedPartSize
                self.absoluteMinimumPartSize = requestResults.absoluteMinimumPartSize
                
                return eventLoop.makeSucceededFuture(())
            } catch {
                return eventLoop.makeFailedFuture(BackblazeError.malformedResponse)
            }
        }
    }

    fileprivate func authorizationHeader(accountId: String, applicationKey: String) throws -> String {
        let authStr = "\(accountId):\(applicationKey)"
        guard let authData = authStr.data(using: .utf8) else {
            throw BackblazeError.malformedRequest
        }
        return "Basic \(authData.base64EncodedString())"
    }
}
