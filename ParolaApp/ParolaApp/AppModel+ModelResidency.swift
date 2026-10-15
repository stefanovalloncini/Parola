import Foundation
import ParolaCore

extension AppModel {
    func modelPickerAppeared() {
        refreshModelList()
    }

    func pickModel(_ id: String, isInstalled: Bool, download: (String) -> Void) {
        // Activate first: a refused or failing download corrects the selection against this pick.
        activateModel(id)
        if isInstalled {
            prewarmSelectedModel()
        } else {
            download(id)
        }
    }
}
