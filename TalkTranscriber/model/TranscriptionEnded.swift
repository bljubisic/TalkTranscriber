//
//  TranscriptionEnded.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic Home  on 6/20/24.
//

import Foundation
import Combine

class TranscriptionEnded: ObservableObject {
    @Published var isAppleTranscriptionEnded = false
    @Published var isWhisperTranscriptionEnded = false
    
    init(isAppleTranscriptionEnded: Bool, isWhisperTranscriptionEnded: Bool) {
        self.isAppleTranscriptionEnded = isAppleTranscriptionEnded
        self.isWhisperTranscriptionEnded = isWhisperTranscriptionEnded
    }
    
    func appleTranscriptionEndedToggle() {
        self.isAppleTranscriptionEnded = !self.isAppleTranscriptionEnded
    }
    
    func whisperTranscriptionEndedToggle() {
        self.isWhisperTranscriptionEnded = !self.isWhisperTranscriptionEnded
    }
}
