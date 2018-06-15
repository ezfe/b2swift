//
//  Backblaze.swift
//  b2swift
//
//  Created by Ezekiel Elin on 5/22/17.
//  Copyright © 2017 Ezekiel Elin. All rights reserved.
//

import Foundation
import SwiftyJSON
import CryptoSwift
import Async

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
    
    public func createBucket(named bucketName: String, on worker: Worker) throws -> Future<Bucket> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_create_bucket")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId":"\(self.accountId)", "bucketName":"\(bucketName)", "bucketType":"allPrivate"], options: .prettyPrinted)
        
        return try executeRequest(jsonFrom: request, on: worker).map(to: Bucket.self) { json in
            return Bucket(json: json, b2: self)
        }
    }
    
    public func listBuckets(on worker: Worker) throws -> Future<[Bucket]>  {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_list_buckets")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId":"\(self.accountId)"], options: .prettyPrinted)
        
        return try executeRequest(jsonFrom: request, on: worker).map(to: [Bucket].self) { json in
            return json["buckets"].arrayValue.map({ (bucket) -> Bucket in
                return Bucket(json: bucket, b2: self)
            })
        }
    }
    
    public func bucket(named searchBucketName: String, on worker: Worker) throws -> Future<Bucket?> {
        return try self.listBuckets(on: worker).map(to: Bucket?.self) { buckets in
            for bucket in buckets where bucket.name == searchBucketName {
                return bucket
            }
            return nil
        }
    }
    
    //MARK:- Files
    
    public func getFileId(json: JSON) -> String {
        return json["fileId"].stringValue
    }
    
    public func listFileNames(in bucket: Bucket, startFileName: String? = nil, maxFileCount: Int? = nil, on worker: Worker) throws -> Future<JSON> {
        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_list_file_names") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.authorizationToken!, forHTTPHeaderField: "Authorization")
            var params: JSON = ["bucketId": bucket.id]
            if let startFileStr = startFileName {
                params["startFileName"] = JSON(startFileStr)
            }
            if let maxFileCount = maxFileCount {
                params["startFileName"] = JSON(String(maxFileCount))
            }
            request.httpBody = try! params.rawData()
            
            return try executeRequest(request, withSessionConfig: nil, on: worker).map(to: JSON.self) { data in
                return try JSON(data: data)
            }
        }
        return Future.map(on: worker) { JSON.null }
    }
    
    public func findFirstFileIdForName(searchFileName: String, bucket: Bucket, on worker: Worker) -> Future<String?> {
        do {
            return try self.listFileNames(
                                in: bucket,
                                startFileName: nil,
                                maxFileCount: -1,
                                on: worker).map(to: String?.self) { json in

                for (_, file): (String, JSON) in json {
                    if file["fileName"].stringValue.caseInsensitiveCompare(searchFileName) == .orderedSame {
                        return file["fileId"].stringValue
                    }
                }
                return nil
            }
        } catch let err {
            print(err.localizedDescription)
            return Future.map(on: worker) { nil }
        }
    }
    
    /// Downloads one file from B2.
    ///
    /// [Backblaze Documentation](https://www.backblaze.com/b2/docs/b2_download_file_by_id.html)
    public func downloadFile(withId fileId: String, on worker: Worker) throws -> Future<Data> {
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
        
        return try executeRequest(request, on: worker)
    }
    
    /// Hides a file so that downloading by name will not find the file,
    /// but previous versions of the file are still stored.
    ///
    /// [Backblaze Documentation](https://www.backblaze.com/b2/docs/b2_hide_file.html)
    public func hideFile(named fileName: String, in bucket: Bucket, on worker: Worker) throws -> Future<HideFileResponse> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }

        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_hide_file")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileName\":\"\(fileName)\",\"bucketId\":\"\(bucket.id)\"}".data(using: .utf8, allowLossyConversion: false)
            
        return try executeRequest(request, on: worker).map(to: HideFileResponse.self) { data in
            let jdc = JSONDecoder()
            jdc.dateDecodingStrategy = .millisecondsSince1970
            return try jdc.decode(HideFileResponse.self, from: data)
        }
    }
    
    
    //MARK:- Common
    
    public func executeRequest(_ request: URLRequest, withSessionConfig sessionConfig: URLSessionConfiguration? = nil, on worker: Worker) throws -> Future<Data> {
        let session: URLSession
        if let sessionConfig = sessionConfig {
            session = URLSession(configuration: sessionConfig)
        } else {
            session = URLSession.shared
        }
        
        let requestDataPromise = worker.eventLoop.newPromise(Data.self)
        let task = session.dataTask(with: request) { (data, response, error) in
            if let data = data {
                requestDataPromise.succeed(result: data)
            } else {
                requestDataPromise.fail(error: error ?? BackblazeError.malformedResponse)
            }
        }
        task.resume()
        
        return requestDataPromise.futureResult
    }
    
    public func executeRequest(jsonFrom request: URLRequest, withSessionConfig sessionConfig: URLSessionConfiguration? = nil, on worker: Worker) throws -> Future<JSON> {
        return try executeRequest(request, withSessionConfig: sessionConfig, on: worker).map(to: JSON.self) { data in
            return try JSON(data: data)
        }
    }
    
    //MARK:- Unprocessed
    
    public func b2ListFileVersions(bucketId: String, startFileName: String?, startFileId: String?, maxFileCount: Int, on worker: Worker) throws -> Future<JSON> {
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
        return try executeRequest(request, on: worker).map(to: JSON.self) { data in
            return try JSON(data: data)
        }
    }
    
    public func b2GetFileInfo(fileId: String, on worker: Worker) throws -> Future<JSON> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_file_info")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileId\":\"\(fileId)\"}".data(using: .utf8, allowLossyConversion: false)
        
        return try executeRequest(request, on: worker).map(to: JSON.self) { data in
            return try JSON(data: data)
        }
    }
    
    public func b2DeleteFileVersion(fileId: String, fileName: String, on worker: Worker) throws -> Future<JSON> {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_delete_file_version")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileName\":\"\(fileName)\",\"fileId\":\"\(fileId)\"}".data(using: .utf8, allowLossyConversion: false)
        
        return try executeRequest(request, on: worker).map(to: JSON.self) { data in
            return try JSON(data: data)
        }
    }
}

