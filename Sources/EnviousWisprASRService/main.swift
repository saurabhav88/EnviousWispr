import Foundation

let delegate = ASRServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
