//
//  Backblaze.swift
//  b2swift
//
//  Created by Ezekiel Elin on 5/22/17.
//  Copyright © 2017 Ezekiel Elin. All rights reserved.
//

import Foundation
import CryptoSwift
import NIO

public class Backblaze {
    public enum BackblazeError: LocalizedError {
        case urlConstructionFailed
        case urlEncodingFailed
        case malformedRequest
        case malformedResponse
        case unauthenticated
        case uploadFailed
        
        public var errorDescription: String? {
            switch self {
            case .urlConstructionFailed:
                return "An error occurred construction the URL"
            case .urlEncodingFailed:
                return "An error occurred encoding the URL parameters"
            case .malformedRequest:
                return "The request could not be created with the given parameters"
            case .malformedResponse:
                return "The server responded with unparseable data"
            case .unauthenticated:
                return "Authentication details are missing"
            case .uploadFailed:
                return "An error occurred uploading the file"
            }
        }
    }
    
    /// The base URL to use for authorization.
    internal let authURL = URL(string: "https://api.backblazeb2.com")!
    
    /// The identifier for the account.
    public let accountId: String
    
    /// The account authentication key.
    public let applicationKey: String
    
    /**
     * An authorization token to use with all calls (except authorization itself).
     
     * This authorization token is valid for at most 24 hours.
     */
    internal var authorizationToken: String?
    
    /// The base URL to use for all API calls except for uploading and downloading files.
    internal var apiUrl: URL?
    
    /// The base URL to use for downloading files.
    internal var downloadUrl: URL?
    
    /// The recommended size for each part of a large file. We recommend using this part size for optimal upload performance.
    internal var recommendedPartSize: Int?
    
    /**
     * The smallest possible size of a part of a large file (except the last one).
     *
     * This is smaller than the recommendedPartSize. If you use it, you may find that it takes longer overall to upload a large file.
     */
    internal var absoluteMinimumPartSize: Int?
    
    public init(id: String, key: String) {
        self.accountId = id
        self.applicationKey = key
    }
    
    //MARK:- Buckets
    
    public func createBucket(named bucketName: String, on eventLoop: EventLoop) throws -> EventLoopFuture<Bucket> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_create_bucket")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId":"\(self.accountId)", "bucketName":"\(bucketName)", "bucketType":"allPrivate"], options: .prettyPrinted)
        
        return try executeRequest(request, on: eventLoop).flatMapThrowing { data in
            let jdc = JSONDecoder()
            let response = try jdc.decode(Bucket.CreatePayload.self, from: data)
            
            return Bucket(response, b2: self)
        }
    }
    
    public func listBuckets(on eventLoop: EventLoop) throws -> EventLoopFuture<[Bucket]>  {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_list_buckets")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId":"\(self.accountId)"])
        
        return try executeRequest(request, on: eventLoop).flatMapThrowing { data in
            struct BucketList: Codable {
                let buckets: [Bucket.CreatePayload]
            }
            
            let jdc = JSONDecoder()
            let bucketList = try jdc.decode(BucketList.self, from: data)
            
            return bucketList.buckets.map({ (bucketData) -> Bucket in
                return Bucket(bucketData, b2: self)
            })
        }
    }
    
    public func bucket(named searchBucketName: String, on eventLoop: EventLoop) throws -> EventLoopFuture<Bucket?> {
        return try self.listBuckets(on: eventLoop).flatMapThrowing { buckets in
            for bucket in buckets where bucket.name == searchBucketName {
                return bucket
            }
            return nil
        }
    }
    
    //MARK:- Files
    
