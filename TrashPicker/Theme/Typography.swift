import SwiftUI

enum AppFont {
  // Use native San Francisco; rely on weight + size for hierarchy
  static let h1  = Font.system(size: 28, weight: .bold)
  static let h2  = Font.system(size: 22, weight: .bold)
  static let h3  = Font.system(size: 18, weight: .semibold)
  static let body = Font.system(size: 16, weight: .regular)
  static let sub  = Font.system(size: 14, weight: .regular)
  static let label = Font.system(size: 15, weight: .semibold)
}
