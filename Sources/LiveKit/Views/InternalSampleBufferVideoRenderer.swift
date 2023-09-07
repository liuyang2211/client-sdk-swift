/*
 * Copyright 2023 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import WebRTC

internal class InternalSampleBufferVideoRenderer: NativeView {

    public let sampleBufferDisplayLayer: AVSampleBufferDisplayLayer

    override init(frame: CGRect) {
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        super.init(frame: frame)
        sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        #if os(macOS)
        // this is required for macOS
        wantsLayer = true
        layer?.insertSublayer(sampleBufferDisplayLayer, at: 0)
        #elseif os(iOS)
        layer.insertSublayer(sampleBufferDisplayLayer, at: 0)
        #else
        fatalError("Unimplemented")
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performLayout() {
        super.performLayout()
        sampleBufferDisplayLayer.frame = bounds
    }
}

extension InternalSampleBufferVideoRenderer: RTCVideoRenderer {

    public func setSize(_ size: CGSize) {
        //
    }

    public func renderFrame(_ frame: RTCVideoFrame?) {

        guard let frame = frame else { return }

        guard let rtcPixelBuffer = frame.buffer as? RTCCVPixelBuffer else {
            logger.warning("frame.buffer is not a RTCCVPixelBuffer")
            return
        }

        guard let sampleBuffer = CMSampleBuffer.from(rtcPixelBuffer.pixelBuffer) else {
            logger.error("Failed to convert CVPixelBuffer to CMSampleBuffer")
            return
        }

        DispatchQueue.main.async {
            self.sampleBufferDisplayLayer.enqueue(sampleBuffer)
        }
    }
}