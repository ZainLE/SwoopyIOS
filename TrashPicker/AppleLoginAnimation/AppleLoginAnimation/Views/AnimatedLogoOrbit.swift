import SwiftUI
import SpriteKit
import UIKit

struct AnimatedLogoOrbit: View {
    let images: [String]
    
    @State private var scene: AnimatedLogoOrbitScene?
    
    var body: some View {
        ZStack {
            if let scene {
                SpriteView(
                    scene: scene,
                    options: [.allowsTransparency]
                )
            }
        }
        .onAppear {
            setupScene()
        }
    }
    
    private func setupScene() {
        let newScene = AnimatedLogoOrbitScene()
        newScene.images = images
        newScene.scaleMode = .resizeFill
        scene = newScene
    }
}

class AnimatedLogoOrbitScene: SKScene {
    var images: [String] = []
    
    let dotsPerCircle = 23
    let numCircles = 4
    
    var outerCircleDots: [SKShapeNode] = []
    var nextIconIndex = 0
    var originalPositions: [CGPoint] = []
    
    let container = SKNode()
    
    // Badge configuration
    private let badgeRadius: CGFloat = 13.0
    private let symbolPointSize: CGFloat = 15.0
    
    // Curated light palette for Swoopy vibe
    private let symbolPalettes: [[UIColor]] = [
        // Mint & Teal
        [UIColor(red: 0.4, green: 0.85, blue: 0.75, alpha: 1.0),
         UIColor(red: 0.2, green: 0.7, blue: 0.65, alpha: 1.0)],
        // Fresh Green & Lime
        [UIColor(red: 0.6, green: 0.9, blue: 0.4, alpha: 1.0),
         UIColor(red: 0.45, green: 0.75, blue: 0.3, alpha: 1.0)],
        // Aqua & Sky
        [UIColor(red: 0.4, green: 0.8, blue: 0.9, alpha: 1.0),
         UIColor(red: 0.3, green: 0.65, blue: 0.8, alpha: 1.0)],
        // Light Lime & Spring
        [UIColor(red: 0.7, green: 0.87, blue: 0.3, alpha: 1.0),
         UIColor(red: 0.55, green: 0.72, blue: 0.25, alpha: 1.0)],
        // Seafoam & Mint
        [UIColor(red: 0.5, green: 0.9, blue: 0.7, alpha: 1.0),
         UIColor(red: 0.35, green: 0.75, blue: 0.55, alpha: 1.0)],
        // Bright Teal & Turquoise
        [UIColor(red: 0.3, green: 0.85, blue: 0.85, alpha: 1.0),
         UIColor(red: 0.2, green: 0.7, blue: 0.75, alpha: 1.0)],
        // Lime Zest & Green
        [UIColor(red: 0.75, green: 0.9, blue: 0.35, alpha: 1.0),
         UIColor(red: 0.6, green: 0.75, blue: 0.3, alpha: 1.0)],
        // Aquamarine & Ocean
        [UIColor(red: 0.45, green: 0.85, blue: 0.8, alpha: 1.0),
         UIColor(red: 0.3, green: 0.7, blue: 0.7, alpha: 1.0)]
    ]
    
    private let gradient: [(angle: CGFloat, color: SKColor)] = [
        (0, SKColor(red: 0/255, green: 81/255, blue: 63/255, alpha: 1)),          // Dark Green (right)
        (.pi / 2, SKColor(red: 180/255, green: 221/255, blue: 78/255, alpha: 1)), // Lime (top)
        (.pi, SKColor(red: 0/255, green: 81/255, blue: 63/255, alpha: 1)),        // Dark Green (left)
        (3 * .pi / 2, SKColor(red: 180/255, green: 221/255, blue: 78/255, alpha: 1)), // Lime (bottom)
        (2 * .pi, SKColor(red: 0/255, green: 81/255, blue: 63/255, alpha: 1))     // Dark Green (loop)
    ]
    
    override func didMove(to view: SKView) {
        self.backgroundColor = .clear
        physicsWorld.gravity = .zero
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        
        addChild(container)
        buildCircles()
        startRotation()
        animateNextIcon()
    }
    
