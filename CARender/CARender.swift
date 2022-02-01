//
//  main.swift
//  CARender
//
//  Created by Matt Jacobson on 12/28/21.
//

import AppKit
import CoreFoundation
import CoreGraphics
import Foundation
import Metal
import OpenGL
import OpenGL.GL
import QuartzCore

extension String : Error {}

protocol Renderer {
    static func image(for layer: CALayer) -> CGImage
}

@main
struct Program {
    static func usage() {
        print("""

        USAGE: CARender [options] <input-file> <output-file>
            <input-file>          A Core Animation layer tree to render.
            <output-file>         Where to place the rendered result.

            --package             Loads the input file using CAPackage.
            --renderer=[coregraphics|metal|opengl]
                coregraphics      Renders the layer tree using a Core Graphics bitmap context.
                                  Many advanced features (e.g., filters, backdrops, meshes, some
                                  cases of group blending, and much more) are not implemented.
                metal             Renders the layer tree using the standard "OGL" Metal renderer.
                                  This is the default.
                opengl            Renders the layer tree using the "OGL" OpenGL renderer.
            --open                Opens the finished output file using Launch Services.
        """)
        exit(EX_USAGE)
    }

    static func main() {
        var inputURL: URL? = nil
        var outputURL: URL? = nil
        var isPackage: Bool = false
        var renderer: Renderer.Type = RendererOGLMetal.self
        var open: Bool = false

        for argument in CommandLine.arguments.dropFirst() {
            let indexOfEqualSign = argument.firstIndex(of: "=") ?? argument.endIndex
            let (baseName, value) = (argument[..<indexOfEqualSign], argument[indexOfEqualSign...].dropFirst())

            switch baseName {
            case "--package":
                isPackage = true

            case "--renderer":
                switch value {
                case "coregraphics": renderer = RendererCG.self
                case "opengl": renderer = RendererOGLOpenGL.self
                case "metal": renderer = RendererOGLMetal.self
                default:
                    print("ERROR: unrecognized renderer \"\(value)\"")
                    usage()
                }

            case "--open":
                open = true

            default:
                if inputURL == nil {
                    inputURL = URL(fileURLWithPath: argument)
                } else if outputURL == nil {
                    outputURL = URL(fileURLWithPath: argument)
                }
            }
        }

        if let inputURL = inputURL, let outputURL = outputURL {
            let layer: CALayer

            do {
                if isPackage {
                    layer = try loadPackageLayerTree(from: inputURL)
                } else {
                    layer = try loadLayerTree(from: inputURL)
                }

                print("Loaded layer tree from \(inputURL.path).")
            } catch {
                print("ERROR: could not load layer tree from input file \(inputURL.path)")
                exit(EX_DATAERR)
            }

            let img = renderer.image(for: layer)
            print("Rendered layer tree using \(renderer) renderer.")

            do {
                try img.write(to: outputURL)
                print("Wrote rendered image to \(outputURL.path).")
            } catch {
                print("ERROR: could not write rendered image to output file \(outputURL.path)")
                exit(EX_CANTCREAT)
            }

            if open {
                NSWorkspace.shared.open(outputURL)
            }
        } else {
            print("ERROR: did not provide both input and output files")
            usage()
        }
    }
}

extension Optional {
    func tryUnwrap() throws -> Wrapped {
        switch self {
        case .some(let wrapped): return wrapped
        case .none: throw "failed unwrap"
        }
    }
}

func loadPackageLayerTree(from url: URL) throws -> CALayer {
    let type: String

    switch url.pathExtension {
    case "caar":
        type = kCAPackageTypeArchive
    case "ca":
        type = kCAPackageTypeCAMLBundle
    case "caml":
        type = kCAPackageTypeCAMLFile
    default:
        throw "unrecognized package file extension"
    }

    let package = try CAPackage(contentsOf: url, type: type, options: nil)
    return try package.rootLayer.tryUnwrap()
}

func loadLayerTree(from url: URL) throws -> CALayer {
    let data = try Data(contentsOf: url)
    return try NSKeyedUnarchiver.unarchivedObject(ofClass: CALayer.self, from: data).tryUnwrap()
}

struct RendererCG: Renderer {
    static func image(for layer: CALayer) -> CGImage {
        let bounds = layer.bounds
        let pixelsWide = Int(bounds.width)
        let pixelsHigh = Int(bounds.height)
        let bytesPerRow = pixelsWide * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)!
        layer.render(in: ctx)

        return ctx.makeImage()!
    }
}

struct RendererOGLMetal: Renderer {
    static func image(for layer: CALayer) -> CGImage {
        let bounds = layer.bounds
        let pixelsWide = Int(bounds.width)
        let pixelsHigh = Int(bounds.height)
        let bytesPerRow = pixelsWide * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixelsWide, height: pixelsHigh, mipmapped: false)
        textureDescriptor.usage = .renderTarget

        let device = MTLCreateSystemDefaultDevice()!
        let texture = device.makeTexture(descriptor: textureDescriptor)!
        let commandQueue = device.makeCommandQueue()!

        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace : colorSpace,
            kCARendererMetalCommandQueue : commandQueue,
        ])
        renderer.layer = layer
        CATransaction.flush()

        // FIXME: why is this drawing upside down?  I'm forced to use a row-flipped data provider below as a result.
        renderer.bounds = bounds
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(bounds)
        renderer.render()
        renderer.endFrame()

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!

        let buffer = device.makeBuffer(length: pixelsHigh * bytesPerRow, options: .storageModeShared)!

        blitEncoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: buffer.length, options: [])
        blitEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let data = Data(bytes: buffer.contents(), count: buffer.length)

        // See above -- CARenderer is drawing upside-down.
        #if false
        let dataProvider = CGDataProvider(data: data as CFData)!
        #else
        let dataProvider = rowFlippedDataProvider(for: data, rows: pixelsHigh, rowBytes: bytesPerRow)
        #endif

        return CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

