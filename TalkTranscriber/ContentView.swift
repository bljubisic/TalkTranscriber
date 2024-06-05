//
//  ContentView.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic on 05.06.24.
//

import SwiftUI
import WhisperKit

struct ContentView: View {
    @State var whisper: WhisperKit? = nil
    private var selectedModel = WhisperKit.recommendedModels().default
    @State private var isRecording: Bool = false
    
    @State private var bufferEnergy: [Float] = []
    @State private var bufferSeconds: Double = 0
    
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
            Button{
//                isRecording = !isRecording
                toggleRecording(shouldLoop: true)
            }
        label: {
            Label(isRecording ? "Stop Recording": "Start Recording", systemImage: isRecording ? "stop.circle": "record.circle")
                .foregroundColor(.red)
        }.contentTransition(.symbolEffect(.replace))
                .font(.largeTitle)
        }
        .padding()
    }
    
    func toggleRecording(shouldLoop: Bool) {
        isRecording.toggle()

        if isRecording {
            startRecording(shouldLoop)
        } else {
            stopRecording(shouldLoop)
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
            }
        }
    }
    
    func stopRecording(_ shouldLoop: Bool) {
        
    }
}



#Preview {
    ContentView()
}
