//
//  TranscriptionModel.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic on 18.06.24.
//

import Foundation

struct TranscriptionWER: Codable {
    let transcription: [String]
    let reference: [String]
    let wordErrorRate: Double
    let timeForTranscription: Double
}