struct RendererOGLOpenGL: Renderer {
    static func image(for layer: CALayer) -> CGImage {
        func checkingCGLError(op: () -> (CGLError)) {
            let error = op()
            precondition(error == kCGLNoError)
        }

        func checkingGLError(op: () -> ()) {
            op()
            let error = glGetError()
            precondition(error == GL_NO_ERROR)
        }

        let bounds = layer.bounds
        let pixelsWide = Int(bounds.width)
        let pixelsHigh = Int(bounds.height)
        let bytesPerRow = pixelsWide * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        var pix: CGLPixelFormatObj! = nil
        var npix: GLint = 0
        checkingCGLError { CGLChoosePixelFormat([.init(0)], &pix, &npix) }
        precondition(pix != nil)

        var context: CGLContextObj! = nil
        checkingCGLError { CGLCreateContext(pix!, nil, &context) }
        precondition(context != nil)

        checkingCGLError { CGLSetCurrentContext(context) }

        // Set up an FBO.
        checkingGLError {
            var rb: GLuint = 0
            glGenRenderbuffers(1, &rb)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), rb)
            glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_RGBA), GLsizei(pixelsWide), GLsizei(pixelsHigh))

            var fbo: GLuint = 0
            glGenFramebuffers(1, &fbo)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), rb)

            let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
            precondition(status == GL_FRAMEBUFFER_COMPLETE)
        }

        // Draw some "uninitialzed red" into it.
        checkingGLError {
            glClearColor(1.0, 0.0, 0.0, 1.0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }

        // Set up the window.
        checkingGLError {
            glViewport(0, 0, GLsizei(pixelsWide), GLsizei(pixelsHigh))

            // Map CA's coordinates into GL world space
            glMatrixMode(GLenum(GL_MODELVIEW))
            glLoadIdentity()
            glOrtho(0, GLdouble(pixelsWide), 0, GLdouble(pixelsHigh), -1, 1)
        }

        let renderer = CARenderer(cglContext: context, options: [
            kCARendererColorSpace : colorSpace,
        ])
        renderer.layer = layer
        CATransaction.flush()

        renderer.bounds = bounds
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(bounds)
        renderer.render()
        renderer.endFrame()

        var data = Data(count: pixelsHigh * bytesPerRow)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            checkingGLError {
                glReadPixels(0, 0, GLsizei(pixelsWide), GLsizei(pixelsHigh), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_8_8_8_8_REV), bytes.baseAddress!)
            }
        }

        // glReadPixels() copies out the rows from bottom to top, so create a row-flipped data provider to feed the data to CG.
        let dataProvider = rowFlippedDataProvider(for: data, rows: pixelsHigh, rowBytes: bytesPerRow)

        return CGImage(width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

func rowFlippedDataProvider(for underlyingData: Data, rows: Int, rowBytes: Int) -> CGDataProvider {
    final class InfoBox {
        let underlyingData: Data
        let rows: Int
        let rowBytes: Int

        init(_ underlyingData: Data, _ rows: Int, _ rowBytes: Int) {
            self.underlyingData = underlyingData
            self.rows = rows
            self.rowBytes = rowBytes
        }
    }

    precondition(rows * rowBytes == underlyingData.count)

    var callbacks = CGDataProviderDirectCallbacks(
        version: 0,
        getBytePointer: nil,
        releaseBytePointer: nil,

        getBytesAtPosition: { (info: UnsafeMutableRawPointer?, buffer: UnsafeMutableRawPointer, position: off_t, count: Int) in
            let info = Unmanaged<InfoBox>.fromOpaque(info!).takeUnretainedValue()
            var currentPosition = Int(position)
            var currentCount = count

            while currentCount > 0 {
                let row = currentPosition / info.rowBytes
                let offset = currentPosition % info.rowBytes

                let flippedRow = (info.rows - 1) - row
                let location = flippedRow * info.rowBytes + offset
                let length = info.rowBytes - offset

                let pointer = buffer.advanced(by: currentPosition).assumingMemoryBound(to: UInt8.self)
                let range = location ..< (location + length)
                info.underlyingData.copyBytes(to: pointer, from: range)

                currentPosition += length
                currentCount -= length
            }

            return count
        },

        releaseInfo: { (info: UnsafeMutableRawPointer?) in
            Unmanaged<InfoBox>.fromOpaque(info!).release()
        }
    )

    let info = InfoBox(underlyingData, rows, rowBytes)
    return CGDataProvider(directInfo: Unmanaged.passRetained(info).toOpaque(), size: off_t(underlyingData.count), callbacks: &callbacks)!
}

extension CGImage {
    func write(to url: URL) throws {
        let type: CFString

        switch url.pathExtension {
        case "tiff":
            type = kUTTypeTIFF
        case "jpeg", "jpg":
            type = kUTTypeJPEG
        case "png":
            type = kUTTypePNG
        default:
            throw "unsupported extension"
        }

        let destination = try CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil).tryUnwrap()
        CGImageDestinationAddImage(destination, self, nil)
        CGImageDestinationFinalize(destination)
    }
}
