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

// 定义 WAV 文件头结构体
struct WavHeader {
    var riff: [UInt8] = Array("RIFF".utf8)
    var fileSize: UInt32 = 0
    var wave: [UInt8] = Array("WAVE".utf8)
    var fmt: [UInt8] = Array("fmt ".utf8)
    var fmtSize: UInt32 = 16
    var audioFormat: UInt16 = 1
    var numChannels: UInt16 = 0
    var sampleRate: UInt32 = 0
    var bitsPerSample: UInt16 = 0
    var byteRate: UInt32 = 0
    var blockAlign: UInt16 = 0
    var data: [UInt8] = Array("data".utf8)
    var dataSize: UInt32 = 0
}


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
    func convertPCMDataToWAV(pcmData: Data, sampleRate: Int, numChannels: Int, bitsPerSample: Int) -> Data? {
        // 检查输入数据
        if pcmData.isEmpty {
            print("错误：PCM数据为空")
            return nil
        }
        
        // 创建WAV文件头
        var header = WavHeader()
        
        // 填充RIFF头
        header.fileSize = UInt32(pcmData.count + MemoryLayout<WavHeader>.size - 8)
        
        // 填充fmt子块
        header.numChannels = UInt16(numChannels)
        header.sampleRate = UInt32(sampleRate)
        header.bitsPerSample = UInt16(bitsPerSample)
        header.byteRate = UInt32(sampleRate * numChannels * bitsPerSample / 8)
        header.blockAlign = UInt16(numChannels * bitsPerSample / 8)
        
        // 填充data子块
        header.dataSize = UInt32(pcmData.count)
        
        // 将结构体转换为 Data
        var headerData = Data()
        headerData.append(contentsOf: header.riff)
        headerData.append(header.fileSize.bigEndian.data)
        headerData.append(contentsOf: header.wave)
        headerData.append(contentsOf: header.fmt)
        headerData.append(header.fmtSize.bigEndian.data)
        headerData.append(header.audioFormat.bigEndian.data)
        headerData.append(header.numChannels.bigEndian.data)
        headerData.append(header.sampleRate.bigEndian.data)
        headerData.append(header.bitsPerSample.bigEndian.data)
        headerData.append(header.byteRate.bigEndian.data)
        headerData.append(header.blockAlign.bigEndian.data)
        headerData.append(contentsOf: header.data)
        headerData.append(header.dataSize.bigEndian.data)
        
        // 创建包含文件头和PCM数据的WAV数据
        var wavData = headerData
        wavData.append(pcmData)
        
        return wavData
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
            var wavData = convertPCMDataToWAV(currentSegmentData,44100,1,16)

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
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(streamDesc.pointee.mSampleRate),
            channels: AVAudioChannelCount(streamDesc.pointee.mChannelsPerFrame),
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
