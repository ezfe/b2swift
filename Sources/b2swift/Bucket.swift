//
//  Bucket.swift
//  b2swift
//
//  Created by Ezekiel Elin on 5/26/17.
//  Copyright © 2017 Ezekiel Elin. All rights reserved.
//

import Foundation
import SwiftyJSON
import CryptoSwift
import Files

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
    
    @available(macOS 10.11, *)
    public func upload(url: URL) throws -> JSON {
        if url.isFileURL {
            if url.hasDirectoryPath {
                print(url.absoluteString)
                let _ = try Folder(path: url.path)
                print("Folder upload support isn't available yet")
                throw Backblaze.BackblazeError.uploadFailed
            } else {
                let file = try File(path: url.path)
                return try self.upload(file: file)
            }
        } else {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            return try self.upload(data: data, at: filename)
        }
    }
    
    /// Upload a file
    public func upload(file: File, at path: String? = nil) throws -> JSON {
        return try self.upload(data: file.read(), at: path ?? file.name)
    }
    
    /// Upload raw data
    public func upload(data: Data, at path: String, contentType: String? = nil, sha1: String? = nil) throws -> JSON {
        
        // Try to generate the upload
        guard let (uploadUrl, uploadAuthToken) = try self.prepareUpload() else {
            throw Backblaze.BackblazeError.unauthenticated
        }
        
        guard let encodedFilename = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw Backblaze.BackblazeError.urlEncodingFailed
        }
        
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "POST"
        
        request.addValue(uploadAuthToken, forHTTPHeaderField: BackblazeHTTPHeaders.authorization)
        request.addValue(encodedFilename, forHTTPHeaderField: BackblazeHTTPHeaders.fileName)
//        request.addValue("fail_some_uploads", forHTTPHeaderField: "X-Bz-Test-Mode")

        let resolvedContentType = contentType ?? BackblazeContentTypes.auto
        request.addValue(resolvedContentType, forHTTPHeaderField: BackblazeHTTPHeaders.contentType)
        
        let resolvedSha1 = sha1 ?? data.sha1().map({ String(format: "%02hhx", $0) }).joined()
        request.addValue(resolvedSha1, forHTTPHeaderField: BackblazeHTTPHeaders.contentSHA1)
        
        guard let uploadResponseData = self.executeUploadRequest(request, with: data) else {
            throw Backblaze.BackblazeError.uploadFailed
        }
        
        return try JSON(data: uploadResponseData)
    }
    
    private func prepareUpload() throws -> (url: URL, authToken: String)? {
        guard let apiUrl = self.backblaze.apiUrl, let authorizationToken = self.backblaze.authorizationToken else {
            throw Backblaze.BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_upload_url")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: BackblazeHTTPHeaders.authorization)
        request.httpBody = try JSONEncoder().encode(["bucketId":"\(self.id)"])
        
        let requestResponse = try JSON(data: try self.backblaze.executeRequest(request))
        if let uploadUrlString = requestResponse["uploadUrl"].string,
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

