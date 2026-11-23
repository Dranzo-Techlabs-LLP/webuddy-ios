//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The corner brackets drawn around the camera preview of a QR code scanner.
struct QRScannerViewOverlay: View {
    let length: CGFloat
    
    private let dashRatio: CGFloat = 80.0 / 312.0
    private let emptyRatio: CGFloat = 232.0 / 312.0
    private let dashPhaseRatio: CGFloat = 40.0 / 312.0
    
    private var dashLength: CGFloat {
        length * dashRatio
    }
    
    private var emptyLength: CGFloat {
        length * emptyRatio
    }
    
    private var dashPhase: CGFloat {
        length * dashPhaseRatio
    }
    
    var body: some View {
        Rectangle()
            .stroke(.compound.textPrimary, style: StrokeStyle(lineWidth: 6.0, lineCap: .square, dash: [dashLength, emptyLength], dashPhase: dashPhase))
    }
}
