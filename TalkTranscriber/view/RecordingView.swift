//
//  RecordingView.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic Home  on 6/18/24.
//

import SwiftUI
import WhisperKit
import AVFoundation
import CoreML
import Combine
import Speech

struct recordingView: View {
    @EnvironmentObject var readyForRecording: ReadyForRecording
    
    let transcriptionEnded = TranscriptionEnded(isAppleTranscriptionEnded: false, isWhisperTranscriptionEnded: false)
    
    @State var whisper: WhisperKit? = nil
    var selectedModel = "base.en"
    @State private var isRecording: Bool = false
    @State private var isTranscribing: Bool = false
    @State private var transcriptionTask: Task<Void, Never>? = nil
    @State private var wordIndex = 0
    @State private var timer: Publishers.Autoconnect<Timer.TimerPublisher>? = nil
    
    @State private var transcribeFileTask: Task<Void, Never>? = nil
    
    @State var audioFile: URL = URL(fileURLWithPath: "")
    
    var reference = ["2024", "june", "wednesday", "joe biden", "car", "clock", "pen"]
//    var words = ["car", "clock", "pencil"]
    @State var audioRecorder: AVAudioRecorder?
    
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
    
    @State var fileFolderURL: URL = URL(fileURLWithPath: "")

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
    @AppStorage("chunkingStrategy") private var chunkingStrategy: ChunkingStrategy = .vad
    
    var body: some View {
        VStack {
            if let timer = timer {
                if wordIndex < 7 {
                    Text(reference[wordIndex])
                        .font(.largeTitle)
                        .onReceive(timer) { time in
                            if(modelState == .loaded) {
                                if wordIndex == 6 {
                                    print("Stopping")
                                    self.timer?.upstream.connect().cancel()
                                    stopRecording(true)
                                } else {
                                    print("The time is now \(time)")
                                }
                                
                                wordIndex += 1
                            }
                        }
                }
            }
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

            Text((modelState != .loaded) ? "Model Loading" : (isRecording ? "Recording": ""))
                .foregroundStyle(isRecording ? .green : .red)
                .font(.largeTitle)

            Button(action: {
//                resetState()
                toggleRecording(shouldLoop: false)
            }, label: {
                Text(isRecording ? Image(systemName: "stop.circle") : Image(systemName: "record.circle"))
                    .font(.largeTitle)
                    .tint(.red)
            })
            .disabled((modelState == .loaded || !isTranscribing) ? false : true)

        }
        .padding()
        .onAppear {
            do {
                fileFolderURL = try createNewFolder()
                requestRecordPermission(folder: fileFolderURL)
            } catch {
                print(error)
            }
            fetchModels()
//            resetState()
            loadModel(selectedModel)
            modelState = .loading
        }
        .onReceive(Publishers.CombineLatest(transcriptionEnded.$isAppleTranscriptionEnded, transcriptionEnded.$isWhisperTranscriptionEnded), perform: {isAppleEnded, isWhisperEnded in
            if isAppleEnded && isWhisperEnded {
                do {
                    try FileManager.default.removeItem(atPath: audioFile.path())
                    resetState()
                } catch {
                    print(error)
                }
            }

        })
    }
    
    func requestRecordPermission(folder: URL) {
        AVAudioApplication.requestRecordPermission { granted in
            if granted {
                do {
                    try setupAudioSession()
                    try setupRecorder(folder: folder)
                } catch {
                    print(error)
                }
            } else {
                // Handle permission denied
            }
        }
    }
    
    func setupRecorder(folder: URL) throws {
        let recordingSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 12000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue] as [String : Any]
//        let documentPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        audioFile = folder.appendingPathComponent("recording.m4a")
        
