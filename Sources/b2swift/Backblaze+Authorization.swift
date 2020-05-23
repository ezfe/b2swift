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

import Async
import NIO

extension Backblaze {
    /**
     * Used to log in to the B2 API
     *
     * - Sets authorizationToken that can be used for account-level operations
     * - Sets URLs that should be used as the base URL for subsequent API calls.
     *
     * API equivelant to b2_authorize_account
     */
    @discardableResult
    public func authorize(on worker: Worker) throws -> Future<Bool> {
        let url = self.authURL.appendingPathComponent("b2api/v1/b2_authorize_account")
        var request = URLRequest(url: url)
        
        let authStr = "\(self.accountId):\(self.applicationKey)"
        guard let authData = authStr.data(using: .utf8) else {
            throw BackblazeError.malformedRequest
        }
        let authStringBase64 = authData.base64EncodedString()
        
        request.httpMethod = "GET"
        let authSessionConfig = URLSessionConfiguration.default
        authSessionConfig.httpAdditionalHeaders = ["Authorization": "Basic \(authStringBase64)"]
        
        return try executeRequest(request, withSessionConfig: authSessionConfig, on: worker).map(to: Bool.self) { data in
            do {
                struct RawAuthorizationResult: Codable {
                    var accountId: String
                    var authorizationToken: String
                    //                var capabilities: [String]
                    var apiUrl: String
                    var downloadUrl: String
                    var recommendedPartSize: Int
                    var absoluteMinimumPartSize: Int
                }
                
                let decoder = JSONDecoder()
                let requestResults = try decoder.decode(RawAuthorizationResult.self, from: data)
                
                self.downloadUrl = URL(string: requestResults.downloadUrl)
                self.apiUrl = URL(string: requestResults.apiUrl)
                self.authorizationToken = requestResults.authorizationToken
                self.recommendedPartSize = requestResults.recommendedPartSize
                self.absoluteMinimumPartSize = requestResults.absoluteMinimumPartSize
                
                return true
            } catch {
                throw BackblazeError.malformedResponse
            }
        }
    }
    
}
