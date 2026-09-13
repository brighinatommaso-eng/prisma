import Foundation

/// The state of one screen's request. Every request ends in `loaded` or
/// `failed`; nothing is left in `loading` once its request finishes.
enum LoadState<Value> {
    case idle
    case loading(since: Date)
    case loaded(Value)
    case failed(APIError)
}