    private func buildCircles() {
        let circles = generateCircles()
        var angleOffset: CGFloat = 0
        
        for (circleIndex, circle) in circles.enumerated() {
            for dotIndex in 0..<dotsPerCircle {
                var angle = (2 * .pi / CGFloat(dotsPerCircle) * CGFloat(dotIndex)) + angleOffset
                if angle > 2 * .pi { angle -= 2 * .pi }
                
                let position = CGPoint(x: circle.radius * cos(angle), y: circle.radius * sin(angle))
                
                let dot = SKShapeNode(circleOfRadius: circle.size)
                dot.position = position
                dot.fillColor = getColor(for: angle)
                dot.strokeColor = .clear
                dot.name = "dot-\(circleIndex)"
                dot.physicsBody = SKPhysicsBody(circleOfRadius: circle.size + 3)
                dot.physicsBody?.isDynamic = true
                dot.physicsBody?.affectedByGravity = false
                
                if circleIndex == 0 {
                    let step = Int(round(Double(dotsPerCircle) / Double(images.count)))
                    
                    if dotIndex % step == 0 {
                        placeIconOnOuterCircle(for: dot)
                        outerCircleDots.append(dot)
                    }
                }
                
                container.addChild(dot)
                originalPositions.append(position)
            }
            
            angleOffset += 0.4
        }
        
        // icons should animate clockwise
        outerCircleDots.reverse()
    }
    
    private func placeIconOnOuterCircle(for dot: SKShapeNode) {
        guard !images.isEmpty else { return }
        let index = outerCircleDots.count % images.count
        let symbolName = images[index]
        let paletteIndex = outerCircleDots.count % symbolPalettes.count
        let paletteColors = symbolPalettes[paletteIndex]

        // Create badge container node
        let badgeContainer = SKNode()
        badgeContainer.name = "badge"
        badgeContainer.alpha = 0
        
        // Create circular background with soft white fill
        let background = SKShapeNode(circleOfRadius: badgeRadius)
        background.fillColor = UIColor(white: 1.0, alpha: 0.95)
        background.strokeColor = UIColor(white: 0.85, alpha: 0.3)
        background.lineWidth = 1.0
        background.glowWidth = 2.0
        badgeContainer.addChild(background)

        if let assetNode = createAssetNode(named: symbolName) {
            badgeContainer.addChild(assetNode)
        } else {
            let resolvedPalette = palette(for: symbolName, defaultPalette: paletteColors)
            if let symbolTexture = createSymbolTexture(symbolName: symbolName, palette: resolvedPalette) {
                let symbolSprite = SKSpriteNode(texture: symbolTexture)
                symbolSprite.size = CGSize(width: symbolPointSize, height: symbolPointSize)
                symbolSprite.position = CGPoint.zero
                badgeContainer.addChild(symbolSprite)
            } else if let fallbackTexture = createSymbolTexture(symbolName: "checkmark.circle.fill", palette: paletteColors) {
                let symbolSprite = SKSpriteNode(texture: fallbackTexture)
                symbolSprite.size = CGSize(width: symbolPointSize, height: symbolPointSize)
                symbolSprite.position = CGPoint.zero
                badgeContainer.addChild(symbolSprite)
            }
        }
        
        dot.addChild(badgeContainer)
    }

    private func createAssetNode(named name: String) -> SKNode? {
        let bundles: [Bundle] = [Bundle.main, Bundle(for: AnimatedLogoOrbitScene.self)]
        let image = bundles.compactMap { UIImage(named: name, in: $0, compatibleWith: nil) }.first
        guard let image else { return nil }
        let texture = SKTexture(image: image)
        texture.usesMipmaps = true
        texture.filteringMode = .linear
        let sprite = SKSpriteNode(texture: texture)

        let targetDiameter = max(badgeRadius * 2, 0)
        let imageSize = image.size
        if imageSize.width > 0, imageSize.height > 0 {
            let scale = max(targetDiameter / imageSize.width, targetDiameter / imageSize.height)
            let newSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            sprite.size = newSize
        } else {
            sprite.size = CGSize(width: targetDiameter, height: targetDiameter)
        }

        sprite.position = CGPoint.zero
        sprite.colorBlendFactor = 0

        let cropNode = SKCropNode()
        cropNode.name = "assetCrop"
        cropNode.position = .zero

        let maskDiameter = targetDiameter
        let mask = SKShapeNode(circleOfRadius: maskDiameter / 2)
        mask.fillColor = .white
        mask.strokeColor = .clear
        mask.lineWidth = 0
        cropNode.maskNode = mask

        cropNode.addChild(sprite)
        return cropNode
    }
    
    private func createSymbolTexture(symbolName: String, palette: [UIColor]) -> SKTexture? {
        // Create hierarchical color configuration for provided palette
        let paletteConfig = UIImage.SymbolConfiguration(paletteColors: palette)
        let sizeConfig = UIImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        let combinedConfig = paletteConfig.applying(sizeConfig)
        
        guard let symbolImage = UIImage(systemName: symbolName, withConfiguration: combinedConfig) else {
            return nil
        }
        
        // Render the symbol with proper alignment
        let renderer = UIGraphicsImageRenderer(size: symbolImage.size)
        let renderedImage = renderer.image { context in
            symbolImage.draw(at: .zero)
        }
        
        return SKTexture(image: renderedImage)
    }
    
