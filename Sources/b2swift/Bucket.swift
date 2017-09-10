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
    
    //MARK:- Uploading Files
    
    /// Upload a file
    public func uploadFile(_ fileUrl: URL, withName fileName: String, contentType: String, sha1: String) throws -> String? {

    
        guard let (uploadUrl, uploadAuthToken) = try self.prepareUpload() else {
            return nil
        }
        
        guard let encodedFilename = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw Backblaze.BackblazeError.urlEncodingFailed
        }
        
        var jsonStr: String? = nil
        if let fileData = try? Data(contentsOf: fileUrl) {
            var request = URLRequest(url: uploadUrl)
            request.httpMethod = "POST"
            request.addValue(uploadAuthToken, forHTTPHeaderField: "Authorization")
            
            request.addValue(encodedFilename    , forHTTPHeaderField: "X-Bz-File-Name")
            request.addValue(contentType, forHTTPHeaderField: "Content-Type")
            request.addValue(sha1, forHTTPHeaderField: "X-Bz-Content-Sha1")
            if let requestData = self.executeUploadRequest(request, with: fileData) {
                jsonStr = String(data: requestData, encoding: .utf8)
            }
        }
        return jsonStr ?? ""

    
    
    }
    
    private func prepareUpload() throws -> (url: URL, authToken: String)? {
        guard let apiUrl = self.backblaze.apiUrl, let authorizationToken = self.backblaze.authorizationToken else {
            throw Backblaze.BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_upload_url")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["bucketId":"\(self.id)"])
        
        let requestResponse = JSON(data: try self.backblaze.executeRequest(request))
        if let uploadUrlString = requestResponse.string,
            let uploadUrl = URL(string: uploadUrlString),
            let authToken = requestResponse["authorizationToken"].string {
            return (url: uploadUrl, authToken: authToken)
        } else {
            return nil
        }
    }
    
    private func executeUploadRequest(_ request: URLRequest, with uploadData: Data, sessionConfig: URLSessionConfiguration? = nil) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        
        let session: URLSession
        if let sessionConfig = sessionConfig {
            session = URLSession(configuration: sessionConfig)
        } else {
            session = URLSession.shared
        }
        
        var requestData: Data?
        let task = session.uploadTask(with: request, from: uploadData) { (data, response, error) in
            if let error = error {
                print("Erorr: \(error.localizedDescription)")
            }
            
            requestData = data
            semaphore.signal()
        }
        
        task.resume()
        semaphore.wait()
        
        return requestData
    }
    
    //MARK:-
    
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

