//
//  ReadyForRecording.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic Home  on 6/18/24.
//

import Foundation
import Combine

class ReadyForRecording: ObservableObject {
    @Published var isReadyForRecording: Bool = false
    
    init(isReadyForRecording: Bool) {
        self.isReadyForRecording = isReadyForRecording
    }
    
    func readyForRecording() {
        isReadyForRecording = true
    }
}
