import SwiftUI
import MetalKit
import CoreImage
import CoreVideo

// A real CVPixelBuffer from the guest is required: never paint a fake SpringBoard.
final class GuestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: CVPixelBuffer?
    func submitGuestFrame(_ buffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        latestFrame = buffer
    }
    func currentFrame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latestFrame
    }
}

struct MetalGuestView: UIViewRepresentable {
    let frameStore: GuestFrameStore

    func makeCoordinator() -> MetalFrameRenderer {
        MetalFrameRenderer(frames: frameStore)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

final class MetalFrameRenderer: NSObject, MTKViewDelegate {
    private let frames: GuestFrameStore
    private let queue: MTLCommandQueue?
    private let context: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(frames: GuestFrameStore) {
        self.frames = frames
        if let device = MTLCreateSystemDefaultDevice() {
            self.queue = device.makeCommandQueue()
            self.context = CIContext(mtlDevice: device)
        } else {
            self.queue = nil
            self.context = nil
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = queue?.makeCommandBuffer() else { return }
        let buffer = frames.currentFrame()
        if let buffer, let context {
            let image = CIImage(cvPixelBuffer: buffer)
            let original = image.extent
            let destination = view.drawableSize
            guard original.width > 0 && original.height > 0 else { return }
            let scale = min(destination.width / original.width, destination.height / original.height)
            let translationX = (destination.width - original.width * scale) / 2
            let translationY = (destination.height - original.height * scale) / 2
            let scaled = image.transformed(by:
                CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: translationX, y: translationY)))
            context.render(scaled, to: drawable.texture, commandBuffer: commandBuffer,
                           bounds: CGRect(origin: .zero, size: destination), colorSpace: colorSpace)
        } else {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
