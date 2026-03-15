import Foundation

let delegate = AudioServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