//    public func getFileId(json: JSON) -> String {
//        return json["fileId"].stringValue
//    }
    
    public func listFileNames(in bucket: Bucket,
                              startFileName: String? = nil,
                              maxFileCount: Int? = nil,
                              on eventLoop: EventLoop) throws -> EventLoopFuture<[ListFileNamesResponse]> {

        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_list_file_names") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.authorizationToken!, forHTTPHeaderField: "Authorization")
//            var params: JSON = ["bucketId": bucket.id]
//            if let startFileStr = startFileName {
//                params["startFileName"] = JSON(startFileStr)
//            }
//            if let maxFileCount = maxFileCount {
//                params["startFileName"] = JSON(String(maxFileCount))
//            }
//            request.httpBody = try! params.rawData()
            
            return try executeRequest(request, withSessionConfig: nil, on: eventLoop).flatMapThrowing { data in
                let jdc = JSONDecoder()
                jdc.dateDecodingStrategy = .millisecondsSince1970
                return try jdc.decode([ListFileNamesResponse].self, from: data)
            }
        }

        return eventLoop.makeSucceededFuture([ListFileNamesResponse]())
    }
    
    public func findFirstFileIdForName(searchFileName: String,
                                       bucket: Bucket,
                                       on eventLoop: EventLoop) -> EventLoopFuture<String?> {

        do {
            return try self.listFileNames(
                                in: bucket,
                                startFileName: nil,
                                maxFileCount: -1,
                                on: eventLoop).map { filenames in

                for file in filenames {
                    if file.fileName.caseInsensitiveCompare(searchFileName) == .orderedSame {
                        return file.fileId
                    }
                }
                return nil
            }
        } catch let err {
            print(err.localizedDescription)
            return eventLoop.makeSucceededFuture(nil)
        }
    }
    
    /// Downloads one file from B2.
    ///
    /// [Backblaze Documentation](https://www.backblaze.com/b2/docs/b2_download_file_by_id.html)
    public func downloadFile(withId fileId: String, on eventLoop: EventLoop) throws -> EventLoopFuture<Data> {
        guard let downloadUrl = self.downloadUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = downloadUrl.appendingPathComponent("/b2api/v1/b2_download_file_by_id")
        
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        urlComponents.query = "fileId=\(fileId)"
        let modifiedUrl = urlComponents.url!
        
        var request = URLRequest(url: modifiedUrl)
        
        request.httpMethod = "GET"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        
        return try executeRequest(request, on: eventLoop)
    }
    
    /// Hides a file so that downloading by name will not find the file,
    /// but previous versions of the file are still stored.
    ///
    /// [Backblaze Documentation](https://www.backblaze.com/b2/docs/b2_hide_file.html)
    public func hideFile(named fileName: String, in bucket: Bucket, on eventLoop: EventLoop) throws -> EventLoopFuture<HideFileResponse> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }

        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_hide_file")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileName\":\"\(fileName)\",\"bucketId\":\"\(bucket.id)\"}".data(using: .utf8, allowLossyConversion: false)
            
        return try executeRequest(request, on: eventLoop).flatMapThrowing { data in
            let jdc = JSONDecoder()
            jdc.dateDecodingStrategy = .millisecondsSince1970
            return try jdc.decode(HideFileResponse.self, from: data)
        }
    }
    
    
    //MARK:- Common
    
    public func executeRequest(_ request: URLRequest,
                               withSessionConfig sessionConfig: URLSessionConfiguration? = nil,
                               on eventLoop: EventLoop) throws -> EventLoopFuture<Data> {

        let session: URLSession
        if let sessionConfig = sessionConfig {
            session = URLSession(configuration: sessionConfig)
        } else {
            session = URLSession.shared
        }
        
        let requestDataPromise = eventLoop.makePromise(of: Data.self)
        let task = session.dataTask(with: request) { (data, response, error) in
            if let data = data {
                requestDataPromise.succeed(data)
            } else {
                requestDataPromise.fail(error ?? BackblazeError.malformedResponse)
            }
        }
        task.resume()
        
        return requestDataPromise.futureResult
    }
    
    //MARK:- Unprocessed
    
    /*
    public func b2ListFileVersions(bucketId: String, startFileName: String?, startFileId: String?, maxFileCount: Int, on eventLoop: EventLoop) throws -> EventLoopFuture<JSON> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_list_file_versions")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        
        var params: JSON = ["bucketId": bucketId]
        if let startFileNameStr = startFileName {
            params["startFileName"] = JSON(startFileNameStr)
        }
        if let startFileIdStr = startFileId {
            params["startFileId"] = JSON(startFileIdStr)
        }
        if (maxFileCount > -1) {
            params["maxFileCount"] = JSON(String(maxFileCount))
        }
        
        request.httpBody = try params.rawData()
        return try executeRequest(request, on: eventLoop).map(to: JSON.self) { data in
            return try JSON(data: data)
        }
    }
    
    public func b2GetFileInfo(fileId: String, on eventLoop: EventLoop) throws -> EventLoopFuture<JSON> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_file_info")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileId\":\"\(fileId)\"}".data(using: .utf8, allowLossyConversion: false)
        
        return try executeRequest(request, on: eventLoop).map(to: JSON.self) { data in
            return try JSON(data: data)
        }
    }
    
    public func b2DeleteFileVersion(fileId: String, fileName: String, on eventLoop: EventLoop) throws -> EventLoopFuture<JSON> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_delete_file_version")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileName\":\"\(fileName)\",\"fileId\":\"\(fileId)\"}".data(using: .utf8, allowLossyConversion: false)
        
        return try executeRequest(request, on: eventLoop).map(to: JSON.self) { data in
            return try JSON(data: data)
        }
    }
    */
}
