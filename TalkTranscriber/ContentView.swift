//
//  ContentView.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic on 05.06.24.
//

import SwiftUI

struct ContentView: View {

    @StateObject var readyForRecording: ReadyForRecording = ReadyForRecording(isReadyForRecording: false)


    
    var body: some View {
        if readyForRecording.isReadyForRecording {
            recordingView().environmentObject(readyForRecording)
        } else {
            initView().environmentObject(readyForRecording)
        }
    }
    
}

#Preview {
    ContentView(readyForRecording: ReadyForRecording(isReadyForRecording: false))
}
