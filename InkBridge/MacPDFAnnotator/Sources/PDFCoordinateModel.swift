import AppKit

struct PDFNormalizedPoint: Equatable, Sendable {
  let x: CGFloat
  let y: CGFloat
}

func normalizedPDFRotation(_ rotation: Int) -> Int {
  let value = rotation % 360
  return value >= 0 ? value : value + 360
}

func pagePoint(
  from normalized: PDFNormalizedPoint,
  bounds: NSRect,
  rotation: Int
) -> NSPoint {
  let x = min(1, max(0, normalized.x))
  let y = min(1, max(0, normalized.y))
  switch normalizedPDFRotation(rotation) {
  case 90:
    return NSPoint(x: bounds.minX + y * bounds.width, y: bounds.minY + x * bounds.height)
  case 180:
    return NSPoint(x: bounds.maxX - x * bounds.width, y: bounds.minY + y * bounds.height)
  case 270:
    return NSPoint(x: bounds.maxX - y * bounds.width, y: bounds.maxY - x * bounds.height)
  default:
    return NSPoint(x: bounds.minX + x * bounds.width, y: bounds.maxY - y * bounds.height)
  }
}

func normalizedPoint(
  from point: NSPoint,
  bounds: NSRect,
  rotation: Int
) -> PDFNormalizedPoint {
  guard bounds.width > 0, bounds.height > 0 else {
    return PDFNormalizedPoint(x: 0.5, y: 0.5)
  }
  let x: CGFloat
  let y: CGFloat
  switch normalizedPDFRotation(rotation) {
  case 90:
    x = (point.y - bounds.minY) / bounds.height
    y = (point.x - bounds.minX) / bounds.width
  case 180:
    x = (bounds.maxX - point.x) / bounds.width
    y = (point.y - bounds.minY) / bounds.height
  case 270:
    x = (bounds.maxY - point.y) / bounds.height
    y = (bounds.maxX - point.x) / bounds.width
  default:
    x = (point.x - bounds.minX) / bounds.width
    y = (bounds.maxY - point.y) / bounds.height
  }
  return PDFNormalizedPoint(
    x: min(1, max(0, x)),
    y: min(1, max(0, y))
  )
}

func visualPageWidth(bounds: NSRect, rotation: Int) -> CGFloat {
  switch normalizedPDFRotation(rotation) {
  case 90, 270: return bounds.height
  default: return bounds.width
  }
}
