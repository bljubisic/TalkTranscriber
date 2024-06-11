//
//  ContentView.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic on 05.06.24.
//

import SwiftUI
import WhisperKit
import CoreML

struct ContentView: View {
    @State var whisper: WhisperKit? = nil
    private var selectedModel = WhisperKit.recommendedModels().default
    @State private var isRecording: Bool = false
    @State private var isTranscribing: Bool = false
    @State private var transcriptionTask: Task<Void, Never>? = nil
    @State private var wordIndex = 0
    var timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    
    private var words = ["bicycle", "car", "chair.lounge"]
    
    @State private var bufferEnergy: [Float] = []
    @State private var bufferSeconds: Double = 0
    @State private var lastBufferSize: Int = 0
    @State var currentText: String = ""
    @State var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
    @State private var totalInferenceTime: TimeInterval = 0
    @State private var requiredSegmentsForConfirmation: Int = 1
    @State private var lastConfirmedSegmentEndSeconds: Float = 0
    @State private var tokensPerSecond: TimeInterval = 0
    @State private var firstTokenTime: TimeInterval = 0
    @State private var pipelineStart: TimeInterval = 0
    @State private var currentLag: TimeInterval = 0
    @State private var currentEncodingLoops: Int = 0
    @State private var effectiveRealTimeFactor: TimeInterval = 0
    @State private var effectiveSpeedFactor: TimeInterval = 0
    @State private var confirmedSegments: [TranscriptionSegment] = []
    @State private var unconfirmedSegments: [TranscriptionSegment] = []
    
    @State private var modelState: ModelState = .unloaded
    @State private var localModels: [String] = []
    @State private var localModelPath: String = ""
    @State private var availableModels: [String] = []
    @State private var availableLanguages: [String] = []
    @State private var disabledModels: [String] = WhisperKit.recommendedModels().disabled
    
    @State private var confirmedText: String = ""

    @State var modelStorage: String = "huggingface/models/argmaxinc/whisperkit-coreml"
    
    @AppStorage("repoName") private var repoName: String = "argmaxinc/whisperkit-coreml"
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.3
    @AppStorage("decoderComputeUnits") private var decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @AppStorage("encoderComputeUnits") private var encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @AppStorage("sampleLength") private var sampleLength: Double = 224
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true
    @AppStorage("enablePromptPrefill") private var enablePromptPrefill: Bool = true
    @AppStorage("enableCachePrefill") private var enableCachePrefill: Bool = true
    @AppStorage("enableSpecialCharacters") private var enableSpecialCharacters: Bool = false
    @AppStorage("chunkingStrategy") private var chunkingStrategy: ChunkingStrategy = .none
    
