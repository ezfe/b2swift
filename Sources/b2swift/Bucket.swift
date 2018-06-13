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
import Async

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
    
    unowned var backblaze: Backblaze
    
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
    public func upload(url: URL, on worker: Worker) throws -> Future<JSON> {
        if url.isFileURL {
            if url.hasDirectoryPath {
                print(url.absoluteString)
                let _ = try Folder(path: url.path)
                print("Folder upload support isn't available yet")
                throw Backblaze.BackblazeError.uploadFailed
            } else {
                let file = try File(path: url.path)
                return try self.upload(file: file, on: worker)
            }
        } else {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            return try self.upload(data: data, at: filename, on: worker)
        }
    }
    
    /// Upload a file
    public func upload(file: Files.File, at path: String? = nil, on worker: Worker) throws -> Future<JSON> {
        return try self.upload(data: file.read(), at: path ?? file.name, on: worker)
    }
    
    /// Upload raw data
    public func upload(data: Data, at path: String, contentType: String? = nil, sha1: String? = nil, on worker: Worker) throws -> Future<JSON> {
        return try self.prepareUpload(on: worker).map(to: PreparedUploadInfo.self) { uploadInfo in
            guard let uploadInfo = uploadInfo else {
                throw Backblaze.BackblazeError.unauthenticated
            }
            return uploadInfo
        }.flatMap(to: Data.self) { uploadInfo in
            guard let encodedFilename = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw Backblaze.BackblazeError.urlEncodingFailed
            }
            
            var request = URLRequest(url: uploadInfo.url)
            request.httpMethod = "POST"
            
            request.addValue(uploadInfo.authToken, forHTTPHeaderField: BackblazeHTTPHeaders.authorization)
            request.addValue(encodedFilename, forHTTPHeaderField: BackblazeHTTPHeaders.fileName)
            //        request.addValue("fail_some_uploads", forHTTPHeaderField: "X-Bz-Test-Mode")
            
            let resolvedContentType = contentType ?? BackblazeContentTypes.auto
            request.addValue(resolvedContentType, forHTTPHeaderField: BackblazeHTTPHeaders.contentType)
            
            let resolvedSha1 = sha1 ?? data.sha1().map({ String(format: "%02hhx", $0) }).joined()
            request.addValue(resolvedSha1, forHTTPHeaderField: BackblazeHTTPHeaders.contentSHA1)
            
            return self.executeUploadRequest(request, with: data, on: worker)
        }.map(to: JSON.self) { data in
            return try JSON(data: data)
        }
    }
    
    private struct PreparedUploadInfo {
        let url: URL
        let authToken: String
    }
    
    private func prepareUpload(on worker: Worker) throws -> Future<PreparedUploadInfo?> {
        guard let apiUrl = self.backblaze.apiUrl, let authorizationToken = self.backblaze.authorizationToken else {
            throw Backblaze.BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_upload_url")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: BackblazeHTTPHeaders.authorization)
        request.httpBody = try JSONEncoder().encode(["bucketId":"\(self.id)"])
        
        return try self.backblaze.executeRequest(request, on: worker).map(to: JSON.self) { data in
            return try JSON(data: data)
        }.map(to: PreparedUploadInfo?.self) { requestResponse in
            if let uploadUrlString = requestResponse["uploadUrl"].string,
                let uploadUrl = URL(string: uploadUrlString),
                let authToken = requestResponse["authorizationToken"].string {
                
                return PreparedUploadInfo(url: uploadUrl, authToken: authToken)
            } else {
                return nil
            }
        }
    }
    
    private func executeUploadRequest(_ request: URLRequest, with uploadData: Data, sessionConfig: URLSessionConfiguration? = nil, on worker: Worker) -> Future<Data> {
        
        let session: URLSession
        if let sessionConfig = sessionConfig {
            session = URLSession(configuration: sessionConfig)
        } else {
            session = URLSession.shared
        }
        
        let requestDataPromise = worker.eventLoop.newPromise(Data.self)
        session.uploadTask(with: request, from: uploadData) { (data, response, error) in
            if let data = data {
                requestDataPromise.succeed(result: data)
            } else {
                requestDataPromise.fail(error: error ?? Backblaze.BackblazeError.uploadFailed)
            }
            
        }
        
        return requestDataPromise.futureResult
    }
    
    //MARK:-
    
    public func setType(bucketType newType: Bucket.BucketType, on worker: Worker) throws {
        guard let apiUrl = self.backblaze.apiUrl, let authorizationToken = self.backblaze.authorizationToken else {
            throw Backblaze.BackblazeError.unauthenticated
        }

        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_update_bucket")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        
        let httpJSON: JSON = ["bucketId": self.id, "bucketType": newType.rawValue, "accountId": self.backblaze.accountId]
        
        request.httpBody = try httpJSON.rawData()
        
        _ =
            try self.backblaze.executeRequest(jsonFrom: request, on: worker).map(to: Void.self) { json in
            self.type = BucketType.interpret(type: json["bucketType"].stringValue)
        }
    }
    
    public var description: String {
        return "\(name)(id: \(id), type: \(type.rawValue))"
    }
}

