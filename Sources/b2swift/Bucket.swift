//
//  Bucket.swift
//  b2swift
//
//  Created by Ezekiel Elin on 5/26/17.
//  Copyright © 2017 Ezekiel Elin. All rights reserved.
//

import Foundation
import SwiftyJSON

public class Bucket: CustomStringConvertible {
    public enum BucketType: String {
        case allPublic
        case allPrivate
        case share
        case snapshot
        
        static func interpret(type: String) -> BucketType {
            if let type = BucketType(rawValue: type) {
                return type
            } else {
                return .allPublic
            }
        }
    }
    
    let id: String
    let name: String
    private(set) var type: BucketType
    
    weak var backblaze: Backblaze!
    
    internal init(id: String, name: String, type: String, b2: Backblaze) {
        self.id = id
        self.name = name
        self.type = BucketType.interpret(type: type)
        self.backblaze = b2
    }
    
    internal init(id: String, name: String, type: BucketType, b2: Backblaze) {
        self.id = id
        self.name = name
        self.type = type
        self.backblaze = b2
    }
    
    internal init(json: JSON, b2: Backblaze) {
        self.id = json["bucketId"].stringValue
        self.name = json["bucketName"].stringValue
        self.type = BucketType.interpret(type: json["bucketType"].stringValue)
        self.backblaze = b2
    }
    
    public func uploadFile(_ fileUrl: URL, withName fileName: String, contentType: String, sha1: String) throws -> String? {
        return try self.backblaze.uploadFile(fileUrl, withName: fileName, toBucket: self, contentType: contentType, sha1: sha1)
    }
    
    public func setType(bucketType newType: Bucket.BucketType) throws {
        guard let apiUrl = self.backblaze.apiUrl, let authorizationToken = self.backblaze.authorizationToken else {
            throw Backblaze.BackblazeError.unauthenticated
        }

        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_update_bucket")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        
        let httpJSON: JSON = ["bucketId": self.id, "bucketType": newType.rawValue, "accountId": self.backblaze.accountId]
        
        request.httpBody = try httpJSON.rawData()
        
        let json = try self.backblaze.executeRequest(jsonFrom: request)
        self.type = BucketType.interpret(type: json["bucketType"].stringValue)
    }
    
    public var description: String {
        return "\(name)(id: \(id), type: \(type.rawValue))"
    }
}

