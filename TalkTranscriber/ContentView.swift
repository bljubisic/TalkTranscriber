//
//  ContentView.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic on 05.06.24.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var readyForRecording: ReadyForRecording


    
    var body: some View {
        if readyForRecording.isReadyForRecording {
            recordingView(audioFile: URL(fileURLWithPath: "something"))
        } else {
            initView()
        }
    }
    
}

#Preview {
    ContentView().environmentObject(ReadyForRecording(isReadyForRecording: false))
}
