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

// WAV header structure
struct WavHeader {
    var riff: (UInt8, UInt8, UInt8, UInt8) // "RIFF"
    var fileSize: UInt32
    var wave: (UInt8, UInt8, UInt8, UInt8) // "WAVE"
    var fmt: (UInt8, UInt8, UInt8, UInt8)  // "fmt "
    var fmtSize: UInt32
    var audioFormat: UInt16
    var numChannels: UInt16
    var sampleRate: UInt32
    var byteRate: UInt32
    var blockAlign: UInt16
    var bitsPerSample: UInt16
    var data: (UInt8, UInt8, UInt8, UInt8) // "data"
    var dataSize: UInt32
    
    init() {
        riff = (0, 0, 0, 0)
        fileSize = 0
        wave = (0, 0, 0, 0)
        fmt = (0, 0, 0, 0)
        fmtSize = 0
        audioFormat = 0
        numChannels = 0
        sampleRate = 0
        byteRate = 0
        blockAlign = 0
        bitsPerSample = 0
        data = (0, 0, 0, 0)
        dataSize = 0
    }
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
    func convertPCMDataToWAV(_ pcmData: Data, 
                        sampleRate: Int, 
                        numChannels: Int, 
                        bitsPerSample: Int) -> Data? {
    // Check input data
    guard !pcmData.isEmpty else {
        print("Error: PCM data is empty")
        return nil
    }
    
    // Create WAV header struct
    var header = WavHeader()
    
    // Fill RIFF header
    "RIFF".utf8CString.withUnsafeBytes { buffer in
        buffer.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: 4) {
            header.riff = ($0[0], $0[1], $0[2], $0[3])
        }
    }
    header.fileSize = UInt32(pcmData.count + MemoryLayout<WavHeader>.size - 8)
    "WAVE".utf8CString.withUnsafeBytes { buffer in
        buffer.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: 4) {
            header.wave = ($0[0], $0[1], $0[2], $0[3])
        }
    }
    
    // Fill fmt subchunk
    "fmt ".utf8CString.withUnsafeBytes { buffer in
        buffer.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: 4) {
            header.fmt = ($0[0], $0[1], $0[2], $0[3])
        }
    }
    header.fmtSize = 16 // Fixed size for PCM
    header.audioFormat = 1 // PCM
    header.numChannels = UInt16(numChannels)
    header.sampleRate = UInt32(sampleRate)
    header.bitsPerSample = UInt16(bitsPerSample)
    header.byteRate = UInt32(sampleRate * numChannels * bitsPerSample / 8)
    header.blockAlign = UInt16(numChannels * bitsPerSample / 8)
    
    // Fill data subchunk
    "data".utf8CString.withUnsafeBytes { buffer in
        buffer.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: 4) {
            header.data = ($0[0], $0[1], $0[2], $0[3])
        }
    }
    header.dataSize = UInt32(pcmData.count)
    
    // Create WAV data with header and PCM data
    var wavData = Data(bytes: &header, count: MemoryLayout<WavHeader>.size)
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
            if let wavData = convertPCMDataToWAV(currentSegmentData, 
                                       sampleRate: 48000, 
                                       numChannels: 1, 
                                       bitsPerSample: 32) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filePath = documentsDirectory.appendingPathComponent("output_\(Date().timeIntervalSince1970).wav").path
        saveWAVDataToFile(wavData: wavData, filePath: filePath)
    }
    currentSegmentData.removeAll()
        }
    }
}

extension RemoteAudioTrack: AudioRenderer {
    
    public func render(sampleBuffer: CMSampleBuffer) {
        if let pcmBuffer = convertSampleBufferToPCMBuffer(sampleBuffer: sampleBuffer) {

            let sampleRate = Int(pcmBuffer.format.sampleRate)
            let channels = pcmBuffer.format.channelCount
            let bitsPerSample = pcmBuffer.format.streamDescription.pointee.mBitsPerChannel
            print("实际采样率: \(sampleRate), 声道数: \(channels), 位深度: \(bitsPerSample)")
            

            if let pcmData = extractPCMData(from: sampleBuffer) {
                print("获取到PCM数据: \(pcmData.count)字节")
                currentSegmentData.append(pcmData)
                // 检查并处理数据
                checkAndProcessData()
            }
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

        print("convertSampleBufferToPCMBuffer sampleRate：%f  channels：%ld",Double(streamDesc.pointee.mSampleRate),AVAudioChannelCount(streamDesc.pointee.mChannelsPerFrame))
        
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

    //SampleBuffer data转换
    func extractPCMData(from sampleBuffer: CMSampleBuffer) -> Data? {
        // 1. 获取音频格式描述
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            print("无法获取格式描述")
            return nil
        }
        
        // 2. 验证是否为PCM格式
        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
        guard mediaType == kCMMediaType_Audio else {
            print("不是音频样本")
            return nil
        }
        
        // 3. 获取音频流描述
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            print("无法获取音频流描述")
            return nil
        }
        
        print("音频参数：采样率 \(streamDescription.pointee.mSampleRate)Hz, 声道数 \(streamDescription.pointee.mChannelsPerFrame)")
        
        // 4. 获取音频缓冲区
        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr else {
            print("获取音频缓冲区失败: \(status)")
            return nil
        }
        
        // 5. 提取PCM数据
        let buffers = UnsafeBufferPointer<AudioBuffer>(start: &audioBufferList.mBuffers, count: Int(audioBufferList.mNumberBuffers))
        var pcmData = Data()
        
        for buffer in buffers {
            let audioData = Data(bytes: buffer.mData!, count: Int(buffer.mDataByteSize))
            pcmData.append(audioData)
        }
        
        return pcmData
    }

}
