import AppKit

@main
enum PDFCoordinateModelTests {
  static func main() {
    normalizedPointsRoundTripAcrossPageRotations()
    visualWidthUsesRotatedCropBoxGeometry()
    print("PDFCoordinateModelTests passed")
  }

  static func normalizedPointsRoundTripAcrossPageRotations() {
    let bounds = NSRect(x: 18, y: 27, width: 600, height: 800)
    let samples = [
      PDFNormalizedPoint(x: 0, y: 0),
      PDFNormalizedPoint(x: 1, y: 0),
      PDFNormalizedPoint(x: 0.5, y: 0.5),
      PDFNormalizedPoint(x: 0.17, y: 0.83),
      PDFNormalizedPoint(x: 1, y: 1),
    ]
    for rotation in [0, 90, 180, 270] {
      for sample in samples {
        let converted = pagePoint(from: sample, bounds: bounds, rotation: rotation)
        let roundTrip = normalizedPoint(from: converted, bounds: bounds, rotation: rotation)
        precondition(abs(roundTrip.x - sample.x) < 0.000_001)
        precondition(abs(roundTrip.y - sample.y) < 0.000_001)
      }
    }
  }

  static func visualWidthUsesRotatedCropBoxGeometry() {
    let bounds = NSRect(x: 0, y: 0, width: 600, height: 800)
    precondition(visualPageWidth(bounds: bounds, rotation: 0) == 600)
    precondition(visualPageWidth(bounds: bounds, rotation: 90) == 800)
    precondition(visualPageWidth(bounds: bounds, rotation: 180) == 600)
    precondition(visualPageWidth(bounds: bounds, rotation: 270) == 800)
  }
}