    private func palette(for symbolName: String, defaultPalette: [UIColor]) -> [UIColor] {
        switch symbolName {
        case "checkmark.seal.fill", "checkmark.circle.fill", "checkmark.circle.dotted":
            // Solid Swoopy lime tone
            let lime = UIColor(red: 180/255, green: 221/255, blue: 78/255, alpha: 1.0)
            return [lime, lime]
        case "person.2.fill", "person.fill", "person.crop.circle.fill":
            // Deeper teal tones for better contrast
            return [
                UIColor(red: 0.17, green: 0.32, blue: 0.42, alpha: 1.0),
                UIColor(red: 0.10, green: 0.22, blue: 0.30, alpha: 1.0)
            ]
        default:
            return defaultPalette
        }
    }
    private func startRotation() {
        let rotate = SKAction.rotate(byAngle: .pi * -2, duration: 10)
        container.run(.repeatForever(rotate))
    }
    
    private func animateNextIcon() {
        let dot = outerCircleDots[nextIconIndex]
        
        dot.physicsBody? = SKPhysicsBody(circleOfRadius: 10)
        dot.physicsBody?.density = 110
        dot.physicsBody?.isDynamic = false
        
        let scaleIcon = SKAction.run {
            let a1 = SKAction.scale(to: 4.0 * 1.1, duration: 0.1)
            let a2 = SKAction.scale(to: 4.0, duration: 0.1)
            
            dot.run(.sequence([a1, a2]))
            
            dot.childNode(withName: "badge")?.alpha = 1
        }
        
        let wait = SKAction.wait(forDuration: 1)
        
        let shrinkIcon = SKAction.run {
            let scale = SKAction.scale(to: 1.0, duration: 0.6)
            scale.timingFunction = SpriteKitTimingFunctions.easeInQuad
            dot.run(scale)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                let badge = dot.childNode(withName: "badge")
                let fade = SKAction.fadeAlpha(to: 0, duration: 0.1)
                badge?.run(fade)
            }
        }
        
        // move dots back to their original position
        let moveDots = SKAction.run {
            for (i, surroundingDot) in self.container.children.enumerated()
            where !surroundingDot.position.isApproximatelyEqual(to: self.originalPositions[i])
            {
                let moveAction = SKAction.move(to: self.originalPositions[i], duration: 0.6)
                moveAction.timingFunction = SpriteKitTimingFunctions.easeInQuad
                surroundingDot.run(moveAction)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.nextIconIndex = (self.nextIconIndex + 1) % self.outerCircleDots.count
                self.animateNextIcon()
            }
        }

        dot.run(.sequence([scaleIcon, wait, moveDots, shrinkIcon])) {
            dot.physicsBody?.isDynamic = true
        }
    }
    
    private func generateCircles() -> [(radius: CGFloat, size: CGFloat)] {
        let radiusStep = 15
        let initialRadius = 75
        var dotSize = 4
        
        var circles: [(CGFloat, CGFloat)] = []
        
        for circleIndex in 0..<numCircles {
            let radius = CGFloat(initialRadius + (circleIndex * radiusStep))
            circles.append((CGFloat(radius), CGFloat(dotSize)))
            
            if circleIndex == 0 {
                dotSize += 2
            } else if circleIndex % 2 == 0 {
                dotSize += 3
            } else {
                dotSize -= 1
            }
        }
        
        return Array(circles.reversed())
    }
    
    override func update(_ currentTime: TimeInterval) {
        for case let dot as SKShapeNode in container.children {
            let worldPos = container.convert(dot.position, to: self)
            var angle = atan2(worldPos.y, worldPos.x)
            
            // normalise from -pi...pi to 0...2pi
            if angle < 0 {
                angle += 2 * .pi
            }
            
            dot.fillColor = getColor(for: angle)
            
            // Counter-rotate all badges to keep them upright
            if let badge = dot.childNode(withName: "badge") {
                badge.zRotation = -container.zRotation
            }
        }
    }
    
    private func getColor(for angle: CGFloat) -> SKColor {
        guard let startIndex = gradient.lastIndex(where: { $0.angle <= angle }) else {
            return .white
        }
        
        let endIndex = startIndex + 1
        
        let start = gradient[startIndex]
        let end = gradient[endIndex]
        
        let percent = (angle - start.angle) / (end.angle - start.angle)
        
        let r = start.color.rgba.red + (end.color.rgba.red - start.color.rgba.red) * percent
        let g = start.color.rgba.green + (end.color.rgba.green - start.color.rgba.green) * percent
        let b = start.color.rgba.blue + (end.color.rgba.blue - start.color.rgba.blue) * percent
        
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }
    
}

#Preview {
    AnimatedLogoOrbit(
        images: [
            "mappin.and.ellipse",
            "shippingbox",
            "leaf.fill",
            "sparkles",
            "person.2.fill",
            "house.fill",
            "FirstItem",
            "SecondItem"
        ]
    )
}
