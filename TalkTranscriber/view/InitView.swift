//
//  InitView.swift
//  TalkTranscriber
//
//  Created by Bratislav Ljubisic Home  on 6/19/24.
//

import SwiftUI

struct initView: View {
    @EnvironmentObject var readyForRecording: ReadyForRecording
    var body: some View {
        VStack {
            Button(action: {
                self.readyForRecording.readyForRecording()
            }, label: {
                Text("Add new recording")
                    .font(.largeTitle)
                Text(Image(systemName: "plus.square"))
                    .font(.largeTitle)
                    .tint(.green)
            })
        }
    }
}

#Preview {
    initView().environmentObject(ReadyForRecording(isReadyForRecording: false))
}
