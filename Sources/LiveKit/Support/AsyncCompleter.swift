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

/// Manages a map of AsyncCompleters
actor CompleterMapActor<T> {
    // MARK: - Public

    public nonisolated let label: String

    // MARK: - Private

    private let _defaultTimeout: TimeInterval
    private var _completerMap = [String: AsyncCompleter<T>]()

    public init(label: String, defaultTimeout: TimeInterval) {
        self.label = label
        _defaultTimeout = defaultTimeout
    }

    public func completer(for key: String) -> AsyncCompleter<T> {
        // Return completer if already exists...
        if let element = _completerMap[key] {
            return element
        }

        let newCompleter = AsyncCompleter<T>(label: label, defaultTimeout: _defaultTimeout)
        _completerMap[key] = newCompleter
        return newCompleter
    }

    public func resume(returning value: T, for key: String) {
        let completer = completer(for: key)
        completer.resume(returning: value)
    }

    public func resume(throwing error: any Error, for key: String) {
        let completer = completer(for: key)
        completer.resume(throwing: error)
    }

    public func reset() {
        // Reset call completers...
        for (_, value) in _completerMap {
            value.reset()
        }
        // Clear all completers...
        _completerMap.removeAll()
    }
}

class AsyncCompleter<T>: Loggable {
    //
    struct WaitEntry {
        let continuation: UnsafeContinuation<T, Error>
        let timeoutBlock: DispatchWorkItem

        func cancel() {
            continuation.resume(throwing: LiveKitError(.cancelled))
            timeoutBlock.cancel()
        }

        func timeout() {
            continuation.resume(throwing: LiveKitError(.timedOut))
            timeoutBlock.cancel()
        }

        func resume(with result: Result<T, Error>) {
            continuation.resume(with: result)
            timeoutBlock.cancel()
        }
    }

    public let label: String

    private let _timerQueue = DispatchQueue(label: "LiveKitSDK.AsyncCompleter", qos: .background)

    // Internal states
    private var _defaultTimeout: DispatchTimeInterval
    private var _entries: [UUID: WaitEntry] = [:]
    private var _result: Result<T, Error>?

    private let _lock = UnfairLock()

    public init(label: String, defaultTimeout: TimeInterval) {
        self.label = label
        _defaultTimeout = defaultTimeout.toDispatchTimeInterval
    }

    deinit {
        reset()
    }

    public func set(defaultTimeout: TimeInterval) {
        _lock.sync {
            _defaultTimeout = defaultTimeout.toDispatchTimeInterval
        }
    }

    public func reset() {
        _lock.sync {
            log("把我 reset 吧 ", .warning)
            for entry in _entries.values {
                entry.cancel()
            }
            _entries.removeAll()
            _result = nil
        }
    }

    public func resume(with result: Result<T, Error>) {
        _lock.sync {
            log("resume 我被调用了 result \(String(describing: result))", .warning)
            for entry in _entries.values {
                log("取消我的定时器吧 entry \(String(describing: entry))", .warning)
                entry.resume(with: result)
            }
            _entries.removeAll()
            _result = result
            log("_result 从这里来？？ \(String(describing: _result))", .warning)
        }
    }

    public func resume(returning value: T) {
        log("resume 成功了？？？ \(label)", .warning)
        resume(with: .success(value))
    }

    public func resume(throwing error: Error) {
        log("resume 失败了？？？ \(label)", .warning)
        resume(with: .failure(error))
    }

    public func wait(timeout: TimeInterval? = nil) async throws -> T {
        // Read value
        if let result = _lock.sync({ _result }) {
            log("\(String(describing: _result)) _result 是啥呢 ", .warning)
            // Already resolved...
            if case let .success(value) = result {
                // resume(returning:) already called
                log("\(label) returning value...", .warning)
                return value
            } else if case let .failure(error) = result {
                // resume(throwing:) already called
                log("\(label) throwing error...", .warning)
                throw error
            }
        }

        // Create ids for continuation & timeoutBlock
        let entryId = UUID()

        // Create a cancel-aware timed continuation
        return try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { continuation in
                log("continuation 是啥啊 \(continuation)", .warning)

                // Create time-out block
                let timeoutBlock = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.log("Wait \(entryId) timedOut", .warning)
                    self._lock.sync {
                        if let entry = self._entries[entryId] {
                            self.log("给我返回了个超时啊", .warning)
                            entry.timeout()
                        }
                        self._entries.removeValue(forKey: entryId)
                    }
                }

                _lock.sync {
                    // Schedule time-out block
                    let computedTimeout = (timeout?.toDispatchTimeInterval ?? _defaultTimeout)
                    log("\(label) Schedule time-out block computedTimeout:\(computedTimeout)", .warning)
                    _timerQueue.asyncAfter(deadline: .now() + computedTimeout, execute: timeoutBlock)
                    // Store entry
                    _entries[entryId] = WaitEntry(continuation: continuation, timeoutBlock: timeoutBlock)

                    log("\(label) waiting \(computedTimeout) with id: \(entryId)", .warning)
                }
            }
        } onCancel: {
            log("Cancel only this completer when Task gets cancelled", .warning)
            // Cancel only this completer when Task gets cancelled
            _lock.sync {
                if let entry = self._entries[entryId] {
                    entry.cancel()
                }
                self._entries.removeValue(forKey: entryId)
            }
        }
    }
}