        audioRecorder = try AVAudioRecorder(url: audioFile, settings: recordingSettings)
        audioRecorder?.prepareToRecord()
    }
    
    func setupAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default)
        try audioSession.setActive(true)
    }
    
    func createNewFolder() throws -> URL {
        let manager = FileManager.default
        
        let rootFolder = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let nestedFolderURL = rootFolder.appendingPathComponent(UUID().uuidString)
        do {
            try manager.createDirectory(
                at: nestedFolderURL,
                withIntermediateDirectories: false,
                attributes: nil
            )
        } catch CocoaError.fileWriteFileExists {
            print("Folder Exists")
            // Folder already existed
        } catch {
            print(error)
            throw error
        }
        return nestedFolderURL
    }
    
    func getComputeOptions() -> ModelComputeOptions {
        return ModelComputeOptions(audioEncoderCompute: encoderComputeUnits, textDecoderCompute: decoderComputeUnits)
    }
    
    private func loadModel(_ model: String, redownload: Bool = false) {
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
//                    toggleRecording(shouldLoop: true)
                }
            }
        }
    }
    
    private func resetState() {
        isRecording = false
        isTranscribing = false
        whisper?.audioProcessor.stopRecording()
        currentText = ""
        wordIndex = 0

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
        transcriptionEnded.isAppleTranscriptionEnded = false
        transcriptionEnded.isWhisperTranscriptionEnded = false
        readyForRecording.isReadyForRecording = false
        self.timer?.upstream.connect().cancel()
    }
    
    private func toggleRecording(shouldLoop: Bool) {
        isRecording.toggle()

        if isRecording {
            self.timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
            startRecording(shouldLoop)
        } else {
            stopRecording(shouldLoop)
//            resetState()
        }
    }
    
    private func fetchModels() {
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
    
    private func startRecording(_ shouldLoop: Bool) {
        audioRecorder?.record()
    }
    
    private func stopRecording(_ loop: Bool) {
        let manager = FileManager.default
        isRecording = false
        isTranscribing = true
        audioRecorder?.stop()
        transcribeFile(path: audioFile.path())
        recognizeFile(url: audioFile)
        
//        resetState()
    }
    
    func recognizeFile(url: URL) {
        
        // Create a speech recognizer associated with the user's default language.
        guard let myRecognizer = SFSpeechRecognizer() else {
            // The system doesn't support the user's default language.
            return
        }
        
        guard myRecognizer.isAvailable else {
            // The recognizer isn't available.
            return
        }
        
        // Create and execute a speech recognition request for the audio file at the URL.
        let request = SFSpeechURLRecognitionRequest(url: url)
        myRecognizer.recognitionTask(with: request) { (result, error) in
            guard let result else {
                // Recognition failed, so check the error for details and handle it.
                return
            }
            
            // Print the speech transcription with the highest confidence that the
            // system recognized.
            if result.isFinal {
                var arr = result.bestTranscription.formattedString.lowercased().components(separatedBy: " ")
                var referenceApple = reference.joined(separator: " ").components(separatedBy: " ")
                let wer = calculateWER(arr, referenceApple)
                let transcription = TranscriptionWER(transcription: arr, reference: reference, wordErrorRate: wer, timeForTranscription: 0.0)
                do {
                    let encodedData = try JSONEncoder().encode(transcription)
                    let jsonString = String(data: encodedData,
                                            encoding: .utf8)
                    let pathWithFilename = fileFolderURL.appendingPathComponent("apple.json")
                    do {
                        try jsonString?.write(to: pathWithFilename,
                                             atomically: true,
                                             encoding: .utf8)
                    } catch {
                        print(error)
                    }
                    isTranscribing = false
                    transcriptionEnded.isAppleTranscriptionEnded = true

                } catch {
                    print(error)
                }
            }
        }
    }
    
    private func transcribeFile(path: String) {
//        resetState()
        whisper?.audioProcessor = AudioProcessor()
        self.transcribeFileTask = Task {
            do {
                try await transcribeCurrentFile(path: path)
            } catch {
                print("File selection error: \(error.localizedDescription)")
            }
        }
    }
    
    private func transcribeCurrentFile(path: String) async throws {
        let audioFileBuffer = try AudioProcessor.loadAudio(fromPath: path)
        let audioFileSamples = AudioProcessor.convertBufferToArray(buffer: audioFileBuffer)
        let transcription = try await transcribeAudioSamples(audioFileSamples)

        await MainActor.run {
            currentText = ""
            guard let segments = transcription?.segments else {
                return
            }

            self.tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
            self.effectiveRealTimeFactor = transcription?.timings.realTimeFactor ?? 0
            self.effectiveSpeedFactor = transcription?.timings.speedFactor ?? 0
            self.currentEncodingLoops = Int(transcription?.timings.totalEncodingRuns ?? 0)
            self.firstTokenTime = transcription?.timings.firstTokenTime ?? 0
            self.pipelineStart = transcription?.timings.pipelineStart ?? 0
            self.currentLag = transcription?.timings.decodingLoop ?? 0

            self.confirmedSegments = segments
            let confirmedText = self.confirmedSegments.map{segment in segment.text}.reduce("", {combined, text in combined + "." + text})
            var arr = confirmedText.components(separatedBy: ".")
            arr = arr.map{element in element.trimmingCharacters(in: .whitespacesAndNewlines)}.map{element in element.lowercased()}.filter{item in item != ""}
            let wer = calculateWER(arr, reference)
            let transcription = TranscriptionWER(transcription: arr, reference: reference, wordErrorRate: wer, timeForTranscription: 0.0)
            do {
                let encodedData = try JSONEncoder().encode(transcription)
                let jsonString = String(data: encodedData,
                                        encoding: .utf8)
                let pathWithFilename = fileFolderURL.appendingPathComponent("whisper.json")
                do {
                    try jsonString?.write(to: pathWithFilename,
                                         atomically: true,
                                         encoding: .utf8)
                } catch {
                    print(error)
                }
            } catch {
                print(error)
            }
            transcriptionEnded.isWhisperTranscriptionEnded = true
        }
    }
    
    private func calculateWER(_ arr: [String], _ reference: [String]) -> Double{
        var combined: [String] = [""]
        if arr.count > reference.count {
            combined = arr.map{_ in ""}
            var index = 0
            for el in arr {
                if reference.contains(el) {
                    combined[index] = el
                }
                index += 1
            }
        } else if reference.count >= arr.count {
            combined = reference.map{_ in ""}
            var index = 0
            for el in reference {
                if arr.contains(el) {
                    combined[index] = el
                }
                index += 1
            }
        }
        combined = combined.filter{element in element == ""}
        return Double(combined.count) / Double(reference.count)
    }
    
    private func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
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
    recordingView().environmentObject(ReadyForRecording(isReadyForRecording: true))
}
