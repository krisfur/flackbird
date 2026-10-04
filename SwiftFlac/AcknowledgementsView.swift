import SwiftUI

/// Third-party notices the app must ship with; libFLAC's BSD licence requires its text here.
struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section {
                Text(Self.libFLACLicense)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("libFLAC")
            } footer: {
                Text("Flackbird decodes FLAC with libFLAC 1.5.0 from the Xiph.Org Foundation.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Acknowledgements")
    }

    /// Verbatim from Packages/CFLAC/COPYING.Xiph.
    static let libFLACLicense = """
    Copyright (C) 2000-2009  Josh Coalson
    Copyright (C) 2011-2025  Xiph.Org Foundation

    Redistribution and use in source and binary forms, with or without \
    modification, are permitted provided that the following conditions \
    are met:

    - Redistributions of source code must retain the above copyright \
    notice, this list of conditions and the following disclaimer.

    - Redistributions in binary form must reproduce the above copyright \
    notice, this list of conditions and the following disclaimer in the \
    documentation and/or other materials provided with the distribution.

    - Neither the name of the Xiph.Org Foundation nor the names of its \
    contributors may be used to endorse or promote products derived from \
    this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \
    ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT \
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR \
    A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR \
    CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, \
    EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, \
    PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR \
    PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF \
    LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING \
    NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS \
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}
