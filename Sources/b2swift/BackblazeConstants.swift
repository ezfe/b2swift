//
//  BackblazeConstants.swift
//  b2swift
//
//  Created by Ezekiel Elin on 9/10/17.
//

import Foundation

struct BackblazeHTTPHeaders {
    static let contentSHA1 = "X-Bz-Content-Sha1"
    static let contentType = "Content-Type"
    static let authorization = "Authorization"
    static let fileName = "X-Bz-File-Name"
}

struct BackblazeContentTypes {
    static let auto = "b2/x-auto"
}
