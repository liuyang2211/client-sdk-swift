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

import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

extension RTCPeerConnectionState {
    var isConnected: Bool {
        self == .connected
    }

    var isDisconnected: Bool {
        [.disconnected, .failed].contains(self)
    }
}

extension Room: TransportDelegate {
    func transport(_ transport: Transport, didUpdateState pcState: RTCPeerConnectionState) async {
        log("我擦? target: \(transport.target), connectionState: \(pcState.description)", .warning)
        
        self.peerConnectionState = pcState
        
        log("我擦? 赋值 self.peerConnectionState=\(self.peerConnectionState)", .warning)
        
        
        // primary connected
        if transport.isPrimary {
            
            if pcState.isConnected {
                log("transport.isPrimary => true pcState.isConnected => true", .warning)
                
                primaryTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                
                log("transport.isPrimary => true pcState.isDisconnected => true", .warning)
                
                primaryTransportConnectedCompleter.reset()
            }
        }

        log("publisher state => \(transport.target) ", .warning)
        
        // publisher connected
        if case .publisher = transport.target {
            if pcState.isConnected {
                log("publisher connected  pcState.isConnected => true", .warning)
                publisherTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                log("publisher connected  pcState.isDisconnected => true", .warning)
                publisherTransportConnectedCompleter.reset()
            }
        }

        if _state.connectionState == .connected {
            
            log("transport.isPrimary:\(transport.isPrimary) _state.hasPublished:\(_state.hasPublished) transport.target:\(transport.target) pcState.isDisconnected:\(pcState.isDisconnected)", .warning )
            
            // Attempt re-connect if primary or publisher transport failed
            if transport.isPrimary || (_state.hasPublished && transport.target == .publisher), pcState.isDisconnected {
                do {
                    log("webrtc流断连引起的 重连 transport startReconnect)", .warning )
                    try await startReconnect(reason: .transport)
                } catch {
                    log("Failed calling startReconnect, error: \(error)", .error)
                }
            }
        }
    }

    func transport(_ transport: Transport, didGenerateIceCandidate iceCandidate: LKRTCIceCandidate) async {
        do {
            log("搞事情啊 sending iceCandidate",.warning)
            try await signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
        } catch {
            log("Failed to send iceCandidate, error: \(error)", .error)
        }
    }

    func transport(_ transport: Transport, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) async {
        guard !streams.isEmpty else {
            log("Received onTrack with no streams!", .warning)
            return
        }

        if transport.target == .subscriber {
            // execute block when connected
            execute(when: { state, _ in state.connectionState == .connected },
                    // always remove this block when disconnected
                    removeWhen: { state, _ in state.connectionState == .disconnected })
            { [weak self] in
                guard let self else { return }
                Task {
                    await self.engine(self, didAddTrack: track, rtpReceiver: rtpReceiver, stream: streams.first!)
                }
            }
        }
    }

    func transport(_ transport: Transport, didRemoveTrack track: LKRTCMediaStreamTrack) async {
        if transport.target == .subscriber {
            await engine(self, didRemoveTrack: track)
        }
    }

    func transport(_ transport: Transport, didOpenDataChannel dataChannel: LKRTCDataChannel) async {
        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        if _state.isSubscriberPrimary, transport.target == .subscriber {
            switch dataChannel.label {
            case LKRTCDataChannel.labels.reliable: subscriberDataChannel.set(reliable: dataChannel)
            case LKRTCDataChannel.labels.lossy: subscriberDataChannel.set(lossy: dataChannel)
            default: log("Unknown data channel label \(dataChannel.label)", .warning)
            }
        }
    }

    func transportShouldNegotiate(_: Transport) async {}
}
