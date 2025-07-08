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

    // 新增：用于存储当前音频数据
    private var currentSegmentData = Data()
    // 定义 1M 的字节数
    private let oneMB = 1024 * 1024

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
        print("init RemoteAudioTrack")
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

    // 新增：生成 WAV 头
    private func generateWAVHeader(sampleRate: Double, channels: UInt32, bitDepth: UInt32, dataSize: Int) -> Data {
        var header = Data()
        
        // ChunkID: "RIFF"
        header.append("RIFF".data(using: .ascii)!)
        // ChunkSize: 文件总大小 - 8
        var chunkSize = UInt32(36 + dataSize)
        header.append(Data(bytes: &chunkSize, count: 4))
        // Format: "WAVE"
        header.append("WAVE".data(using: .ascii)!)
        
        // Subchunk1ID: "fmt "
        header.append("fmt ".data(using: .ascii)!)
        // Subchunk1Size: 16 for PCM
        var subchunk1Size: UInt32 = 16
        header.append(Data(bytes: &subchunk1Size, count: 4))
        // AudioFormat: 1 for PCM
        var audioFormat: UInt16 = 1
        header.append(Data(bytes: &audioFormat, count: 2))
        
        // 将 channels 改为 var 变量
        var mutableChannels = channels
        // NumChannels
        header.append(Data(bytes: &mutableChannels, count: 2))
        
        // SampleRate
        var sampleRateUInt32 = UInt32(sampleRate)
        header.append(Data(bytes: &sampleRateUInt32, count: 4))
        // ByteRate = SampleRate * NumChannels * BitDepth / 8
        var byteRate = UInt32(sampleRate * Double(channels) * Double(bitDepth) / 8)
        header.append(Data(bytes: &byteRate, count: 4))
        // BlockAlign = NumChannels * BitDepth / 8
        var blockAlign = UInt16(channels * bitDepth / 8)
        header.append(Data(bytes: &blockAlign, count: 2))
        
        // 将 bitDepth 赋值给可变变量
        var mutableBitDepth = bitDepth
        // BitsPerSample
        header.append(Data(bytes: &mutableBitDepth, count: 2))
        
        // Subchunk2ID: "data"
        header.append("data".data(using: .ascii)!)
        // Subchunk2Size: 数据大小
        var subchunk2Size = UInt32(dataSize)
        header.append(Data(bytes: &subchunk2Size, count: 4))
        
        return header
    }

    // 新增：存储 WAV 数据到本地
    private func saveWAVDataToFile(wavData: Data, filePath: String) {
        do {
            try wavData.write(to: URL(fileURLWithPath: filePath))
            print("WAV file saved to \(filePath)")
        } catch {
            print("Error saving WAV file: \(error)")
        }
    }

    // 新增：实时检查和处理数据
    private func checkAndProcessData() {
        if currentSegmentData.count > oneMB {
            let sampleRate: Double = 44100
            let channels: UInt32 = 1
            let bitDepth: UInt32 = 16
            let wavHeader = generateWAVHeader(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth, dataSize: currentSegmentData.count)
            var wavData = wavHeader + currentSegmentData

            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let filePath = documentsDirectory.appendingPathComponent("output_\(Date().timeIntervalSince1970).wav").path
            saveWAVDataToFile(wavData: wavData, filePath: filePath)

            // 清空数据
            currentSegmentData.removeAll()
        }
    }
}

extension RemoteAudioTrack: AudioRenderer {
    
    public func render(sampleBuffer: CMSampleBuffer) {
        if let pcmBuffer = convertSampleBufferToPCMBuffer(sampleBuffer: sampleBuffer) {
            // 将 PCM 数据添加到 currentSegmentData
            let data = Data(bytes: pcmBuffer.floatChannelData![0], count: Int(pcmBuffer.frameLength * pcmBuffer.format.streamDescription.pointee.mBytesPerFrame))
            currentSegmentData.append(data)
            // 检查并处理数据
            checkAndProcessData()
        }
        print("sampleBuffer pcmBuffer：%@",self.convertSampleBufferToPCMBuffer(sampleBuffer: sampleBuffer))
        _rendererState.audioRenderers.notify { audioRenderer in
            audioRenderer.render?(sampleBuffer: sampleBuffer)
        }
    }
    
    
    public func render(pcmBuffer: AVAudioPCMBuffer) {
        // 将 PCM 数据添加到 currentSegmentData
        let data = Data(bytes: pcmBuffer.floatChannelData![0], count: Int(pcmBuffer.frameLength * pcmBuffer.format.streamDescription.pointee.mBytesPerFrame))
        currentSegmentData.append(data)
        // 检查并处理数据
        checkAndProcessData()

        print("pcmBuffer：%@",pcmBuffer)
        _rendererState.audioRenderers.notify { audioRenderer in
            audioRenderer.render?(pcmBuffer: pcmBuffer)
        }
    }
    
    //20250708 新增buffer转换方法
    func convertSampleBufferToPCMBuffer(sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // 获取音频格式描述
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            print("获取音频格式描述失败")
            return nil
        }
        
        // 获取音频流描述
        guard let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            print("无法获取音频流描述")
            return nil
        }
        
        // 创建 AVAudioFormat 对象（修复可选值问题）
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44100,
            channels: 1,
            interleaved: streamDesc.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )
        
        // 安全解包 audioFormat
        guard let format = audioFormat else {
            print("创建 AVAudioFormat 失败")
            return nil
        }
        
        // 获取样本帧数
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        
        // 创建 AVAudioPCMBuffer
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("创建 AVAudioPCMBuffer 失败")
            return nil
        }
        
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // 获取音频缓冲区列表
        var bufferList = AudioBufferList()
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
        
        // 处理单声道和立体声
        if format.channelCount == 1, let data = bufferList.mBuffers.mData {
            // 单声道
            let channelData = pcmBuffer.floatChannelData![0]
            let byteSize = Int(bufferList.mBuffers.mDataByteSize)
            memcpy(channelData, data, byteSize)
        } else if format.channelCount == 2, let data = bufferList.mBuffers.mData {
            // 立体声
            let leftChannelData = pcmBuffer.floatChannelData![0]
            let rightChannelData = pcmBuffer.floatChannelData![1]
            
            let floatData = data.assumingMemoryBound(to: Float.self)
            let frameCount = Int(bufferList.mBuffers.mDataByteSize) / (MemoryLayout<Float>.size * 2)
            
            for i in 0..<frameCount {
                leftChannelData[i] = floatData[i * 2]
                rightChannelData[i] = floatData[i * 2 + 1]
            }
        } else {
            print("不支持的声道数: \(format.channelCount)")
            return nil
        }
        
        return pcmBuffer
    }
}