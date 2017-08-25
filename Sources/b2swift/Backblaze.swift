//
//  Backblaze.swift
//  b2swift
//
//  Created by Ezekiel Elin on 5/22/17.
//  Copyright © 2017 Ezekiel Elin. All rights reserved.
//

import Foundation
import SwiftyJSON
import Files

public class Backblaze {
    public enum BackblazeError: Swift.Error {
        case urlConstructionFailed
        case urlEncodingFailed
        case malformedResponse
        case unauthenticated
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
    
    public func createBucket(named bucketName: String) throws -> Bucket {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_create_bucket")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId":"\(self.accountId)", "bucketName":"\(bucketName)", "bucketType":"allPrivate"], options: .prettyPrinted)
        
        return Bucket(json: try executeRequest(jsonFrom: request), b2: self)
    }
    
    public func listBuckets() throws -> [Bucket]  {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_list_buckets")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId":"\(self.accountId)"], options: .prettyPrinted)
        
        let json = try executeRequest(jsonFrom: request)
        
        return json["buckets"].arrayValue.map({ (bucket) -> Bucket in
            return Bucket(json: bucket, b2: self)
        })
    }
    
    public func bucketWithName(searchBucketName: String) -> Bucket? {
        do {
            for bucket in try self.listBuckets() where bucket.name == searchBucketName {
                return bucket
            }
            return nil
        } catch {
            print("Unable to list buckets...")
            return nil
        }
    }
    
    //MARK:- Files
    
    public func getFileId(json: JSON) -> String {
        return json["fileId"].stringValue
    }
    
    public func listFileNames(in bucket: Bucket, startFileName: String? = nil, maxFileCount: Int? = nil) throws -> JSON {
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
            let requestData = try executeRequest(request, withSessionConfig: nil)
            return JSON(data: requestData)
        }
        return JSON.null
    }
    
    public func findFirstFileIdForName(searchFileName: String, bucket: Bucket) -> String? {
        if let json = try? self.listFileNames(in: bucket, startFileName: nil, maxFileCount: -1) {
            for (_, file): (String, JSON) in json {
                if file["fileName"].stringValue.caseInsensitiveCompare(searchFileName) == .orderedSame {
                    return file["fileId"].stringValue
                }
            }
        }
        return nil
    }
    
    private func prepareUpload(bucket: Bucket) throws -> (url: URL, authToken: String)? {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_upload_url")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["bucketId":"\(bucket.id)"], options: .prettyPrinted)
        
        let requestData = try executeRequest(request, withSessionConfig: nil)
        if let dict = (try? JSONSerialization.jsonObject(with: requestData, options: .mutableContainers)) as? [String: Any] {
            let uploadUrlStr = dict["uploadUrl"] as! String
            let uploadUrl = URL(string: uploadUrlStr)!
            return (url: uploadUrl, dict["authorizationToken"] as! String)
        }
        return nil
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
    
    internal func uploadFile(_ fileUrl: URL, withName fileName: String, toBucket bucket: Bucket, contentType: String, sha1: String) throws -> String? {
        guard let (uploadUrl, uploadAuthToken) = try self.prepareUpload(bucket: bucket) else {
            return nil
        }
        
        guard let encodedFilename = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw BackblazeError.urlEncodingFailed
        }
        
        var jsonStr: String? = nil
        if let fileData = try? Data(contentsOf: fileUrl) {
            var request = URLRequest(url: uploadUrl)
            request.httpMethod = "POST"
            request.addValue(uploadAuthToken, forHTTPHeaderField: "Authorization")
            
            request.addValue(encodedFilename, forHTTPHeaderField: "X-Bz-File-Name")
            request.addValue(contentType, forHTTPHeaderField: "Content-Type")
            request.addValue(sha1, forHTTPHeaderField: "X-Bz-Content-Sha1")
            if let requestData = self.executeUploadRequest(request, with: fileData) {
                jsonStr = String(data: requestData, encoding: .utf8)
            }
        }
        return jsonStr ?? ""
    }
    
    public func downloadFile(withId fileId: String) throws -> Data {
        guard let downloadUrl = self.downloadUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = downloadUrl.appendingPathComponent("/b2api/v1/b2_download_file_by_id")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fileId":"\(fileId)"], options: .prettyPrinted)
        
        return try executeRequest(request)
    }
    
    public func downloadFileEx(withId fileId: String) throws -> Data {
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
        
        return try executeRequest(request)
    }
    
    public func hideFile(named fileName: String, inBucket bucket: Bucket) throws -> JSON {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }

        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_hide_file")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileName\":\"\(fileName)\",\"bucketId\":\"\(bucket.id)\"}".data(using: .utf8, allowLossyConversion: false)
            
        return JSON(data: try executeRequest(request))
    }
    
    
    //MARK:- Common
    
    public func executeRequest(_ request: URLRequest, withSessionConfig sessionConfig: URLSessionConfiguration? = nil) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        
        let session: URLSession
        if let sessionConfig = sessionConfig {
            session = URLSession(configuration: sessionConfig)
        } else {
            session = URLSession.shared
        }
        
        var requestData: Data?
        let task = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                print("Erorr: \(error.localizedDescription)")
            }
            
            requestData = data
            semaphore.signal()
        }
        
        task.resume()
        semaphore.wait()
        
        if let data = requestData {
            return data
        } else {
            throw BackblazeError.malformedResponse
        }
    }
    
    public func executeRequest(jsonFrom request: URLRequest, withSessionConfig sessionConfig: URLSessionConfiguration? = nil) throws -> JSON {
        let data = try executeRequest(request, withSessionConfig: sessionConfig)
        return JSON(data: data)
    }
    
    //MARK:- Unprocessed
    
    public func b2ListFileVersions(bucketId: String, startFileName: String?, startFileId: String?, maxFileCount: Int) throws -> JSON {
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
        return JSON(data: try executeRequest(request))
    }
    
    public func b2GetFileInfo(fileId: String) throws -> JSON {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_get_file_info")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileId\":\"\(fileId)\"}".data(using: .utf8, allowLossyConversion: false)
        
        return JSON(data: try executeRequest(request))
    }
    
    public func b2DeleteFileVersion(fileId: String, fileName: String) throws -> JSON {
        guard let apiUrl = self.apiUrl, let authorizationToken = self.authorizationToken else {
            throw BackblazeError.unauthenticated
        }
        
        let url = apiUrl.appendingPathComponent("/b2api/v1/b2_delete_file_version")
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue(authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"fileName\":\"\(fileName)\",\"fileId\":\"\(fileId)\"}".data(using: .utf8, allowLossyConversion: false)
        
        return JSON(data: try executeRequest(request))
    }
}

