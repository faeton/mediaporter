// Status icon for file job — maps status to SF Symbol + color.

import SwiftUI

struct StatusIcon: View {
    let job: FileJob

    var body: some View {
        Image(systemName: job.statusIcon)
            .foregroundColor(job.statusColor)
            .font(.system(size: 14))
    }
}
