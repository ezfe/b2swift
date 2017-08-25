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
        case jsonProcessingFailed
    }
    
    private let authServerStr = "api.backblazeb2.com"
    private var emailAddress: String?
    
    public let accountId: String
    public let applicationKey: String
    
    private var ready = false
    
    internal var apiUrl: URL?
    private var downloadUrl: URL?
    internal var accountAuthorizationToken: String?
    
    public init(id: String, key: String) {
        self.accountId = id
        self.applicationKey = key
    }
    
    @discardableResult
    public func authorize() throws -> Bool {
        guard let url = URL(string: "https://\(self.authServerStr)/b2api/v1/b2_authorize_account") else {
            throw BackblazeError.urlConstructionFailed
        }
        
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
            let dict = JSON(data: requestData)
            
            self.downloadUrl = URL(string: dict["downloadUrl"].stringValue)
            self.apiUrl = URL(string: dict["apiUrl"].stringValue)
            self.accountAuthorizationToken = dict["authorizationToken"].stringValue
            
            return true
        } else {
            return false
        }
    }
    
    //MARK:- Buckets
    
    public func createBucket(named bucketName: String) -> Bucket? {
        
        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_create_bucket") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId":"\(self.accountId)", "bucketName":"\(bucketName)", "bucketType":"allPrivate"], options: .prettyPrinted)
            
            return Bucket(json: executeRequest(jsonFrom: request), b2: self)
        }
        
        return nil
    }
    
    public func listBuckets() throws -> [Bucket]  {
        guard let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_list_buckets") else {
            throw BackblazeError.urlConstructionFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId":"\(self.accountId)"], options: .prettyPrinted)
        let json = executeRequest(jsonFrom: request)
        
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
    
    public func listFileNames(in bucket: Bucket, startFileName: String? = nil, maxFileCount: Int? = nil) -> JSON? {
        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_list_file_names") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
            var params: JSON = ["bucketId": bucket.id]
            if let startFileStr = startFileName {
                params["startFileName"] = JSON(startFileStr)
            }
            if let maxFileCount = maxFileCount {
                params["startFileName"] = JSON(String(maxFileCount))
            }
            request.httpBody = try! params.rawData()
            if let requestData = executeRequest(request, withSessionConfig: nil) {
                return JSON(data: requestData)
            }
        }
        return nil
    }
    
    public func findFirstFileIdForName(searchFileName: String, bucket: Bucket) -> String? {
        guard let json = self.listFileNames(in: bucket, startFileName: nil, maxFileCount: -1) else {
            return nil
        }
        
        for (_, file): (String, JSON) in json {
            if file["fileName"].stringValue.caseInsensitiveCompare(searchFileName) == .orderedSame {
                return file["fileId"].stringValue
            }
        }
        return nil
    }
    
    private func prepareUpload(bucket: Bucket) -> (url: URL, authToken: String)? {
        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_get_upload_url") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["bucketId":"\(bucket.id)"], options: .prettyPrinted)
            if let requestData = executeRequest(request, withSessionConfig: nil) {
                if let dict = (try? JSONSerialization.jsonObject(with: requestData, options: .mutableContainers)) as? [String: Any] {
                    let uploadUrlStr = dict["uploadUrl"] as! String
                    let uploadUrl = URL(string: uploadUrlStr)!
                    return (url: uploadUrl, dict["authorizationToken"] as! String)
                }
            }
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
    
    internal func uploadFile(_ fileUrl: URL, withName fileName: String, toBucket bucket: Bucket, contentType: String, sha1: String) -> String? {
        guard let (uploadUrl, uploadAuthToken) = self.prepareUpload(bucket: bucket) else {
            return nil
        }
        
        var jsonStr: String? = nil
        if let fileData = try? Data(contentsOf: fileUrl) {
            var request = URLRequest(url: uploadUrl)
            request.httpMethod = "POST"
            request.addValue(uploadAuthToken, forHTTPHeaderField: "Authorization")
            request.addValue(fileName, forHTTPHeaderField: "X-Bz-File-Name")
            request.addValue(contentType, forHTTPHeaderField: "Content-Type")
            request.addValue(sha1, forHTTPHeaderField: "X-Bz-Content-Sha1")
            if let requestData = self.executeUploadRequest(request, with: fileData) {
                jsonStr = String(data: requestData, encoding: .utf8)
            }
        }
        return jsonStr ?? ""
    }
    
    public func downloadFile(withId fileId: String) -> Data? {
        var downloadedData: Data? = nil
        if let url = self.downloadUrl?.appendingPathComponent("/b2api/v1/b2_download_file_by_id") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["fileId":"\(fileId)"], options: .prettyPrinted)
            if let requestData = executeRequest(request) {
                downloadedData = requestData
            }
        }
        return downloadedData
    }
    
    public func downloadFileEx(withId fileId: String) -> Data? {
        var downloadedData: Data? = nil
        if let url = self.downloadUrl {
            if var urlComponents = URLComponents(string: url.appendingPathComponent("/b2api/v1/b2_download_file_by_id").absoluteString) {
                urlComponents.query = "fileId=\(fileId)"
                var request = URLRequest(url: urlComponents.url!)
                request.httpMethod = "GET"
                request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
                if let requestData = executeRequest(request) {
                    downloadedData = requestData
                }
            }
        }
        return downloadedData
    }
    
    
    public func hideFile(named fileName: String, inBucket bucket: Bucket) -> JSON? {
        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_hide_file") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
            request.httpBody = "{\"fileName\":\"\(fileName)\",\"bucketId\":\"\(bucket.id)\"}".data(using: .utf8, allowLossyConversion: false)
            
            if let requestData = executeRequest(request) {
                return JSON(data: requestData)
            }
        }
        return nil
    }
    
    
    //MARK:- Common
    
    public func executeRequest(_ request: URLRequest, withSessionConfig sessionConfig: URLSessionConfiguration? = nil) -> Data? {
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
        
        return requestData
    }
    
    public func executeRequest(jsonFrom request: URLRequest, withSessionConfig sessionConfig: URLSessionConfiguration? = nil) -> JSON {
        guard let data = executeRequest(request, withSessionConfig: sessionConfig) else {
            return JSON.null
        }
        
        return JSON(data: data)
    }
    
    //MARK:- Unprocessed
    
    public func b2ListFileVersions(bucketId: String, startFileName: String?, startFileId: String?, maxFileCount: Int) -> JSON? {
        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_list_file_versions") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
            
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
            
            if let data = try? params.rawData() {
                request.httpBody = data
                if let requestData = executeRequest(request) {
                    return JSON(data: requestData)
                }
            }
        }
        return nil
    }
    
    public func b2GetFileInfo(fileId: String) -> JSON? {
        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_get_file_info") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
            request.httpBody = "{\"fileId\":\"\(fileId)\"}".data(using: .utf8, allowLossyConversion: false)
            if let requestData = executeRequest(request) {
                return JSON(data: requestData)
            }
        }
        return nil
    }
    
    public func b2DeleteFileVersion(fileId: String, fileName: String) -> JSON? {
        if let url = self.apiUrl?.appendingPathComponent("/b2api/v1/b2_delete_file_version") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue(self.accountAuthorizationToken!, forHTTPHeaderField: "Authorization")
            request.httpBody = "{\"fileName\":\"\(fileName)\",\"fileId\":\"\(fileId)\"}".data(using: .utf8, allowLossyConversion: false)
            if let requestData = executeRequest(request) {
                return JSON(data: requestData)
            }
        }
        return nil
    }
}
