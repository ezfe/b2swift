//
//  Bucket.swift
//  b2swift
//
//  Created by Ezekiel Elin on 5/26/17.
//  Copyright © 2017 Ezekiel Elin. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

import CryptoSwift
import Files
import NIO

public class Bucket: CustomStringConvertible {
    public struct CreatePayload: Codable {
        let bucketId: String
        let bucketName: String
        let bucketType: Bucket.BucketType
    }
    
    public enum BucketType: String, Codable {
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
    
    internal convenience init(_ payload: CreatePayload, b2: Backblaze) {
        self.init(id: payload.bucketId, name: payload.bucketName, type: payload.bucketType, b2: b2)
    }
    
    //MARK:- Uploading Files
    
    @available(macOS 10.11, *)
    public func upload(url: URL, on eventLoop: EventLoop) throws -> EventLoopFuture<UploadFileResponse> {
        if url.isFileURL {
            if url.hasDirectoryPath {
                print(url.absoluteString)
                let _ = try Folder(path: url.path)
                print("Folder upload support isn't available yet")
                throw Backblaze.BackblazeError.uploadFailed
            } else {
                let file = try File(path: url.path)
                return try self.upload(file: file, on: eventLoop)
            }
        } else {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            return try self.upload(data: data, at: filename, on: eventLoop)
        }
    }
    
    /// Upload a file
    public func upload(file: Files.File, at path: String? = nil, on eventLoop: EventLoop) throws -> EventLoopFuture<UploadFileResponse> {
        return try self.upload(data: file.read(), at: path ?? file.name, on: eventLoop)
    }
    
    /// Upload raw data
    public func upload(data: Data,
                       at path: String,
                       contentType: String? = nil,
                       sha1: String? = nil,
                       on eventLoop: EventLoop) throws -> EventLoopFuture<UploadFileResponse> {

        return try self.prepareUpload(on: eventLoop).flatMap { uploadInfo -> EventLoopFuture<Data> in
            guard let encodedFilename = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return eventLoop.makeFailedFuture(Backblaze.BackblazeError.urlEncodingFailed)
            }
            
            guard let url = URL(string: uploadInfo.url) else {
                return eventLoop.makeFailedFuture(Backblaze.BackblazeError.urlEncodingFailed)
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            
            request.addValue(uploadInfo.authToken, forHTTPHeaderField: BackblazeHTTPHeaders.authorization)
            request.addValue(encodedFilename, forHTTPHeaderField: BackblazeHTTPHeaders.fileName)
            //        request.addValue("fail_some_uploads", forHTTPHeaderField: "X-Bz-Test-Mode")
            
            let resolvedContentType = contentType ?? BackblazeContentTypes.auto
            request.addValue(resolvedContentType, forHTTPHeaderField: BackblazeHTTPHeaders.contentType)
            
            let resolvedSha1 = sha1 ?? data.sha1().map({ String(format: "%02hhx", $0) }).joined()
            request.addValue(resolvedSha1, forHTTPHeaderField: BackblazeHTTPHeaders.contentSHA1)

            return self.executeUploadRequest(request, with: data, on: eventLoop)
        }.flatMapThrowing { data in
            let jdc = JSONDecoder()
            jdc.dateDecodingStrategy = .millisecondsSince1970
            return try jdc.decode(UploadFileResponse.self, from: data)
        }
    }
    
    private struct PreparedUploadInfo: Codable {
        let url: String
        let authToken: String
        
        enum CodingKeys: String, CodingKey {
            case url = "uploadUrl"
            case authToken = "authorizationToken"
        }
    }
    
    private func prepareUpload(on eventLoop: EventLoop) throws -> EventLoopFuture<PreparedUploadInfo> {
        guard let apiUrl = self.backblaze.apiUrl, let authorizationToken = self.backblaze.authorizationToken else {
            throw Backblaze.BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_upload_url")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: BackblazeHTTPHeaders.authorization)
        request.httpBody = try JSONEncoder().encode(["bucketId":"\(self.id)"])
        
        return try self.backblaze.executeRequest(request, on: eventLoop).flatMapThrowing { data in
            let jdc = JSONDecoder()
            return try jdc.decode(PreparedUploadInfo.self, from: data)
        }
    }
    
    private func executeUploadRequest(_ request: URLRequest, with uploadData: Data, sessionConfig: URLSessionConfiguration? = nil, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        
        let session: URLSession
        if let sessionConfig = sessionConfig {
            session = URLSession(configuration: sessionConfig)
        } else {
            session = URLSession.shared
        }
        
        let requestDataPromise = eventLoop.makePromise(of: Data.self)
        let task = session.uploadTask(with: request, from: uploadData) { (data, response, error) in
            if let data = data {
                requestDataPromise.succeed(data)
            } else {
                requestDataPromise.fail(error ?? Backblaze.BackblazeError.uploadFailed)
            }
        }
        task.resume()
        
        return requestDataPromise.futureResult
    }
    
    //MARK:-
    
    public func setType(bucketType newType: Bucket.BucketType, on eventLoop: EventLoop) throws {
        guard let apiUrl = self.backblaze.apiUrl, let authorizationToken = self.backblaze.authorizationToken else {
            throw Backblaze.BackblazeError.unauthenticated
        }

        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_update_bucket")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["bucketId": self.id, "bucketType": newType.rawValue, "accountId": self.backblaze.accountId], options: .prettyPrinted)

        _ = try self.backblaze.executeRequest(request, on: eventLoop)
    }
    
    public var description: String {
        return "\(name)(id: \(id), type: \(type.rawValue))"
    }
}

