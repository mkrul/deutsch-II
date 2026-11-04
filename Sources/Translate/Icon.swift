import AppKit

enum Palette {
    static let idle = NSColor(srgbRed: 228 / 255, green: 87 / 255, blue: 46 / 255, alpha: 1)
    static let working = NSColor(srgbRed: 196 / 255, green: 123 / 255, blue: 43 / 255, alpha: 1)
    static let showing = NSColor(srgbRed: 27 / 255, green: 58 / 255, blue: 75 / 255, alpha: 1)
    static let error = NSColor(srgbRed: 140 / 255, green: 47 / 255, blue: 47 / 255, alpha: 1)
    static let paper = NSColor(srgbRed: 247 / 255, green: 243 / 255, blue: 234 / 255, alpha: 242 / 255)
    static let ink = NSColor(srgbRed: 27 / 255, green: 58 / 255, blue: 75 / 255, alpha: 1)
    static let stroke = NSColor(srgbRed: 27 / 255, green: 58 / 255, blue: 75 / 255, alpha: 90 / 255)
}

enum TranslateMark {
    private static let pathData = "M12.87,15.07l-2.54,-2.51 0.03,-0.03c1.74,-1.94 2.98,-4.17 3.71,-6.53H17V4h-7V2H8v2H1v2h11.17C11.5,7.92 10.44,9.75 9,11.35 8.07,10.32 7.3,9.19 6.69,8h-2c0.73,1.63 1.73,3.17 2.98,4.56l-5.09,5.02L4,19l5,-5 3.11,3.11 0.76,-2.04zM18.5,10h-2L12,22h2l1.12,-3h4.75L21,22h2l-4.5,-12zM15.88,17l1.62,-4.33L19.12,17h-3.24z"

    static func draw(in rect: CGRect) {
        let path = bezier(from: pathData)
        NSGraphicsContext.saveGraphicsState()
        let scale = rect.width / 108 * 2.1
        let inset = rect.width * (28.8 / 108)
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX + inset, yBy: rect.maxY - inset)
        transform.scaleX(by: scale, yBy: -scale)
        transform.concat()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private static func bezier(from data: String) -> NSBezierPath {
        let tokens = tokenize(data)
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        var index = 0
        var command: Character = "M"
        var x: CGFloat = 0
        var y: CGFloat = 0
        var startX: CGFloat = 0
        var startY: CGFloat = 0

        func number() -> CGFloat {
            defer { index += 1 }
            if case .number(let value) = tokens[index] { return value }
            return 0
        }

        while index < tokens.count {
            if case .command(let next) = tokens[index] {
                command = next
                index += 1
                if command == "Z" || command == "z" {
                    path.close()
                    x = startX
                    y = startY
                    continue
                }
            }
            switch command {
            case "M":
                x = number()
                y = number()
                path.move(to: NSPoint(x: x, y: y))
                startX = x
                startY = y
                command = "L"
            case "m":
                x += number()
                y += number()
                path.move(to: NSPoint(x: x, y: y))
                startX = x
                startY = y
                command = "l"
            case "L":
                x = number()
                y = number()
                path.line(to: NSPoint(x: x, y: y))
            case "l":
                x += number()
                y += number()
                path.line(to: NSPoint(x: x, y: y))
            case "H":
                x = number()
                path.line(to: NSPoint(x: x, y: y))
            case "h":
                x += number()
                path.line(to: NSPoint(x: x, y: y))
            case "V":
                y = number()
                path.line(to: NSPoint(x: x, y: y))
            case "v":
                y += number()
                path.line(to: NSPoint(x: x, y: y))
            case "C":
                let x1 = number()
                let y1 = number()
                let x2 = number()
                let y2 = number()
                let endX = number()
                let endY = number()
                path.curve(
                    to: NSPoint(x: endX, y: endY),
                    controlPoint1: NSPoint(x: x1, y: y1),
                    controlPoint2: NSPoint(x: x2, y: y2)
                )
                x = endX
                y = endY
            case "c":
                let x1 = x + number()
                let y1 = y + number()
                let x2 = x + number()
                let y2 = y + number()
                let endX = x + number()
                let endY = y + number()
                path.curve(
                    to: NSPoint(x: endX, y: endY),
                    controlPoint1: NSPoint(x: x1, y: y1),
                    controlPoint2: NSPoint(x: x2, y: y2)
                )
                x = endX
                y = endY
            default:
                index += 1
            }
        }
        return path
    }

    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var index = data.startIndex
        while index < data.endIndex {
            let character = data[index]
            if character.isLetter {
                tokens.append(.command(character))
                index = data.index(after: index)
                continue
            }
            if character == "," || character.isWhitespace {
                index = data.index(after: index)
                continue
            }
            let start = index
            if data[index] == "+" || data[index] == "-" {
                index = data.index(after: index)
            }
            var sawDigit = false
            var sawDot = false
            while index < data.endIndex {
                let next = data[index]
                if next.isNumber {
                    sawDigit = true
                    index = data.index(after: index)
                } else if next == "." && !sawDot {
                    sawDot = true
                    index = data.index(after: index)
                } else {
                    break
                }
            }
            if sawDigit, let value = Double(data[start..<index]) {
                tokens.append(.number(CGFloat(value)))
            } else if index == start {
                index = data.index(after: index)
            }
        }
        return tokens
    }
}

enum AppIcon {
    static func make(side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let iconRect = rect.insetBy(dx: rect.width * 0.095, dy: rect.height * 0.095)
            let shape = squircle(in: iconRect)
            Palette.ink.setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            TranslateMark.draw(in: iconRect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func squircle(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let exponent: CGFloat = 5
        let steps = 160
        let centerX = rect.midX
        let centerY = rect.midY
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        for step in 0...steps {
            let angle = (CGFloat(step) / CGFloat(steps)) * 2 * CGFloat.pi
            let cosine = cos(angle)
            let sine = sin(angle)
            let point = NSPoint(
                x: centerX + radiusX * signedPower(cosine, 2 / exponent),
                y: centerY + radiusY * signedPower(sine, 2 / exponent)
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        return path
    }

    private static func signedPower(_ value: CGFloat, _ power: CGFloat) -> CGFloat {
        if value < 0 { return -pow(-value, power) }
        return pow(value, power)
    }
}

enum StatusIcon {
    static func image(caption: String?, color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            let oval = rect.insetBy(dx: 0.5, dy: 0.5)
            NSBezierPath(ovalIn: oval).fill()
            if caption == "…" {
                NSColor.white.setFill()
                let dot: CGFloat = 2.2
                let spacing: CGFloat = 1.8
                let total = dot * 3 + spacing * 2
                let originX = (rect.width - total) / 2
                let originY = (rect.height - dot) / 2
                for index in 0..<3 {
                    let mark = NSRect(
                        x: originX + CGFloat(index) * (dot + spacing),
                        y: originY,
                        width: dot,
                        height: dot
                    )
                    NSBezierPath(ovalIn: mark).fill()
                }
            } else if let caption {
                let fontSize: CGFloat
                switch caption.count {
                case ...1:
                    fontSize = 9
                case 2:
                    fontSize = 7.5
                case 3:
                    fontSize = 6
                default:
                    fontSize = 5
                }
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: style,
                ]
                let text = caption as NSString
                let textSize = text.size(withAttributes: attributes)
                let textRect = NSRect(
                    x: 0,
                    y: (rect.height - textSize.height) / 2 - 0.4,
                    width: rect.width,
                    height: textSize.height
                )
                text.draw(in: textRect, withAttributes: attributes)
            } else {
                TranslateMark.draw(in: oval)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
