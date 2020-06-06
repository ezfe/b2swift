//
//  Data+Digests.swift
//  
//
//  Created by Ezekiel Elin on 5/29/20.
//

import Foundation
import Crypto

extension Data {
    var sha1: String {
        let digest = Insecure.SHA1.hash(data: self)
        return digest.map({ String(format: "%02x", $0) }).joined()
    }
}