    var body: some View {
        VStack {
//            Button {
//                resetState()
//                loadModel(selectedModel)
//                modelState = .loading
//            } label: {
//                Text("Load Model")
//                    .frame(maxWidth: .infinity)
//                    .frame(height: 40)
//            }
//            .buttonStyle(.borderedProminent)
            Image(systemName: (modelState == .loaded && wordIndex < 3) ? words[wordIndex] : "")
                .font(.largeTitle)
                .onReceive(timer) { time in
                    if(modelState == .loaded) {
                        if wordIndex == 2 {
                            print("Stopping")
                            timer.upstream.connect().cancel()
                            stopRecording(true)
                        } else {
                            print("The time is now \(time)")
                        }
                        
                        wordIndex += 1
                    }
                }
            Spacer()
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(modelState == .loaded ? .green : (modelState == .unloaded ? .red : .yellow))
            Spacer()
            ForEach(Array(unconfirmedSegments.enumerated()), id: \.element) { _, segment in
                let timestampText = ""
                Text(timestampText + segment.text)
                    .font(.headline)
                    .fontWeight(.bold)
                    .tint(.green)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button{
//                isRecording = !isRecording
                toggleRecording(shouldLoop: true)
            }
        label: {
            Label(isRecording ? "Stop Recording": "Start Recording", systemImage: isRecording ? "stop.circle": "record.circle")
                .foregroundColor(.red)
        }.contentTransition(.symbolEffect(.replace))
                .font(.largeTitle)
                .disabled(modelState != .loaded)
        }
        .padding()
        .onAppear {
            fetchModels()
            resetState()
            loadModel(selectedModel)
            modelState = .loading
        }
    }
    
    
    func getComputeOptions() -> ModelComputeOptions {
        return ModelComputeOptions(audioEncoderCompute: encoderComputeUnits, textDecoderCompute: decoderComputeUnits)
    }
    
    func loadModel(_ model: String, redownload: Bool = false) {
        print("Selected Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "nil")")
        print("""
            Computing Options:
            - Mel Spectrogram:  \(getComputeOptions().melCompute.description)
            - Audio Encoder:    \(getComputeOptions().audioEncoderCompute.description)
            - Text Decoder:     \(getComputeOptions().textDecoderCompute.description)
            - Prefill Data:     \(getComputeOptions().prefillCompute.description)
        """)

        whisper = nil
        Task {
            whisper = try await WhisperKit(
                computeOptions: getComputeOptions(),
                verbose: true,
                logLevel: .none,
                prewarm: false,
                load: false,
                download: false
            )
            guard let whisperKit = whisper else {
                return
            }

            var folder: URL?

            // Check if the model is available locally
            if localModels.contains(model) && !redownload {
                // Get local model folder URL from localModels
                // TODO: Make this configurable in the UI
                folder = URL(fileURLWithPath: localModelPath).appendingPathComponent(model)
            } else {
                // Download the model
                folder = try await WhisperKit.download(variant: model, from: repoName, progressCallback: { progress in
                    DispatchQueue.main.async {
                        modelState = .downloading
                    }
                })
            }

            await MainActor.run {
                modelState = .downloaded
            }

            if let modelFolder = folder {
                whisperKit.modelFolder = modelFolder

                await MainActor.run {
                    // Set the loading progress to 90% of the way after prewarm
                    modelState = .prewarming
                }


                // Prewarm models
                do {
                    try await whisperKit.prewarmModels()
                } catch {
                    print("Error prewarming models, retrying: \(error.localizedDescription)")
                    if !redownload {
                        loadModel(model, redownload: true)
                        return
                    } else {
                        // Redownloading failed, error out
                        modelState = .unloaded
                        return
                    }
                }

                await MainActor.run {
                    // Set the loading progress to 90% of the way after prewarm
                    modelState = .loading
                }

                try await whisperKit.loadModels()

                await MainActor.run {
                    if !localModels.contains(model) {
                        localModels.append(model)
                    }

                    availableLanguages = Constants.languages.map { $0.key }.sorted()
                    modelState = whisperKit.modelState
                    toggleRecording(shouldLoop: true)
                }
            }
        }
    }
    
    func resetState() {
        isRecording = false
        isTranscribing = false
        whisper?.audioProcessor.stopRecording()
        currentText = ""

        pipelineStart = Double.greatestFiniteMagnitude
        firstTokenTime = Double.greatestFiniteMagnitude
        effectiveRealTimeFactor = 0
        effectiveSpeedFactor = 0
        totalInferenceTime = 0
        tokensPerSecond = 0
        currentLag = 0
        currentEncodingLoops = 0
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        requiredSegmentsForConfirmation = 2
        bufferEnergy = []
        bufferSeconds = 0
        confirmedSegments = []
        confirmedText = ""
        unconfirmedSegments = []

    }
    
    func toggleRecording(shouldLoop: Bool) {
        isRecording.toggle()

        if isRecording {
            startRecording(shouldLoop)
        } else {
            stopRecording(shouldLoop)
        }
    }
    
    func fetchModels() {
        availableModels = [selectedModel]

        // First check what's already downloaded
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let modelPath = documents.appendingPathComponent(modelStorage).path

            // Check if the directory exists
            if FileManager.default.fileExists(atPath: modelPath) {
                localModelPath = modelPath
                do {
                    let downloadedModels = try FileManager.default.contentsOfDirectory(atPath: modelPath)
                    for model in downloadedModels where !localModels.contains(model) {
                        localModels.append(model)
                    }
                } catch {
                    print("Error enumerating files at \(modelPath): \(error.localizedDescription)")
                }
            }
        }

        localModels = WhisperKit.formatModelFiles(localModels)
        for model in localModels {
            if !availableModels.contains(model),
               !disabledModels.contains(model)
            {
                availableModels.append(model)
            }
        }

        print("Found locally: \(localModels)")
        print("Previously selected model: \(selectedModel)")

        Task {
            let remoteModels = try await WhisperKit.fetchAvailableModels(from: repoName)
            for model in remoteModels {
                if !availableModels.contains(model),
                   !disabledModels.contains(model)
                {
                    availableModels.append(model)
                }
            }
            print("Available models: \(availableModels)")
        }
    }
    
