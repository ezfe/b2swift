//
//  AuthorizationResult.swift
//  b2swift
//
//  Created by Ezekiel Elin on 8/24/17.
//

import Foundation
import SwiftyJSON

extension Backblaze {
    struct AuthorizationResult: Codable {
        var accountId: String
        var authorizationToken: String
        var apiUrl: String
        var downloadUrl: String
        var recommendedPartSize: Int
        var absoluteMinimumPartSize: Int
    }
    
    /**
     * Used to log in to the B2 API
     *
     * - Sets authorizationToken that can be used for account-level operations
     * - Sets URLs that should be used as the base URL for subsequent API calls.
     *
     * API equivelant to b2_authorize_account
     */
    @discardableResult
    public func authorize() throws -> Bool {
        let url = self.authURL.appendingPathComponent("b2api/v1/b2_authorize_account")
        
        var request = URLRequest(url: url)
        
        let authStr = "\(self.accountId):\(self.applicationKey)"
        guard let authData = authStr.data(using: .utf8, allowLossyConversion: false) else {
            return false
        }
        let base64Str = authData.base64EncodedString(options: .lineLength76Characters)
        
        request.httpMethod = "GET"
        let authSessionConfig = URLSessionConfiguration.default
        authSessionConfig.httpAdditionalHeaders = ["Authorization": "Basic \(base64Str)"]
        
        if let requestData = executeRequest(request, withSessionConfig: authSessionConfig) {
            do {
                let decoder = JSONDecoder()
                let requestResults = try decoder.decode(AuthorizationResult.self, from: requestData)
                
                self.downloadUrl = URL(string: requestResults.downloadUrl)
                self.apiUrl = URL(string: requestResults.apiUrl)
                self.authorizationToken = requestResults.authorizationToken
                self.recommendedPartSize = requestResults.recommendedPartSize
                self.absoluteMinimumPartSize = requestResults.absoluteMinimumPartSize
            } catch let err {
                print(err.localizedDescription)
                return false
            }
            return true
        } else {
            return false
        }
    }
    
}
