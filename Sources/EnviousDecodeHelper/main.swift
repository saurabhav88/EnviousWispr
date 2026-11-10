import Foundation
import MLX

// #4473 P2 packaging probe. This body proves one thing: an MLX executable that the app build
// embeds at Contents/MacOS/envious-decode finds the app's shared Metal library and runs a GPU
// operation. The EnviousDecode helper replaces it in a later P2 chunk; no code selects it yet.
let sum: Float = Device.withDefaultDevice(.gpu) {
  (MLXArray([1, 2, 3] as [Float]) * 2).sum().item(Float.self)
}

guard sum == 12 else {
  FileHandle.standardError.write(
    Data("envious-decode packaging probe FAILED: expected 12, got \(sum)\n".utf8))
  exit(1)
}

print("envious-decode packaging probe OK: sum=\(sum) bundle=\(Bundle.main.bundlePath)")
