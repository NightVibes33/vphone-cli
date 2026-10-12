import SwiftUI
import MetalKit
import CoreImage
import CoreVideo

// A real CVPixelBuffer from the guest is required: never paint a fake SpringBoard.
final class GuestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var frameListener: (() -> Void)?

    func setFrameListener(_ listener: (() -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        frameListener = listener
    }

    func submitGuestFrame(_ buffer: CVPixelBuffer) {
        lock.lock()
        latestFrame = buffer
        let callback = frameListener
        lock.unlock()
        callback?()
    }

    func clear() {
        lock.lock()
        latestFrame = nil
        let callback = frameListener
        lock.unlock()
        callback?()
    }

    func currentFrame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latestFrame
    }
}

struct MetalGuestView: UIViewRepresentable {
    let frameStore: GuestFrameStore
    let onTouch: (Int, Double, Double) -> Void

    func makeCoordinator() -> MetalFrameRenderer {
        MetalFrameRenderer(frames: frameStore)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = GuestTouchMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.onGuestTouch = onTouch
        view.frameStore = frameStore
        frameStore.setFrameListener { [weak view] in
            DispatchQueue.main.async { view?.setNeedsDisplay() }
        }
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        // Only submit Metal work when a real VM image changes.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        (uiView as? GuestTouchMTKView)?.onGuestTouch = onTouch
    }
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        DispatchQueue.main.async { [weak view] in view?.setNeedsDisplay() }
    }

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


/// Real multi-touch events route into upstream vphoned guest-side HID injection.
final class GuestTouchMTKView: MTKView {
    var onGuestTouch: ((Int, Double, Double) -> Void)?
    var frameStore: GuestFrameStore?
    private func send(_ touches: Set<UITouch>, phase: Int) {
        guard let touch = touches.first, bounds.width > 0, bounds.height > 0,
              let buffer = frameStore?.currentFrame() else { return }
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(buffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        guard sourceWidth > 0, sourceHeight > 0 else { return }
        let scale = min(bounds.width / sourceWidth, bounds.height / sourceHeight)
        let display = CGRect(
            x: (bounds.width - sourceWidth * scale) / 2,
            y: (bounds.height - sourceHeight * scale) / 2,
            width: sourceWidth * scale, height: sourceHeight * scale)
        let position = touch.location(in: self)
        // Ignore black letterbox bars. Still deliver a release outside the
        // framebuffer so the guest never gets a permanently pressed finger.
        if phase != 3 && !display.contains(position) { return }
        let x = min(1, max(0, Double((position.x - display.minX) / display.width)))
        let y = min(1, max(0, Double((position.y - display.minY) / display.height)))
        onGuestTouch?(phase, x, y)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: 0)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: 1)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: 3)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: 3)
    }
}