    func startRecording(_ shouldLoop: Bool) {
        if let audioProcessor = whisper?.audioProcessor {
            Task(priority: .userInitiated) {
                guard await AudioProcessor.requestRecordPermission() else {
                    print("Microphone access was not granted.")
                    return
                }
                
                var deviceId: DeviceID?
                try? audioProcessor.startRecordingLive(inputDeviceID: deviceId) { _ in
                    DispatchQueue.main.async {
                        bufferEnergy = whisper?.audioProcessor.relativeEnergy ?? []
                        bufferSeconds = Double(whisper?.audioProcessor.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
                    }
                }
                // Delay the timer start by 1 second
                isRecording = true
                isTranscribing = true
                if shouldLoop {
                    realtimeLoop()
                }
            }
        }
    }
    
    func stopRecording(_ loop: Bool) {
        isRecording = false
        stopRealtimeTranscription()
        if let audioProcessor = whisper?.audioProcessor {
            audioProcessor.stopRecording()
        }

        // If not looping, transcribe the full buffer

            Task {
                do {
                    try await transcribeCurrentBuffer()
                } catch {
                    print("Error: \(error.localizedDescription)")
                }
            }
        resetState()
    }
    
    func stopRealtimeTranscription() {
        isTranscribing = false
        transcriptionTask?.cancel()
    }
    
    func realtimeLoop() {
        transcriptionTask = Task {
            while isRecording && isTranscribing {
                do {
                    try await transcribeCurrentBuffer()
                } catch {
                    print("Error: \(error.localizedDescription)")
                    break
                }
            }
        }
    }
    
    func transcribeCurrentBuffer() async throws{
        guard let whisperKit = whisper else {return}
        
        let currentBuffer = whisperKit.audioProcessor.audioSamples
        
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

        // Only run the transcribe if the next buffer has at least 1 second of audio
        guard nextBufferSeconds > 1 else {
            await MainActor.run {
                if currentText == "" {
                    currentText = "Waiting for speech..."
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // sleep for 100ms for next buffer
            return
        }
        
        let voiceDetected = AudioProcessor.isVoiceDetected(
            in: whisperKit.audioProcessor.relativeEnergy,
            nextBufferInSeconds: nextBufferSeconds,
            silenceThreshold: Float(silenceThreshold)
        )
        // Only run the transcribe if the next buffer has voice
        guard voiceDetected else {
            await MainActor.run {
                if currentText == "" {
                    currentText = "Waiting for speech..."
                }
            }

            // TODO: Implement silence buffer purging
//                if nextBufferSeconds > 30 {
//                    // This is a completely silent segment of 30s, so we can purge the audio and confirm anything pending
//                    lastConfirmedSegmentEndSeconds = 0
//                    whisperKit.audioProcessor.purgeAudioSamples(keepingLast: 2 * WhisperKit.sampleRate) // keep last 2s to include VAD overlap
//                    currentBuffer = whisperKit.audioProcessor.audioSamples
//                    lastBufferSize = 0
//                    confirmedSegments.append(contentsOf: unconfirmedSegments)
//                    unconfirmedSegments = []
//                }

            // Sleep for 100ms and check the next buffer
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        
        lastBufferSize = currentBuffer.count
        // Run realtime transcribe using timestamp tokens directly
        let transcription = try await transcribeAudioSamples(Array(currentBuffer))
        // We need to run this next part on the main thread
        await MainActor.run {
            currentText = ""
            guard let segments = transcription?.segments else {
                return
            }

            self.tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
            self.firstTokenTime = transcription?.timings.firstTokenTime ?? 0
            self.pipelineStart = transcription?.timings.pipelineStart ?? 0
            self.currentLag = transcription?.timings.decodingLoop ?? 0
            self.currentEncodingLoops += Int(transcription?.timings.totalEncodingRuns ?? 0)

            let totalAudio = Double(currentBuffer.count) / Double(WhisperKit.sampleRate)
            self.totalInferenceTime += transcription?.timings.fullPipeline ?? 0
            self.effectiveRealTimeFactor = Double(totalInferenceTime) / totalAudio
            self.effectiveSpeedFactor = totalAudio / Double(totalInferenceTime)

            // Logic for moving segments to confirmedSegments
            if segments.count > requiredSegmentsForConfirmation {
                // Calculate the number of segments to confirm
                let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation

                // Confirm the required number of segments
                let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
                let remainingSegments = Array(segments.suffix(requiredSegmentsForConfirmation))

                // Update lastConfirmedSegmentEnd based on the last confirmed segment
                if let lastConfirmedSegment = confirmedSegmentsArray.last, lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                    lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end

                    // Add confirmed segments to the confirmedSegments array
                    if !self.confirmedSegments.contains(confirmedSegmentsArray) {
                        self.confirmedSegments.append(contentsOf: confirmedSegmentsArray)
                    }
                }

                // Update transcriptions to reflect the remaining segments
                self.unconfirmedSegments = remainingSegments
            } else {
                // Handle the case where segments are fewer or equal to required
                self.unconfirmedSegments = segments
            }
        }
    }
    
    func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
        guard let whisperKit = whisper else { return nil }
        
        let languageCode = "en"
        let task: DecodingTask = .transcribe
        let seekClip: [Float] = []
        
        let options = DecodingOptions(
            verbose: true,
            task: task,
            language: languageCode,
            sampleLength: Int(sampleLength),
            usePrefillPrompt: enablePromptPrefill,
            usePrefillCache: enableCachePrefill,
            skipSpecialTokens: !enableSpecialCharacters,
            withoutTimestamps: !enableTimestamps,
            clipTimestamps: seekClip,
            chunkingStrategy: chunkingStrategy
        )
        
        let decodingCallback: ((TranscriptionProgress) -> Bool?) = { (progress: TranscriptionProgress) in
            DispatchQueue.main.async {
                let fallbacks = Int(progress.timings.totalDecodingFallbacks)
                let chunkId = progress.windowId

                // First check if this is a new window for the same chunk, append if so
                var updatedChunk = (chunkText: [progress.text], fallbacks: fallbacks)
                if var currentChunk = self.currentChunks[chunkId], let previousChunkText = currentChunk.chunkText.last {
                    if progress.text.count >= previousChunkText.count {
                        // This is the same window of an existing chunk, so we just update the last value
                        currentChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                        updatedChunk = currentChunk
                    } else {
                        // This is either a new window or a fallback (only in streaming mode)
                        if fallbacks == currentChunk.fallbacks && true {
                            // New window (since fallbacks havent changed)
                            updatedChunk.chunkText = currentChunk.chunkText + [progress.text]
                        } else {
                            // Fallback, overwrite the previous bad text
                            updatedChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                            updatedChunk.fallbacks = fallbacks
                            print("Fallback occured: \(fallbacks)")
                        }
                    }
                }

                // Set the new text for the chunk
                self.currentChunks[chunkId] = updatedChunk

                // Set the new text for the chunk
                let joinedChunks = self.currentChunks.sorted { $0.key < $1.key }.flatMap { $0.value.chunkText }.joined(separator: "\n")

                self.currentText = joinedChunks
            }

            // Check early stopping
            let currentTokens = progress.tokens

            if progress.avgLogprob! < options.logProbThreshold! {
                Logging.debug("Early stopping due to logprob threshold")
                return false
            }
            return nil
        }
        
        let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: decodingCallback
        )
        let mergedResults = mergeTranscriptionResults(transcriptionResults)

        return mergedResults
    }

}



#Preview {
    ContentView()
}
