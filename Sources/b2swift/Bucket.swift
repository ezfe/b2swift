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

import Crypto
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
            return self.upload(data: data, at: filename, on: eventLoop)
        }
    }
    
    /// Upload a file
    public func upload(file: Files.File, at path: String? = nil, on eventLoop: EventLoop) throws -> EventLoopFuture<UploadFileResponse> {
        return try self.upload(data: file.read(), at: path ?? file.name, on: eventLoop)
    }
    
    /**
     * Upload raw data
     *
     * - Parameters:
     *   - data: The data to upload
     *   - path: The location to upload the file to
     *   - contentType: The type of the content
     *   - sha1: If provided, this sha1 will be verified. If not provided, one will be calculated for you.
     *   - eventLoop: The EventLoop this upload will be run on
     *
     * - Returns: The response from Backblaze
     */
    public func upload(data: Data,
                       at path: String,
                       contentType: String? = nil,
                       sha1: String? = nil,
                       on eventLoop: EventLoop) -> EventLoopFuture<UploadFileResponse> {

        return self.prepareUpload(on: eventLoop).flatMap { uploadInfo -> EventLoopFuture<Data> in
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
            
            let resolvedSha1 = sha1 ?? data.sha1
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

    /**
     * Prepare to upload a file
     *
     * This will fetch an upload URL and authorization token for uploading.
     *
     * Backblaze Endpoint: [b2_get_upload_url](https://www.backblaze.com/b2/docs/b2_get_upload_url.html)
     */
    private func prepareUpload(on eventLoop: EventLoop) -> EventLoopFuture<PreparedUploadInfo> {
        guard let apiUrl = self.backblaze.apiUrl,
            let authorizationToken = self.backblaze.authorizationToken else {

            return eventLoop.makeFailedFuture(Backblaze.BackblazeError.unauthenticated)
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_upload_url")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: BackblazeHTTPHeaders.authorization)

        do {
            let jsonEncoder = JSONEncoder()
            request.httpBody = try jsonEncoder.encode([ "bucketId": "\(self.id)" ])
        } catch {
            return eventLoop.makeFailedFuture(Backblaze.BackblazeError.malformedRequest)
        }
        
        return self.backblaze.executeRequest(request, on: eventLoop).flatMap { data in
            do {
                let jsonDecoder = JSONDecoder()
                let uploadInfo = try jsonDecoder.decode(PreparedUploadInfo.self, from: data)
                return eventLoop.makeSucceededFuture(uploadInfo)
            } catch {
                return eventLoop.makeFailedFuture(Backblaze.BackblazeError.malformedResponse)
            }
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

        _ = self.backblaze.executeRequest(request, on: eventLoop)
    }

    // MARK:- Files

    /**
     * List File Names
     *
     * Backblaze Endpoint: [b2_list_file_names](https://www.backblaze.com/b2/docs/b2_list_file_names.html)
     *
     * - Warning:
     *   `b2_list_file_names` is a Class C transaction (see [Pricing](https://www.backblaze.com/b2/cloud-storage-pricing.html) ).
     *   The maximum number of files returned per transaction is 1,000. If you set
     *   maxFileCount to more than 1,000 and more than 1,000 are returned, the call
     *   will be billed as multiple transactions, as if you had made requests in a
     *   loop asking for 1,000 at a time.
     *
     *   *For example*: if you set maxFileCount to 10,000 and 3123 items are returned,
     *   you will be billed for 4 Class C transactions.
     *
     * - Parameters:
     *   - startFileName: The first file name to return. If there is a file with this name, it will be returned in the list. If not, the first file name after this the first one after this name.
     *   - maxFileCount: The maximum number of files to return from this call. The default value is 100, and the maximum is 10,000.
     *   - prefix: Files returned will be limited to those with the given prefix.
     *   - delimeter: Files returned will be limited to those within the top folder, or any one subfolder. Folder names will also be returned. The delimiter character will be used to "break" file names into folders.
     */
    public func listFileNames(startFileName: String? = nil,
                              maxFileCount: Int? = nil,
                              prefix: String? = nil,
                              delimeter: String? = nil,
                              on eventLoop: EventLoop) -> EventLoopFuture<[ListFileNamesResponse]> {

        guard let apiUrl = self.backblaze.apiUrl, let authorizationToken = self.backblaze.authorizationToken else {
            return eventLoop.makeFailedFuture(Backblaze.BackblazeError.unauthenticated)
        }

        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_list_file_names")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")

        do {
            let jsonEncoder = JSONEncoder()
            request.httpBody = try jsonEncoder.encode(ListFileNamesRequest(startFileName: startFileName,
                                                                           maxFileCount: maxFileCount,
                                                                           prefix: prefix,
                                                                           delimeter: delimeter))
        } catch {
            return eventLoop.makeFailedFuture(Backblaze.BackblazeError.malformedRequest)
        }

        return self.backblaze.executeRequest(request, on: eventLoop).flatMapThrowing { data in
            let jsonDecoder = JSONDecoder()
            jsonDecoder.dateDecodingStrategy = .millisecondsSince1970
            return try jsonDecoder.decode([ListFileNamesResponse].self, from: data)
        }
    }
    
    public var description: String {
        return "\(name)(id: \(id), type: \(type.rawValue))"
    }
}

