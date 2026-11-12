// #4473 P2. Origin: Envious Labs LLC research, 2026-11 (the file
// Sources/DFlash/DFlashAcceptance.swift added to the research copy of SwiftLM; it has no
// upstream source and was never part of SharpAI's SwiftLM). The acceptance rule itself, keep
// the longest prefix of drafted tokens that the target model also chose, is the DFlash
// method's (Z Lab, arXiv:2602.06036).
// Changed in this port, 2026-11-10: `package` became internal; reformatted. The kernel source,
// the packet layout and the launch geometry are unchanged.

import MLX

enum DFlashAcceptance {
  private static let pack = MLXFast.metalKernel(
    name: "dflash_pack_acceptance", inputNames: ["verify", "posterior"],
    outputNames: ["packed"],
    source: #"""
      uint lane=thread_position_in_grid.x;
      int accepted=0;
      for(int i=0;i<COUNT-1;++i){
          if(verify[i+1]!=posterior[i]) break;
          ++accepted;
      }
      if(lane==0) packed[0]=accepted;
      if(lane<COUNT) packed[lane+1]=int(verify[lane]);
      """#)

  /// One GPU result, one host transfer: accept count and verified IDs.
  /// Host cache offsets still require the count; streamed tokens require IDs.
  static func packet(verify: MLXArray, posterior: MLXArray) -> [Int] {
    return pack(
      [verify, posterior], template: [("COUNT", verify.size)],
      grid: (max(32, verify.size), 1, 1), threadGroup: (32, 1, 1),
      outputShapes: [[verify.size + 1]], outputDTypes: [.int32])[0].asArray(Int.self)
  }
}
