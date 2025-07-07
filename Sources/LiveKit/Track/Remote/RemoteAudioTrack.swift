/*
 * Copyright 2024 LiveKit
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

import CoreMedia
import AVFAudio


#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@objc
public class RemoteAudioTrack: Track, RemoteTrack, AudioTrack {
    // State used to manage AudioRenderers
    private struct RendererState {
        var didAttacheAudioRendererAdapter: Bool = false
        let audioRenderers = MulticastDelegate<AudioRenderer>(label: "AudioRenderer")
    }

    private lazy var _audioRendererAdapter = AudioRendererAdapter(target: self)
    private let _rendererState = StateSync(RendererState())
    
    private lazy var _pcmAudioRendererAdapter = AudioCustomProcessingDelegateAdapter(target: nil)


    /// Volume with range 0.0 - 1.0
    public var volume: Double {
        get {
            guard let audioTrack = mediaTrack as? LKRTCAudioTrack else { return 0 }
            return audioTrack.source.volume / 10
        }
        set {
            guard let audioTrack = mediaTrack as? LKRTCAudioTrack else { return }
            audioTrack.source.volume = newValue * 10
        }
    }

    init(name: String,
         source: Track.Source,
         track: LKRTCMediaStreamTrack,
         reportStatistics: Bool)
    {
        super.init(name: name,
                   kind: .audio,
                   source: source,
                   track: track,
                   reportStatistics: reportStatistics)
    }

    public func add(audioRenderer: AudioRenderer) {
        
        print("want add(audioRenderer = \(audioRenderer)")
        
        guard let audioTrack = mediaTrack as? LKRTCAudioTrack else { return }

        print("add(audioRenderer = \(audioTrack)")
        
        _rendererState.mutate {
            print("_rendererState.mutate = \($0)")
            print("didAttacheAudioRendererAdapter = \($0.didAttacheAudioRendererAdapter)")

            $0.audioRenderers.add(delegate: audioRenderer)
            if !$0.didAttacheAudioRendererAdapter {
                print("非 didAttacheAudioRendererAdapter = \($0.didAttacheAudioRendererAdapter)")
                print("非 _audioRendererAdapter = \(_audioRendererAdapter)")

                audioTrack.add(_audioRendererAdapter)
                _pcmAudioRendererAdapter.audioRenderers.add(delegate: audioRenderer)

                $0.didAttacheAudioRendererAdapter = true
            }
            print("add(audioRenderer over")

        }
    }

    public func remove(audioRenderer: AudioRenderer) {
        guard let audioTrack = mediaTrack as? LKRTCAudioTrack else { return }

        _rendererState.mutate {
            $0.audioRenderers.remove(delegate: audioRenderer)
            if $0.audioRenderers.allDelegates.isEmpty {
                audioTrack.remove(_audioRendererAdapter)
                _pcmAudioRendererAdapter.audioRenderers.remove(delegate: audioRenderer)

                $0.didAttacheAudioRendererAdapter = false
            }
        }
    }

    // MARK: - Internal

    override func startCapture() async throws {
        AudioManager.shared.trackDidStart(.remote)
    }

    override func stopCapture() async throws {
        AudioManager.shared.trackDidStop(.remote)
    }
}

extension RemoteAudioTrack: AudioRenderer {
    //
    public func render(sampleBuffer: CMSampleBuffer) {
        _rendererState.audioRenderers.notify { audioRenderer in
            audioRenderer.render?(sampleBuffer: sampleBuffer)
            print("pcmBuffer：%@",self.convertSampleBufferToPCMBuffer(sampleBuffer: sampleBuffer))
        }
    }
    
    
    public func render(pcmBuffer: AVAudioPCMBuffer) {
        print("come on pcmBuffer")
        _rendererState.audioRenderers.notify { audioRenderer in
            audioRenderer.render?(pcmBuffer: pcmBuffer)
        }
    }
    
    func convertSampleBufferToPCMBuffer(sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // 获取音频格式描述
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            print("获取音频格式描述失败")
            return nil
        }
        
        let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        
        // 创建 AVAudioFormat 对象
        guard let audioFormat = AVAudioFormat(streamDescription: streamDescription.pointee) else {
            print("创建 AVAudioFormat 失败")
            return nil
        }
        
        // 获取样本帧数
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        
        // 创建 AVAudioPCMBuffer
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("创建 AVAudioPCMBuffer 失败")
            return nil
        }
        
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // 获取音频缓冲区列表
        var bufferList: AudioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr else {
            print("获取音频缓冲区列表失败: \(status)")
            return nil
        }
        
        // 确保 blockBuffer 被释放
        defer {
            blockBuffer.map { CFRelease($0) }
        }
        
        // 复制音频数据到 PCMBuffer
        let bufferListPointer = UnsafeMutableAudioBufferListPointer(&bufferList)
        
        for buffer in bufferListPointer {
            let audioData = buffer.mData!
            let dataSize = buffer.mDataByteSize
            
            if audioFormat.channelCount == 1 {
                // 单声道
                let channelData = pcmBuffer.floatChannelData![0]
                memcpy(channelData, audioData, Int(dataSize))
            } else if audioFormat.channelCount == 2 {
                // 立体声
                let leftChannelData = pcmBuffer.floatChannelData![0]
                let rightChannelData = pcmBuffer.floatChannelData![1]
                
                // 假设是交错的立体声数据
                let interleavedData = audioData.assumingMemoryBound(to: Float.self)
                let frameCount = Int(dataSize) / (MemoryLayout<Float>.size * 2)
                
                for j in 0..<frameCount {
                    leftChannelData[j] = interleavedData[j * 2]
                    rightChannelData[j] = interleavedData[j * 2 + 1]
                }
            }
        }
        
        return pcmBuffer
    }

    
}
