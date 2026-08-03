import Foundation

public enum VolumeCurve {
  /// Maps the UI's 0...1 scalar to amplitude. Squaring gives useful low-volume resolution
  /// while preserving exact silence and unity gain at the endpoints.
  public static func gain(for scalar: Double) -> Float {
    let clamped = min(max(scalar, 0), 1)
    return Float(clamped * clamped)
  }
}
